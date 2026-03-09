//
//  TestRunner.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation
import Combine
import AppKit
import UserNotifications

class TestRunner: ObservableObject {
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var isBuilding = false
    @Published var queuedRunCount = 0
    @Published var currentTestRun: TestRun?
    @Published var output: String = ""
    @Published var passingCount: Int = 0
    @Published var failingCount: Int = 0
    @Published var totalCount: Int = 0
    
    private var passedTestNames = Set<String>()
    private var failedTestNames = Set<String>()
    
    private var process: Process?
    private var xcodebuildProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var cancellables = Set<AnyCancellable>()
    private var isCancelled = false
    private let setupQueue = DispatchQueue(label: "com.atastypixel.Tests.setupQueue", qos: .userInitiated)
    private var pendingRuns: [PendingRunRequest] = []
    private var activeBranchName: String?
    
    private let tempRootFolder: URL
    private let fileManager = FileManager.default
    
    private static let totalCountKey = "com.atastypixel.Tests.lastTotalCount"

    private struct PendingRunRequest {
        let branchName: String
        let isManualRun: Bool
    }

    enum RunDispatchAction: Equatable {
        case startNow
        case queued
        case queuedAndCancelActive
    }
    
    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        tempRootFolder = appSupport.appendingPathComponent("Tests/TempWorkspace", isDirectory: true)
    }
    
    private func workspaceFolder() -> URL {
        tempRootFolder.appendingPathComponent("workspace", isDirectory: true)
    }
    
    func runTests(branchName: String? = nil, isManualRun: Bool = false) {
        print("TestRunner: runTests() called with branch: \(branchName ?? "nil"), isManualRun: \(isManualRun)")
        
        // Ignore automatic triggers while paused, but still allow explicit manual runs.
        if isPaused && !isManualRun {
            print("TestRunner: Tests are paused, ignoring run request")
            return
        }

        let settings = SettingsStore.shared
        
        // Repository path is required
        guard !settings.repositoryPath.isEmpty else {
            print("TestRunner: ERROR - Repository path not configured. Please set it in Settings.")
            showError("Repository path not configured", message: "Please configure the repository path in Settings.")
            return
        }
        
        // Determine which branch to use: notification branch > settings branch > "develop".
        let branchToUse = resolvedBranchName(for: branchName, defaultBranch: settings.branchName)

        switch dispatchIncomingRun(branchName: branchToUse, isManualRun: isManualRun) {
        case .startNow:
            break
        case .queued:
            return
        case .queuedAndCancelActive:
            cancelActiveRunForQueueReplacement()
            return
        }

        // Reset cancellation flag when starting new tests
        isCancelled = false
        activeBranchName = branchToUse

        print("TestRunner: Using repository path: \(settings.repositoryPath)")
        print("TestRunner: Using branch: \(branchToUse)")
        let repositoryRoot = URL(fileURLWithPath: settings.repositoryPath)
        let branchWorkspace = workspaceFolder()

        prepareForRunStart()
        
        // Move all setup work to a serial background queue to avoid overlapping git operations.
        setupQueue.async { [weak self] in
            guard let self = self else { return }

            if self.shouldStopBeforeLaunchingProcess() { return }
            
            // Verify repository path exists
            guard self.fileManager.fileExists(atPath: repositoryRoot.path) else {
                print("TestRunner: ERROR - Repository path does not exist: \(repositoryRoot.path)")
                self.abortRun(removeCurrentRun: true)
                self.showError("Repository path not found", message: "The configured repository path does not exist. Please check Settings.")
                return
            }
            
            // Ensure temp folder exists
            DispatchQueue.main.async {
                self.output += "Preparing workspace...\n"
            }
            do {
                try self.fileManager.createDirectory(at: self.tempRootFolder, withIntermediateDirectories: true)
                try self.fileManager.createDirectory(at: branchWorkspace, withIntermediateDirectories: true)
                self.cleanupLegacyBranchWorkspacesSync(keeping: branchWorkspace)
                print("TestRunner: Temp root ready: \(self.tempRootFolder.path)")
                print("TestRunner: Branch workspace ready: \(branchWorkspace.path)")
            } catch {
                print("TestRunner: ERROR - Failed to create temp folder: \(error)")
                self.abortRun(removeCurrentRun: true)
                self.showError("Failed to create temp folder", message: error.localizedDescription)
                return
            }

            if self.shouldStopBeforeLaunchingProcess() { return }
            
            // Clone or update repository (synchronous on background thread)
            if !self.fileManager.fileExists(atPath: branchWorkspace.appendingPathComponent(".git").path) {
                DispatchQueue.main.async {
                    self.output += "Cloning repository...\n"
                }
                print("TestRunner: Cloning repository...")
                if !self.cloneRepositorySync(from: repositoryRoot, to: branchWorkspace) {
                    self.abortRun(removeCurrentRun: true)
                    self.showError("Failed to clone repository", message: "Could not clone repository into the temp workspace.")
                    return
                }
            } else {
                // Fetch latest changes from remote
                DispatchQueue.main.async {
                    self.output += "Fetching repository updates...\n"
                }
                print("TestRunner: Fetching repository updates...")
                let fetchResult = self.fetchRepositorySync(in: branchWorkspace)
                if !fetchResult.success {
                    print("TestRunner: Fetch failed, rebuilding workspace and retrying")
                    DispatchQueue.main.async {
                        self.output += "Fetch failed. Recreating workspace and retrying...\n"
                    }
                    if !self.recreateWorkspaceSync(from: repositoryRoot, to: branchWorkspace) {
                        let detail = fetchResult.output.isEmpty ? "No additional git output available." : fetchResult.output
                        self.abortRun(removeCurrentRun: true)
                        self.showError(
                            "Failed to fetch repository",
                            message: "Could not fetch repository updates.\n\nGit output:\n\(detail)"
                        )
                        return
                    }
                }
            }

            if self.shouldStopBeforeLaunchingProcess() { return }
            
            // Checkout selected ref (branch or commit SHA)
            DispatchQueue.main.async {
                self.output += "Checking out '\(branchToUse)'...\n"
            }
            print("TestRunner: Checking out ref: \(branchToUse)")
            if !self.checkoutRefSync(branchToUse, in: branchWorkspace) {
                self.abortRun(removeCurrentRun: true)
                self.showError(
                    "Failed to checkout ref",
                    message: "Could not checkout '\(branchToUse)'. Please verify the branch name, commit SHA, or commit message selection."
                )
                return
            }

            if self.shouldStopBeforeLaunchingProcess() { return }
            
            // Find workspace file within the cloned repository
            DispatchQueue.main.async {
                self.output += "Finding workspace...\n"
            }
            print("TestRunner: Searching for workspace file in: \(branchWorkspace.path)")
            guard let workspaceURL = WorkspaceFinder.findWorkspace(in: branchWorkspace) else {
                print("TestRunner: ERROR - Could not find .xcworkspace file in repository root")
                self.abortRun(removeCurrentRun: true)
                self.showError("Workspace not found", message: "Could not find .xcworkspace file in repository root. Please check the repository path in Settings.")
                return
            }
            
            print("TestRunner: Found workspace: \(workspaceURL.path)")

            if self.shouldStopBeforeLaunchingProcess() { return }
            
            // Run tests on main thread
            DispatchQueue.main.async {
                self.output += "Starting build...\n\n"
                print("TestRunner: Starting xcodebuild build+test pipeline...")
                self.runXcodebuildTests(workspaceURL: workspaceURL, branchName: branchToUse, workspaceDirectory: branchWorkspace)
            }
        }
    }
    
    private func showError(_ title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    func pause() {
        print("TestRunner: Pausing - will ignore incoming notifications")
        isPaused = true
        // Don't kill current process - just prevent new triggers
    }
    
    func resume() {
        print("TestRunner: Resuming - will accept incoming notifications")
        isPaused = false
        // Tests will resume on next trigger or manual run
    }
    
    func cancel() {
        print("TestRunner: Canceling tests")
        isCancelled = true
        pendingRuns.removeAll()
        queuedRunCount = 0
        
        // Delete the test run from history if it was already saved
        if let testRun = currentTestRun {
            // Notify that we're clearing this test run
            // The AppDelegate will handle deletion from the store
            NotificationCenter.default.post(name: NSNotification.Name("DeleteTestRun"), object: testRun)
        }
        
        killCurrentProcess()
        isPaused = false
        isRunning = false
        isBuilding = false
        
        // Reset all state to clear the view
        output = ""
        passingCount = 0
        failingCount = 0
        passedTestNames.removeAll()
        failedTestNames.removeAll()
        currentTestRun = nil
    }
    
    private func killCurrentProcess() {
        if let process = process {
            process.terminate()
            // Don't wait synchronously - let it terminate in background
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
        }
        if let xcodebuildProcess = xcodebuildProcess {
            xcodebuildProcess.terminate()
            DispatchQueue.global(qos: .utility).async {
                xcodebuildProcess.waitUntilExit()
            }
        }
        // Don't wait synchronously - let it terminate in background
        self.process = nil
        self.xcodebuildProcess = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
    }
    
    private struct GitCommandResult {
        let success: Bool
        let output: String
    }
    
    @discardableResult
    private func runGitCommandSync(
        _ arguments: [String],
        in directory: URL? = nil,
        suppressFailureLogging: Bool = false
    ) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: data, encoding: .utf8) ?? ""
            
            if !outputString.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.output += outputString
                }
            }
            
            let success = process.terminationStatus == 0
            if !success && !suppressFailureLogging {
                let command = arguments.joined(separator: " ")
                let trimmed = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                print("TestRunner: Git command failed (\(command))")
                if !trimmed.isEmpty {
                    print("TestRunner: Git output: \(trimmed)")
                }
            }
            return GitCommandResult(success: success, output: outputString)
        } catch {
            let message = "Failed to run git command (\(arguments.joined(separator: " "))): \(error.localizedDescription)"
            print("TestRunner: \(message)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "\(message)\n"
            }
            return GitCommandResult(success: false, output: message)
        }
    }
    
    private func cloneRepositorySync(from source: URL, to destination: URL) -> Bool {
        // Remove --depth 1 to get all branches (needed for branch checkout).
        let result = runGitCommandSync(["clone", "file://\(source.path)", destination.path])
        return result.success
    }
    
    private func fetchRepositorySync(in directory: URL) -> GitCommandResult {
        runGitCommandSync(["fetch", "origin"], in: directory)
    }
    
    private func recreateWorkspaceSync(from source: URL, to destination: URL) -> Bool {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            DispatchQueue.main.async { [weak self] in
                self?.output += "Recloning repository...\n"
            }
            return cloneRepositorySync(from: source, to: destination)
        } catch {
            print("TestRunner: Failed to recreate workspace: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "Error: Failed to recreate workspace: \(error.localizedDescription)\n"
            }
            return false
        }
    }

    private func cleanupLegacyBranchWorkspacesSync(keeping currentWorkspace: URL) {
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: tempRootFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for item in contents where item.path != currentWorkspace.path {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }

                do {
                    try fileManager.removeItem(at: item)
                    print("TestRunner: Removed legacy workspace: \(item.path)")
                    DispatchQueue.main.async { [weak self] in
                        self?.output += "Removed old workspace '\(item.lastPathComponent)'.\n"
                    }
                } catch {
                    print("TestRunner: Failed to remove legacy workspace \(item.path): \(error)")
                }
            }
        } catch {
            print("TestRunner: Failed to inspect temp workspace contents: \(error)")
        }
    }
    
    private func checkoutRefSync(_ ref: String, in directory: URL) -> Bool {
        if isKnownBranchRef(ref, in: directory) {
            let checkoutResult = runGitCommandSync(["checkout", ref], in: directory)
            if !checkoutResult.success {
                return false
            }
            return resetToRemoteBranch(ref, in: directory)
        }

        // Fallback for commit SHA/short SHA: detached checkout.
        let detachedCheckout = runGitCommandSync(["checkout", "--detach", ref], in: directory)
        return detachedCheckout.success
    }

    private func isKnownBranchRef(_ ref: String, in directory: URL) -> Bool {
        let localExists = runGitCommandSync(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(ref)"],
            in: directory,
            suppressFailureLogging: true
        ).success
        if localExists {
            return true
        }

        let remoteExists = runGitCommandSync(
            ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(ref)"],
            in: directory,
            suppressFailureLogging: true
        ).success
        return remoteExists
    }
    
    private func abortRun(removeCurrentRun: Bool) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.isBuilding = false
            self.activeBranchName = nil
            
            if removeCurrentRun, let currentRun = self.currentTestRun {
                NotificationCenter.default.post(name: NSNotification.Name("DeleteTestRun"), object: currentRun)
                self.currentTestRun = nil
            }
            self.startNextQueuedRunIfNeeded()
        }
    }
    
    private func resetToRemoteBranch(_ branchName: String, in directory: URL) -> Bool {
        // Check if remote branch exists.
        let checkResult = runGitCommandSync(
            ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branchName)"],
            in: directory,
            suppressFailureLogging: true
        )
        if !checkResult.success {
            print("TestRunner: Remote branch 'origin/\(branchName)' does not exist, skipping reset")
            return true
        }
        
        // Reset local branch to match remote.
        let resetResult = runGitCommandSync(["reset", "--hard", "origin/\(branchName)"], in: directory)
        return resetResult.success
    }
    
    private func runXcodebuildTests(workspaceURL: URL, branchName: String, workspaceDirectory: URL) {
        if isCancelled {
            print("TestRunner: Run was canceled before xcodebuild launch")
            isCancelled = false
            abortRun(removeCurrentRun: true)
            return
        }

        // isRunning and output are already set in runTests()
        if currentTestRun == nil {
            var testRun = TestRun(status: .running)
            testRun.totalCount = totalCount > 0 ? totalCount : nil
            testRun.branchName = branchName
            currentTestRun = testRun
            sendTestStartNotification(branchName: branchName)
        }

        let escapedWorkspacePath = shellEscape(workspaceURL.path)
        let escapedScheme = shellEscape("Loopy Pro (macOS)")
        let escapedDestination = shellEscape("platform=macOS,arch=arm64")
        let xcodebuildCommand = """
        /usr/bin/xcodebuild -workspace \(escapedWorkspacePath) -scheme \(escapedScheme) -destination \(escapedDestination) build-for-testing && /usr/bin/xcodebuild -workspace \(escapedWorkspacePath) -scheme \(escapedScheme) -destination \(escapedDestination) test-without-building
        """
        
        // Check if xcbeautify is available
        let xcbeautifyPaths = ["/usr/local/bin/xcbeautify", "/opt/homebrew/bin/xcbeautify"]
        var xcbeautifyPath: String?
        for path in xcbeautifyPaths {
            if fileManager.fileExists(atPath: path) {
                xcbeautifyPath = path
                break
            }
        }
        
        // Run build and test in a fail-fast shell pipeline:
        // test-without-building only runs if build-for-testing succeeds.
        let xcodebuildProcess = Process()
        xcodebuildProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        xcodebuildProcess.arguments = ["-lc", xcodebuildCommand]
        xcodebuildProcess.currentDirectoryURL = workspaceDirectory
        
        // Set up environment with NSUnbufferedIO for real-time output
        var environment = ProcessInfo.processInfo.environment
        if xcbeautifyPath != nil {
            environment["NSUnbufferedIO"] = "YES"
        }
        xcodebuildProcess.environment = environment
        
        if let xcbeautifyPath = xcbeautifyPath {
            // Pipe through xcbeautify for colored output
            let xcodebuildOutputPipe = Pipe()
            xcodebuildProcess.standardOutput = xcodebuildOutputPipe
            xcodebuildProcess.standardError = xcodebuildOutputPipe // Merge stderr into stdout for xcbeautify
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            
            let xcbeautifyProcess = Process()
            xcbeautifyProcess.executableURL = URL(fileURLWithPath: xcbeautifyPath)
            xcbeautifyProcess.arguments = ["--renderer", "terminal"] // Explicitly use terminal renderer for ANSI colors
            xcbeautifyProcess.standardInput = xcodebuildOutputPipe
            xcbeautifyProcess.standardOutput = outputPipe
            xcbeautifyProcess.standardError = errorPipe
            
            // Set NSUnbufferedIO environment variable to disable buffering for real-time output
            var xcbeautifyEnv = ProcessInfo.processInfo.environment
            xcbeautifyEnv["NSUnbufferedIO"] = "YES"
            xcbeautifyProcess.environment = xcbeautifyEnv
            
            self.process = xcbeautifyProcess
            self.xcodebuildProcess = xcodebuildProcess
            
            // When xcbeautify terminates, terminate xcodebuild
            xcbeautifyProcess.terminationHandler = { [weak self] _ in
                self?.xcodebuildProcess?.terminate()
            }
            
            // Set up output reading - update directly on main thread
            let outputHandle = outputPipe.fileHandleForReading
            self.outputHandle = outputHandle
            
            // Configure file handle for reading
            outputHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty {
                    guard let string = String(data: data, encoding: .utf8) else {
                        return
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.output += string
                        // Parse output to detect build vs test phase and count tests
                        self.detectPhase(string)
                        self.parseTestOutput(string)
                    }
                }
            }
            
            let errorHandle = errorPipe.fileHandleForReading
            self.errorHandle = errorHandle
            errorHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty {
                    guard let string = String(data: data, encoding: .utf8) else {
                        return
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.output += string
                        // Parse output to detect build vs test phase and count tests
                        self.detectPhase(string)
                        self.parseTestOutput(string)
                    }
                }
            }
        } else {
            // Direct xcodebuild output (no xcbeautify)
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            
            xcodebuildProcess.standardOutput = outputPipe
            xcodebuildProcess.standardError = errorPipe
            self.process = xcodebuildProcess
            self.xcodebuildProcess = nil
            
            // Set up output reading - update directly on main thread
            let outputHandle = outputPipe.fileHandleForReading
            self.outputHandle = outputHandle
            
            outputHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty {
                    guard let string = String(data: data, encoding: .utf8) else {
                        return
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.output += string
                        // Parse output to detect build vs test phase and count tests
                        self.detectPhase(string)
                        self.parseTestOutput(string)
                    }
                }
            }
            
            let errorHandle = errorPipe.fileHandleForReading
            self.errorHandle = errorHandle
            
            errorHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty {
                    guard let string = String(data: data, encoding: .utf8) else {
                        return
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.output += string
                        // Parse output to detect build vs test phase and count tests
                        self.detectPhase(string)
                        self.parseTestOutput(string)
                    }
                }
            }
        }
        
        guard let process = process else {
            DispatchQueue.main.async {
                self.isRunning = false
                if var testRun = self.currentTestRun {
                    testRun.status = .error
                    testRun.errorDescription = "Failed to create process"
                    self.currentTestRun = testRun
                }
                self.startNextQueuedRunIfNeeded()
            }
            return
        }
        
        process.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            
            // Stop reading
            self.outputHandle?.readabilityHandler = nil
            self.errorHandle?.readabilityHandler = nil
            
            // Read any remaining data from pipes before capturing output
            if let outputHandle = self.outputHandle {
                let remainingData = outputHandle.readDataToEndOfFile()
                if !remainingData.isEmpty, let remainingString = String(data: remainingData, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.output += remainingString
                    }
                }
            }
            
            if let errorHandle = self.errorHandle {
                let remainingData = errorHandle.readDataToEndOfFile()
                if !remainingData.isEmpty, let remainingString = String(data: remainingData, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.output += remainingString
                    }
                }
            }
            
            // Wait a moment for all async updates to complete, then capture output on main thread
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isRunning = false
                self.isBuilding = false
                self.process = nil
                self.xcodebuildProcess = nil
                self.activeBranchName = nil
                self.outputHandle = nil
                self.errorHandle = nil
                
                // Don't save if cancelled
                if self.isCancelled {
                    self.isCancelled = false
                    self.currentTestRun = nil
                    self.startNextQueuedRunIfNeeded()
                    return
                }
                
                // Capture output on main thread after all updates are complete
                let finalOutput = self.output
                
                if var testRun = self.currentTestRun {
                    let duration = Date().timeIntervalSince(testRun.timestamp)
                    testRun.duration = duration
                    testRun.outputLog = finalOutput
                    
                    // Use live counts (from parseTestOutput) as the source of truth
                    // Don't overwrite with summary parsing which may pick up intermediate suite summaries
                    testRun.passingCount = self.passingCount
                    testRun.failingCount = self.failingCount
                    
                    // Total count is the sum of passing and failing (what we actually counted)
                    let countedTotal = self.passingCount + self.failingCount
                    testRun.totalCount = countedTotal > 0 ? countedTotal : nil
                    
                    // Store total count in UserDefaults for next run (use counted total)
                    if countedTotal > 0 {
                        UserDefaults.standard.set(countedTotal, forKey: Self.totalCountKey)
                    }
                    
                    // Parse output for status (check for xcbeautify formatted output too)
                    // Determine status based on counts and output content
                    if finalOutput.contains("error:") || finalOutput.contains("*** Terminating") || finalOutput.contains("❌") {
                        testRun.status = .error
                        testRun.errorDescription = self.extractError(from: finalOutput)
                    } else if finalOutput.contains("** BUILD FAILED **") || finalOutput.contains("BUILD FAILED") {
                        testRun.status = .error
                    } else if self.failingCount > 0 || self.outputContainsRealTestFailure(finalOutput) {
                        testRun.status = .failed
                    } else if finalOutput.contains("warning:") || finalOutput.contains("⚠️") {
                        testRun.status = .warnings
                    } else if finalOutput.contains("✅") || finalOutput.contains("** TEST SUCCEEDED **") || finalOutput.contains("TEST SUCCEEDED") {
                        testRun.status = .success
                    } else {
                        // Default to success only if we have no failures
                        testRun.status = self.failingCount > 0 ? .failed : .success
                    }
                    
                    self.currentTestRun = testRun
                    
                    // Send notification that tests have completed
                    self.sendTestCompletionNotification(testRun: testRun)
                }
                self.startNextQueuedRunIfNeeded()
            }
        }
        
        do {
            // Start xcodebuild first if using xcbeautify
            // NOTE: Don't close write ends of pipes until processes terminate - closing them early causes crashes
            if let _ = xcbeautifyPath {
                if let xcodebuildProc = self.xcodebuildProcess {
                    try xcodebuildProc.run()
                }
                if let proc = self.process {
                    try proc.run()
                }
            } else {
                if let proc = self.process {
                    try proc.run()
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
                self.activeBranchName = nil
                if var testRun = self.currentTestRun {
                    testRun.status = .error
                    testRun.errorDescription = error.localizedDescription
                    self.currentTestRun = testRun
                }
                self.startNextQueuedRunIfNeeded()
            }
        }
    }

    private func prepareForRunStart() {
        isRunning = true
        output = ""

        // Load total count from UserDefaults (from previous run)
        let savedTotalCount = UserDefaults.standard.integer(forKey: Self.totalCountKey)
        if savedTotalCount > 0 {
            totalCount = savedTotalCount
        }

        // Reset counts for new run
        passingCount = 0
        failingCount = 0
        passedTestNames.removeAll()
        failedTestNames.removeAll()
        isBuilding = true // Start in building phase
        currentTestRun = nil
    }

    private func startNextQueuedRunIfNeeded() {
        guard !isRunning, !pendingRuns.isEmpty else { return }
        let nextRequest = pendingRuns.removeFirst()
        queuedRunCount = pendingRuns.count
        runTests(branchName: nextRequest.branchName, isManualRun: nextRequest.isManualRun)
    }

    private func resolvedBranchName(for requestedBranch: String?, defaultBranch: String?) -> String {
        var branchToUse = requestedBranch ?? defaultBranch ?? "develop"
        branchToUse = branchToUse.trimmingCharacters(in: .whitespaces)
        if branchToUse.hasPrefix("+") {
            branchToUse = String(branchToUse.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return branchToUse
    }

    private func enqueuePendingRun(branchName: String, isManualRun: Bool) {
        if let existingIndex = pendingRuns.firstIndex(where: { $0.branchName == branchName }) {
            let existing = pendingRuns[existingIndex]
            pendingRuns[existingIndex] = PendingRunRequest(
                branchName: branchName,
                isManualRun: existing.isManualRun || isManualRun
            )
            queuedRunCount = pendingRuns.count
            print("TestRunner: Deduped queued request for branch '\(branchName)'")
            return
        }
        
        pendingRuns.append(PendingRunRequest(branchName: branchName, isManualRun: isManualRun))
        queuedRunCount = pendingRuns.count
        print("TestRunner: Queued request for branch '\(branchName)' (queue size: \(pendingRuns.count))")
    }

    @discardableResult
    func dispatchIncomingRun(branchName: String, isManualRun: Bool) -> RunDispatchAction {
        guard isRunning else {
            return .startNow
        }

        enqueuePendingRun(branchName: branchName, isManualRun: isManualRun)
        let runningBranch = activeBranchName ?? currentTestRun?.branchName
        if runningBranch == branchName {
            print("TestRunner: Queued request matches active branch '\(branchName)', canceling active run to prioritize newest commit")
            return .queuedAndCancelActive
        } else {
            print("TestRunner: Active branch '\(runningBranch ?? "unknown")' differs, keeping current run and queueing branch '\(branchName)'")
            return .queued
        }
    }

    var queuedRunBranchesForTesting: [String] {
        pendingRuns.map(\.branchName)
    }

    private func cancelActiveRunForQueueReplacement() {
        guard !isCancelled else { return }
        isCancelled = true
        
        if let testRun = currentTestRun {
            NotificationCenter.default.post(name: NSNotification.Name("DeleteTestRun"), object: testRun)
        }
        
        killCurrentProcess()
    }

    private func shouldStopBeforeLaunchingProcess() -> Bool {
        guard isCancelled else { return false }
        print("TestRunner: Aborting run before process launch due to cancellation/superseded trigger")
        isCancelled = false
        abortRun(removeCurrentRun: true)
        return true
    }
    
    private func extractError(from output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.lowercased().contains("error:") {
                if let range = line.range(of: "error:", options: .caseInsensitive) {
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if line.contains("*** Terminating") {
                if let range = line.range(of: "*** ") {
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private func outputContainsRealTestFailure(_ output: String) -> Bool {
        if output.contains("** TEST FAILED **") || output.contains("TEST FAILED") {
            return true
        }

        // Avoid false positives from summaries like "0 failed".
        let pattern = #"\b([1-9]\d*)\s+failed\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(output.startIndex..., in: output)
        return regex.firstMatch(in: output, options: [], range: range) != nil
    }
    
    private func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
    
    private func detectPhase(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        
        // Check the most recent lines first (they're more indicative of current state)
        var foundTestPhase = false
        var foundBuildPhase = false
        
        for line in lines.reversed() {
            let lowercased = line.lowercased()
            
            // Check for test phase indicators (higher priority - once we see tests, we're testing)
            if !foundTestPhase && (
                lowercased.contains("test case") || 
                lowercased.contains("testing") ||
                lowercased.contains("running tests") ||
                lowercased.contains("test suite") ||
                lowercased.contains("test class") ||
                line.contains("✔") || line.contains("✖") || line.contains("✓")
            ) {
                foundTestPhase = true
                break
            }
            
            // Check for build phase indicators
            if !foundBuildPhase && (
                lowercased.contains("compiling") ||
                lowercased.contains("building") ||
                lowercased.contains("linking") ||
                lowercased.contains("processing") ||
                lowercased.contains("copying") ||
                lowercased.contains("code signing") ||
                lowercased.contains("touching") ||
                lowercased.contains("write auxiliary file") ||
                lowercased.contains("compile") ||
                (lowercased.contains("build") && !lowercased.contains("test"))
            ) {
                foundBuildPhase = true
            }
        }
        
        // Update building state based on what we found
        if foundTestPhase {
            // We've entered the test phase
            if isBuilding {
                isBuilding = false
            }
        } else if foundBuildPhase && isRunning {
            // We're still in build phase (only set if running)
            if !isBuilding {
                isBuilding = true
            }
        }
    }
    
    private func parseTestOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            var testName: String? = nil
            var isPassed = false
            var isFailed = false
            
            // Match patterns like:
            // "Test Case '-[ClassName testMethod]' passed"
            // "Test Case '-[ClassName testMethod]' failed"
            // "✔ testMethod (0.002 seconds)" (xcbeautify format)
            // "✖ testMethod (0.002 seconds)" (xcbeautify format)
            // "✖ testMethod, assertion failed" (xcbeautify format with assertion details)
            
            // Check for xcbeautify checkmark format
            if line.contains("✔") || line.contains("✓") {
                // Check if this is a test result line (not just a checkmark in text)
                if line.contains("test") && (line.contains("seconds") || line.contains("passed")) {
                    testName = extractTestNameFromXcbeautifyLine(line)
                    isPassed = true
                }
            } else if line.contains("✖") || line.contains("✗") || line.contains("×") {
                // Check if this is a test failure line
                // Could be: "✖ testMethod (0.002 seconds)" or "✖ testMethod, assertion failed"
                if line.contains("test") {
                    testName = extractTestNameFromXcbeautifyLine(line)
                    isFailed = true
                }
            } else if line.contains("Test Case") {
                // Standard xcodebuild format: "Test Case '-[ClassName testMethod]' passed/failed"
                testName = extractTestNameFromTestCaseLine(line)
                if line.contains("passed") {
                    isPassed = true
                } else if line.contains("failed") {
                    isFailed = true
                }
            }
            
            // Update counts only if we found a unique test name
            if let name = testName, !name.isEmpty {
                if isPassed {
                    if !passedTestNames.contains(name) {
                        // Remove from failed set if it was there (test might have been retried)
                        failedTestNames.remove(name)
                        passedTestNames.insert(name)
                        passingCount = passedTestNames.count
                        failingCount = failedTestNames.count
                        updateCurrentTestRunCounts()
                    }
                } else if isFailed {
                    if !failedTestNames.contains(name) && !passedTestNames.contains(name) {
                        // Only count as failed if not already passed
                        failedTestNames.insert(name)
                        failingCount = failedTestNames.count
                        updateCurrentTestRunCounts()
                    }
                }
            }
        }
    }
    
    private func extractTestNameFromXcbeautifyLine(_ line: String) -> String? {
        // Patterns:
        // "✔ testMethod (0.002 seconds)"
        // "✖ testMethod (0.002 seconds)"
        // "✖ testMethod, assertion details"
        
        // First, try to find test name before comma (most common in failure cases)
        if let commaIndex = line.firstIndex(of: ",") {
            let beforeComma = String(line[..<commaIndex])
            // Look for test name pattern in the part before comma
            if let testRange = beforeComma.range(of: "test[A-Za-z0-9_]+", options: .regularExpression) {
                return String(beforeComma[testRange])
            }
        }
        
        // Try regex patterns to match test names
        let patterns = [
            "test[A-Z]\\w+",  // Matches testMethodName (camelCase)
            "test_[a-zA-Z0-9_]+"  // Matches test_method_name (snake_case)
        ]
        
        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                var testName = String(line[range])
                // If test name contains a comma or parenthesis, truncate it
                if let commaIndex = testName.firstIndex(of: ",") {
                    testName = String(testName[..<commaIndex])
                }
                if let parenIndex = testName.firstIndex(of: "(") {
                    testName = String(testName[..<parenIndex])
                }
                return testName.trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Fallback: look for "test" followed by alphanumeric characters until space/comma/paren
        if let testIndex = line.range(of: "test", options: .caseInsensitive) {
            let afterTest = line[testIndex.upperBound...]
            let endIndex = afterTest.firstIndex(where: { $0 == " " || $0 == "," || $0 == "(" }) ?? afterTest.endIndex
            let testName = "test" + String(afterTest[..<endIndex]).trimmingCharacters(in: .whitespaces)
            if !testName.isEmpty && testName != "test" {
                return testName
            }
        }
        
        return nil
    }
    
    private func extractTestNameFromTestCaseLine(_ line: String) -> String? {
        // Pattern: "Test Case '-[ClassName testMethod]' passed/failed"
        // Extract testMethod from the brackets
        
        if let startRange = line.range(of: "-["),
           let endRange = line.range(of: "]'", range: startRange.upperBound..<line.endIndex) {
            let testCase = String(line[startRange.upperBound..<endRange.lowerBound])
            // testCase is now "ClassName testMethod"
            let components = testCase.components(separatedBy: .whitespaces)
            if components.count >= 2 {
                return components.last // Return testMethod
            }
        }
        
        return nil
    }
    
    
    private func updateCurrentTestRunCounts() {
        // Don't update totalCount here - it's the saved denominator from UserDefaults
        // The current counted total is passingCount + failingCount
        
        if var testRun = currentTestRun {
            testRun.passingCount = passingCount
            testRun.failingCount = failingCount
            // Total count is the sum of what we've actually counted
            let countedTotal = passingCount + failingCount
            testRun.totalCount = countedTotal > 0 ? countedTotal : nil
            currentTestRun = testRun
        }
    }
    
    func killAllProcesses() {
        killCurrentProcess()
    }
    
    private func sendTestStartNotification(branchName: String) {
        let center = UNUserNotificationCenter.current()
        
        let content = UNMutableNotificationContent()
        content.title = "Tests Started"
        content.body = "Running tests on branch: \(branchName)"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                print("TestRunner: Failed to send start notification: \(error)")
            }
        }
    }
    
    private func sendTestCompletionNotification(testRun: TestRun) {
        let center = UNUserNotificationCenter.current()
        
        let content = UNMutableNotificationContent()
        let passingCount = testRun.passingCount ?? 0
        let failingCount = testRun.failingCount ?? 0
        let totalCount = testRun.totalCount ?? (passingCount + failingCount)
        
        // Determine notification details based on status
        switch testRun.status {
        case .success:
            content.title = "Tests Passed ✅"
            content.body = "\(passingCount) of \(totalCount) tests passed"
            content.sound = .default
        case .failed:
            content.title = "Tests Failed ❌"
            content.body = "\(failingCount) of \(totalCount) tests failed (\(passingCount) passed)"
            // Use a more prominent sound for failures
            if #available(macOS 12.0, *) {
                content.sound = UNNotificationSound.defaultCritical
                content.interruptionLevel = .critical
            } else {
                content.sound = .default
            }
            content.categoryIdentifier = "TEST_FAILURE"
        case .error:
            content.title = "Test Error ❌"
            if let errorDesc = testRun.errorDescription {
                content.body = errorDesc
            } else {
                content.body = "An error occurred during test execution"
            }
            // Use a more prominent sound for errors
            if #available(macOS 12.0, *) {
                content.sound = UNNotificationSound.defaultCritical
                content.interruptionLevel = .critical
            } else {
                content.sound = .default
            }
            content.categoryIdentifier = "TEST_ERROR"
        case .warnings:
            content.title = "Tests Completed with Warnings ⚠️"
            content.body = "\(passingCount) of \(totalCount) tests passed"
            content.sound = .default
        default:
            content.title = "Tests Completed"
            content.body = "\(passingCount) passed, \(failingCount) failed"
            content.sound = .default
        }
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                print("TestRunner: Failed to send completion notification: \(error)")
            }
        }
    }
}
