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
import RegexBuilder

enum TestUserNotification {
    static let startCategoryIdentifier = "TEST_STARTED"
    static let failureCategoryIdentifier = "TEST_FAILURE"
    static let errorCategoryIdentifier = "TEST_ERROR"

    static let cancelActionIdentifier = "CANCEL_TESTS"
    static let openReportsActionIdentifier = "OPEN_REPORTS"
}

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
    private var watchdogTimer: DispatchSourceTimer?
    private var testPhaseStartedAt: Date?
    private var lastTestProgressAt: Date?
    private var watchdogTerminationInfo: WatchdogTerminationInfo?
    private var cancellables = Set<AnyCancellable>()
    private var isCancelled = false
    private let setupQueue = DispatchQueue(label: "com.atastypixel.Tests.setupQueue", qos: .userInitiated)
    private let watchdogQueue = DispatchQueue(label: "com.atastypixel.Tests.watchdogQueue", qos: .utility)
    private var pendingRuns: [PendingRunRequest] = []
    private var activeBranchName: String?
    
    private let tempRootFolder: URL
    private let fileManager = FileManager.default
    
    private static let totalCountKey = "com.atastypixel.Tests.lastTotalCount"
    private static let lastPreparedWorkspaceRefKey = "com.atastypixel.Tests.lastPreparedWorkspaceRef"
    private static let defaultWatchdogCheckInterval: TimeInterval = 15
    static let sourceRemoteTrackingFetchRefspec = "+refs/remotes/origin/*:refs/remotes/source-origin/*"

    private struct PendingRunRequest {
        let branchName: String
        let isManualRun: Bool
    }

    private struct WatchdogTerminationInfo {
        let summary: String
    }

    private struct ProcessSnapshot {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    struct XCResultFailureSummary: Equatable {
        let identifier: String
        let messages: [String]
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
        let configuredRepositoryRoot = URL(fileURLWithPath: settings.repositoryPath)
        let repositoryRoot = resolvedRepositorySourceURL(from: configuredRepositoryRoot)
        let branchWorkspace = workspaceFolder()

        prepareForRunStart()
        
        // Move all setup work to a serial background queue to avoid overlapping git operations.
        setupQueue.async { [weak self] in
            guard let self = self else { return }
            let previousPreparedRef = self.previouslyPreparedWorkspaceRef(in: branchWorkspace)

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
                self.ensureWorkspaceRemoteMatchesSourceSync(source: repositoryRoot, workspace: branchWorkspace)

                if !self.isUsableGitRepositorySync(at: branchWorkspace) {
                    print("TestRunner: Workspace git metadata is invalid, rebuilding before fetch")
                    DispatchQueue.main.async {
                        self.output += "Workspace git metadata is invalid. Recreating workspace...\n"
                    }
                    if !self.recreateWorkspaceSync(from: repositoryRoot, to: branchWorkspace) {
                        self.abortRun(removeCurrentRun: true)
                        self.showError(
                            "Failed to rebuild workspace",
                            message: "Could not recreate the temp workspace from the configured repository."
                        )
                        return
                    }
                }

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
            
            let shouldCleanForRefChange = Self.shouldCleanWorkspaceForRefChange(
                previousRef: previousPreparedRef,
                nextRef: branchToUse
            )

            if shouldCleanForRefChange {
                DispatchQueue.main.async {
                    self.output += "Branch changed from '\(previousPreparedRef ?? "unknown")' to '\(branchToUse)'. Cleaning workspace state...\n"
                }
                print("TestRunner: Branch changed from \(previousPreparedRef ?? "unknown") to \(branchToUse); cleaning disposable workspace state before checkout")
                if !self.cleanWorkspaceStateSync(in: branchWorkspace) {
                    self.abortRun(removeCurrentRun: true)
                    self.showError(
                        "Failed to clean workspace",
                        message: "Could not remove stale workspace state before checking out the requested ref."
                    )
                    return
                }
            }

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

            if !shouldCleanForRefChange {
                DispatchQueue.main.async {
                    self.output += "Branch unchanged. Reusing existing build state...\n"
                }
                print("TestRunner: Branch unchanged (\(branchToUse)); reusing existing build state")
            }
            self.recordPreparedWorkspaceRef(branchToUse)

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

            let preBuildScript = settings.preBuildScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preBuildScript.isEmpty {
                DispatchQueue.main.async {
                    self.output += "Running pre-build script...\n"
                }
                print("TestRunner: Running configured pre-build script")
                let preBuildResult = self.runShellScriptSync(
                    preBuildScript,
                    in: branchWorkspace,
                    label: "pre-build script"
                )
                if !preBuildResult.success {
                    let detail = preBuildResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = detail.isEmpty
                        ? "The configured pre-build script exited with status \(preBuildResult.terminationStatus)."
                        : "The configured pre-build script exited with status \(preBuildResult.terminationStatus).\n\nOutput:\n\(detail)"
                    self.abortRun(removeCurrentRun: true)
                    self.showError("Pre-build script failed", message: message)
                    return
                }
            }
            
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
        invalidateWatchdog()
        
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
        invalidateWatchdog()
    }
    
    private struct GitCommandResult {
        let success: Bool
        let output: String
    }

    private struct ShellCommandResult {
        let success: Bool
        let output: String
        let terminationStatus: Int32
    }

    @discardableResult
    private func runCommandSync(_ executablePath: String, arguments: [String]) -> ShellCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let outputHandle = pipe.fileHandleForReading
        let outputLock = NSLock()
        var collectedOutput = Data()

        do {
            // Drain command output while the subprocess is still running.
            // Commands like xcresulttool can emit enough JSON to fill the pipe
            // buffer and deadlock if we wait for exit before reading.
            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputLock.lock()
                collectedOutput.append(data)
                outputLock.unlock()
            }

            try process.run()
            process.waitUntilExit()
            outputHandle.readabilityHandler = nil

            let trailingData = outputHandle.readDataToEndOfFile()
            if !trailingData.isEmpty {
                outputLock.lock()
                collectedOutput.append(trailingData)
                outputLock.unlock()
            }

            outputLock.lock()
            let outputString = String(data: collectedOutput, encoding: .utf8) ?? ""
            outputLock.unlock()
            return ShellCommandResult(
                success: process.terminationStatus == 0,
                output: outputString,
                terminationStatus: process.terminationStatus
            )
        } catch {
            outputHandle.readabilityHandler = nil
            return ShellCommandResult(
                success: false,
                output: "Failed to run \(executablePath): \(error.localizedDescription)",
                terminationStatus: -1
            )
        }
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

    @discardableResult
    private func runShellScriptSync(
        _ script: String,
        in directory: URL,
        label: String
    ) -> ShellCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
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
            if !success {
                let trimmedOutput = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                print("TestRunner: \(label) failed with exit status \(process.terminationStatus)")
                if !trimmedOutput.isEmpty {
                    print("TestRunner: \(label) output: \(trimmedOutput)")
                }
            }

            return ShellCommandResult(
                success: success,
                output: outputString,
                terminationStatus: process.terminationStatus
            )
        } catch {
            let message = "Failed to run \(label): \(error.localizedDescription)"
            print("TestRunner: \(message)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "\(message)\n"
            }
            return ShellCommandResult(success: false, output: message, terminationStatus: -1)
        }
    }
    
    private func cloneRepositorySync(from source: URL, to destination: URL) -> Bool {
        // Remove --depth 1 to get all branches (needed for branch checkout).
        let result = runGitCommandSync(["clone", "file://\(source.path)", destination.path])
        guard result.success else {
            return false
        }

        return fetchSourceRemoteTrackingBranchesSync(in: destination).success
    }

    private func resolvedRepositorySourceURL(from configuredURL: URL) -> URL {
        let commonDirResult = runGitCommandSync(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: configuredURL,
            suppressFailureLogging: true
        )

        guard commonDirResult.success else {
            return configuredURL
        }

        let commonDirPath = commonDirResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonDirPath.isEmpty else {
            return configuredURL
        }

        let commonDirURL = URL(fileURLWithPath: commonDirPath)
        guard commonDirURL.lastPathComponent == ".git" else {
            return configuredURL
        }

        let durableSourceURL = commonDirURL.deletingLastPathComponent()
        if durableSourceURL.path != configuredURL.path {
            print("TestRunner: Normalized repository source from \(configuredURL.path) to \(durableSourceURL.path)")
        }
        return durableSourceURL
    }

    private func fetchRepositorySync(in directory: URL) -> GitCommandResult {
        let sourceBranchFetch = runGitCommandSync(["fetch", "origin"], in: directory)
        guard sourceBranchFetch.success else {
            return sourceBranchFetch
        }

        let sourceRemoteTrackingFetch = fetchSourceRemoteTrackingBranchesSync(in: directory)
        return GitCommandResult(
            success: sourceRemoteTrackingFetch.success,
            output: sourceBranchFetch.output + sourceRemoteTrackingFetch.output
        )
    }

    private func fetchSourceRemoteTrackingBranchesSync(in directory: URL) -> GitCommandResult {
        runGitCommandSync(
            ["fetch", "origin", Self.sourceRemoteTrackingFetchRefspec],
            in: directory
        )
    }

    private func isUsableGitRepositorySync(at directory: URL) -> Bool {
        runGitCommandSync(["rev-parse", "--git-dir"], in: directory, suppressFailureLogging: true).success
    }

    private func ensureWorkspaceRemoteMatchesSourceSync(source: URL, workspace: URL) {
        let expectedRemote = "file://\(source.path)"
        let currentRemoteResult = runGitCommandSync(
            ["config", "--get", "remote.origin.url"],
            in: workspace,
            suppressFailureLogging: true
        )
        let currentRemote = currentRemoteResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard currentRemote != expectedRemote else {
            return
        }

        if currentRemote.isEmpty {
            print("TestRunner: Setting workspace origin to \(expectedRemote)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "Configuring workspace remote...\n"
            }
            _ = runGitCommandSync(["remote", "add", "origin", expectedRemote], in: workspace)
            return
        }

        print("TestRunner: Updating workspace origin from \(currentRemote) to \(expectedRemote)")
        DispatchQueue.main.async { [weak self] in
            self?.output += "Updating workspace remote...\n"
        }
        _ = runGitCommandSync(["remote", "set-url", "origin", expectedRemote], in: workspace)
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
        if localBranchExists(ref, in: directory) || originBranchExists(ref, in: directory) {
            let checkoutResult = runGitCommandSync(["checkout", ref], in: directory)
            if !checkoutResult.success {
                return false
            }
            return resetToRemoteBranch(ref, in: directory)
        }

        if mirroredSourceRemoteBranchExists(ref, in: directory) {
            let mirroredRef = Self.mirroredSourceRemoteTrackingRef(for: ref)
            let checkoutResult = runGitCommandSync(["checkout", "-B", ref, mirroredRef], in: directory)
            if !checkoutResult.success {
                return false
            }
            return resetToRemoteBranch(ref, in: directory)
        }

        // Fallback for commit SHA/short SHA: detached checkout.
        let detachedCheckout = runGitCommandSync(["checkout", "--detach", ref], in: directory)
        return detachedCheckout.success
    }

    static func mirroredSourceRemoteTrackingRef(for branchName: String) -> String {
        "refs/remotes/source-origin/\(branchName)"
    }

    private func localBranchExists(_ ref: String, in directory: URL) -> Bool {
        runGitCommandSync(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(ref)"],
            in: directory,
            suppressFailureLogging: true
        ).success
    }

    private func originBranchExists(_ ref: String, in directory: URL) -> Bool {
        runGitCommandSync(
            ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(ref)"],
            in: directory,
            suppressFailureLogging: true
        ).success
    }

    private func mirroredSourceRemoteBranchExists(_ ref: String, in directory: URL) -> Bool {
        runGitCommandSync(
            ["show-ref", "--verify", "--quiet", Self.mirroredSourceRemoteTrackingRef(for: ref)],
            in: directory,
            suppressFailureLogging: true
        ).success
    }
    
    private func abortRun(removeCurrentRun: Bool) {
        DispatchQueue.main.async {
            self.invalidateWatchdog()
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
        let resetTarget: String
        if originBranchExists(branchName, in: directory) {
            resetTarget = "origin/\(branchName)"
        } else if mirroredSourceRemoteBranchExists(branchName, in: directory) {
            resetTarget = Self.mirroredSourceRemoteTrackingRef(for: branchName)
        } else {
            print("TestRunner: Remote branch for '\(branchName)' does not exist, skipping reset")
            return true
        }
        
        // Reset local branch to match remote.
        let resetResult = runGitCommandSync(["reset", "--hard", resetTarget], in: directory)
        return resetResult.success
    }

    private func cleanWorkspaceStateSync(in directory: URL) -> Bool {
        let resetResult = runGitCommandSync(["reset", "--hard", "HEAD"], in: directory)
        guard resetResult.success else {
            return false
        }

        let cleanResult = runGitCommandSync(["clean", "-ffd"], in: directory)
        guard cleanResult.success else {
            return false
        }

        for directoryName in Self.workspaceBuildArtifactDirectoryNames {
            let artifactURL = directory.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: artifactURL.path) else { continue }

            do {
                try fileManager.removeItem(at: artifactURL)
                print("TestRunner: Removed stale build artifact directory: \(artifactURL.path)")
                DispatchQueue.main.async { [weak self] in
                    self?.output += "Removed stale build artifact directory '\(directoryName)'.\n"
                }
            } catch {
                print("TestRunner: Failed to remove build artifact directory \(artifactURL.path): \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.output += "Error: Failed to remove build artifact directory '\(directoryName)': \(error.localizedDescription)\n"
                }
                return false
            }
        }

        return true
    }

    private func previouslyPreparedWorkspaceRef(in directory: URL) -> String? {
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) else {
            return nil
        }

        let storedRef = UserDefaults.standard.string(forKey: Self.lastPreparedWorkspaceRefKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedRef, !storedRef.isEmpty {
            return storedRef
        }

        let currentBranchResult = runGitCommandSync(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: directory,
            suppressFailureLogging: true
        )
        let currentBranch = currentBranchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentBranchResult.success, !currentBranch.isEmpty {
            return currentBranch
        }

        let currentCommitResult = runGitCommandSync(
            ["rev-parse", "--short", "HEAD"],
            in: directory,
            suppressFailureLogging: true
        )
        let currentCommit = currentCommitResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return currentCommit.isEmpty ? nil : currentCommit
    }

    private func recordPreparedWorkspaceRef(_ ref: String) {
        UserDefaults.standard.set(ref, forKey: Self.lastPreparedWorkspaceRefKey)
    }

    private func currentCommitSHASync(in directory: URL) -> String? {
        let previousDirectory = fileManager.currentDirectoryPath
        fileManager.changeCurrentDirectoryPath(directory.path)
        defer {
            fileManager.changeCurrentDirectoryPath(previousDirectory)
        }

        let result = runCommandSync("/usr/bin/git", arguments: ["rev-parse", "HEAD"])
        guard result.success else {
            return nil
        }

        let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
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
            testRun.commitSHA = currentCommitSHASync(in: workspaceDirectory)
            currentTestRun = testRun
            sendTestStartNotification(branchName: branchName)
        }

        let escapedWorkspacePath = shellEscape(workspaceURL.path)
        let escapedScheme = shellEscape("Loopy Pro (macOS)")
        let escapedDestination = shellEscape("platform=macOS,arch=arm64")
        let escapedDerivedDataPath = shellEscape(workspaceBuildArtifactDirectory(in: workspaceDirectory).path)
        let performanceArguments = Self.xcodebuildPerformanceArguments()
            .map(shellEscape)
            .joined(separator: " ")
        let parallelBuildArguments = xcodebuildParallelBuildArguments(
            workspaceURL: workspaceURL,
            workspaceDirectory: workspaceDirectory,
            schemeName: "Loopy Pro (macOS)",
            settings: SettingsStore.shared
        )
            .map(shellEscape)
            .joined(separator: " ")
        let parallelTestingArguments = xcodebuildParallelTestingArguments(from: SettingsStore.shared)
            .map(shellEscape)
            .joined(separator: " ")
        let optionalPerformanceArguments = performanceArguments.isEmpty ? "" : " \(performanceArguments)"
        let optionalParallelBuildArguments = parallelBuildArguments.isEmpty ? "" : " \(parallelBuildArguments)"
        let optionalParallelArguments = parallelTestingArguments.isEmpty ? "" : " \(parallelTestingArguments)"
        let xcodebuildCommand = """
        /usr/bin/xcodebuild -workspace \(escapedWorkspacePath) -scheme \(escapedScheme) -destination \(escapedDestination) -derivedDataPath \(escapedDerivedDataPath)\(optionalPerformanceArguments)\(optionalParallelBuildArguments)\(optionalParallelArguments) build-for-testing && /usr/bin/xcodebuild -workspace \(escapedWorkspacePath) -scheme \(escapedScheme) -destination \(escapedDestination) -derivedDataPath \(escapedDerivedDataPath)\(optionalPerformanceArguments)\(optionalParallelArguments) test-without-building
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
            xcbeautifyProcess.arguments = Self.xcbeautifyArguments() // Preserve original failure lines alongside formatted output
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
            self.invalidateWatchdog()
            
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
            
            // Wait a moment for all async updates to complete, then capture output on main thread.
            // Any expensive xcresult parsing runs off-main to avoid blocking AppKit's run loop.
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

                guard var testRun = self.currentTestRun else {
                    self.watchdogTerminationInfo = nil
                    self.startNextQueuedRunIfNeeded()
                    return
                }

                let finalOutput = self.output
                let passingCount = self.passingCount
                let failingCount = self.failingCount
                let watchdogTerminationInfo = self.watchdogTerminationInfo

                let duration = Date().timeIntervalSince(testRun.timestamp)
                testRun.duration = duration
                testRun.outputLog = finalOutput
                testRun.passingCount = passingCount
                testRun.failingCount = failingCount

                let countedTotal = passingCount + failingCount
                testRun.totalCount = countedTotal > 0 ? countedTotal : nil

                if countedTotal > 0 {
                    UserDefaults.standard.set(countedTotal, forKey: Self.totalCountKey)
                }

                if let watchdogTerminationInfo {
                    testRun.status = .error
                    testRun.errorDescription = watchdogTerminationInfo.summary
                } else if finalOutput.contains("** BUILD FAILED **") || finalOutput.contains("BUILD FAILED") {
                    testRun.status = .error
                    testRun.errorDescription = self.extractError(from: finalOutput)
                } else if finalOutput.contains("error:") || finalOutput.contains("*** Terminating") || finalOutput.contains("❌") {
                    testRun.status = .error
                    testRun.errorDescription = self.extractError(from: finalOutput)
                } else if failingCount > 0 || self.outputContainsRealTestFailure(finalOutput) {
                    testRun.status = .failed
                } else if finalOutput.contains("warning:") || finalOutput.contains("⚠️") {
                    testRun.status = .warnings
                } else if finalOutput.contains("✅") || finalOutput.contains("** TEST SUCCEEDED **") || finalOutput.contains("TEST SUCCEEDED") {
                    testRun.status = .success
                } else {
                    testRun.status = failingCount > 0 ? .failed : .success
                }

                let shouldAppendFailureSummary = testRun.status == .failed || testRun.status == .error

                DispatchQueue.global(qos: .userInitiated).async {
                    let summarySuffix: String
                    if shouldAppendFailureSummary,
                       let failureSummary = self.buildLatestXCResultFailureSummary(in: workspaceDirectory),
                       !failureSummary.isEmpty {
                        let separator = finalOutput.hasSuffix("\n") || finalOutput.isEmpty ? "" : "\n"
                        summarySuffix = separator + failureSummary
                    } else {
                        summarySuffix = ""
                    }

                    let outputWithSummary = finalOutput + summarySuffix

                    DispatchQueue.main.async {
                        testRun.outputLog = outputWithSummary
                        if !summarySuffix.isEmpty {
                            self.output += summarySuffix
                        }
                        self.currentTestRun = testRun

                        self.sendTestCompletionNotification(testRun: testRun)
                        self.watchdogTerminationInfo = nil
                        self.startNextQueuedRunIfNeeded()
                    }
                }
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
        invalidateWatchdog()
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
        testPhaseStartedAt = nil
        lastTestProgressAt = nil
        watchdogTerminationInfo = nil
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
            if line.localizedCaseInsensitiveContains("Test failure summary from ") {
                continue
            }
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

    private func buildLatestXCResultFailureSummary(in workspaceDirectory: URL) -> String? {
        guard let resultBundleURL = latestXCResultBundle(in: workspaceDirectory) else {
            return "Tests failed. No .xcresult bundle was found under \(testLogsDirectory(in: workspaceDirectory).path)"
        }

        let temporaryParentDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Tests-xcresult-\(UUID().uuidString)", isDirectory: true)
        let temporaryBundleURL = temporaryParentDirectory.appendingPathComponent(resultBundleURL.lastPathComponent, isDirectory: true)

        do {
            try fileManager.createDirectory(at: temporaryParentDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: resultBundleURL, to: temporaryBundleURL)
        } catch {
            try? fileManager.removeItem(at: temporaryParentDirectory)
            return """
            Test failure summary from \(resultBundleURL.lastPathComponent):
              Couldn't copy result bundle for summary: \(resultBundleURL.path)
              Copy error: \(error.localizedDescription)
            Result bundle: \(resultBundleURL.path)
            """
        }

        defer {
            try? fileManager.removeItem(at: temporaryParentDirectory)
        }

        let commandResult = runCommandSync(
            "/usr/bin/xcrun",
            arguments: [
                "xcresulttool",
                "get",
                "test-results",
                "tests",
                "--path",
                temporaryBundleURL.path,
                "--compact"
            ]
        )

        guard commandResult.success else {
            let trimmedOutput = commandResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return """
                Test failure summary from \(resultBundleURL.lastPathComponent):
                  Unable to extract structured failure details from \(resultBundleURL.path)
                Result bundle: \(resultBundleURL.path)
                """
            }

            return """
            Test failure summary from \(resultBundleURL.lastPathComponent):
              Unable to extract structured failure details from \(resultBundleURL.path)
              xcresulttool output: \(trimmedOutput)
            Result bundle: \(resultBundleURL.path)
            """
        }

        guard
            let data = commandResult.output.data(using: .utf8),
            let failures = Self.parseXCResultFailureSummaries(from: data)
        else {
            return """
            Test failure summary from \(resultBundleURL.lastPathComponent):
              Unable to extract structured failure details from \(resultBundleURL.path)
            Result bundle: \(resultBundleURL.path)
            """
        }

        var lines = ["Test failure summary from \(resultBundleURL.lastPathComponent):"]
        if failures.isEmpty {
            lines.append("  No failed test cases were found in the xcresult test report.")
        } else {
            for failure in failures {
                lines.append(failure.identifier)
                for message in failure.messages {
                    lines.append("  \(message)")
                }
                lines.append("")
            }

            if lines.last?.isEmpty == true {
                lines.removeLast()
            }
        }
        lines.append("Result bundle: \(resultBundleURL.path)")
        return lines.joined(separator: "\n")
    }

    private func testLogsDirectory(in workspaceDirectory: URL) -> URL {
        workspaceBuildArtifactDirectory(in: workspaceDirectory)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Test", isDirectory: true)
    }

    private func latestXCResultBundle(in workspaceDirectory: URL) -> URL? {
        let testLogsURL = testLogsDirectory(in: workspaceDirectory)
        guard let bundleURLs = try? fileManager.contentsOfDirectory(
            at: testLogsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return bundleURLs
            .filter { $0.pathExtension == "xcresult" && $0.lastPathComponent.hasPrefix("Test-") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    static func parseXCResultFailureSummaries(from data: Data) -> [XCResultFailureSummary]? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let root = jsonObject as? [String: Any]
        else {
            return nil
        }

        let testNodes = root["testNodes"] as? [[String: Any]] ?? []
        var failures: [XCResultFailureSummary] = []
        for node in testNodes {
            collectXCResultFailures(in: node, into: &failures)
        }
        return failures
    }

    private static func collectXCResultFailures(in node: [String: Any], into failures: inout [XCResultFailureSummary]) {
        let children = node["children"] as? [[String: Any]] ?? []

        let nodeType = node["nodeType"] as? String
        let result = node["result"] as? String
        if nodeType == "Test Case", result == "Failed" {
            let identifier = ((node["nodeIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? ((node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Unknown failed test"

            let messages = uniqueFailureMessages(from: collectXCResultFailureMessages(in: node))
            failures.append(
                XCResultFailureSummary(
                    identifier: identifier,
                    messages: messages.isEmpty ? ["No failure message text was present in the xcresult data."] : messages
                )
            )
        }

        for child in children {
            collectXCResultFailures(in: child, into: &failures)
        }
    }

    private static func collectXCResultFailureMessages(in node: [String: Any]) -> [String] {
        var messages: [String] = []

        let nodeType = node["nodeType"] as? String
        if nodeType == "Failure Message",
           let name = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            if let documentLocation = formattedXCResultDocumentLocation(from: node["documentLocationInCreatingWorkspace"] as? [String: Any]) {
                messages.append("\(documentLocation): \(name)")
            } else {
                messages.append(name)
            }
        }

        let children = node["children"] as? [[String: Any]] ?? []
        for child in children {
            messages.append(contentsOf: collectXCResultFailureMessages(in: child))
        }

        return messages
    }

    private static func uniqueFailureMessages(from messages: [String]) -> [String] {
        var seen = Set<String>()
        var uniqueMessages: [String] = []

        for message in messages {
            if seen.insert(message).inserted {
                uniqueMessages.append(message)
            }
        }

        return uniqueMessages
    }

    private static func formattedXCResultDocumentLocation(from location: [String: Any]?) -> String? {
        guard let location else { return nil }

        let fileURLString = (location["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filePath = fileURLString.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            if let url = URL(string: value), url.isFileURL {
                return url.path
            }
            return value
        }

        let lineNumber = (location["lineNumber"] as? Int)
            ?? Int((location["lineNumber"] as? String) ?? "")

        if let filePath, let lineNumber {
            return "\(filePath):\(lineNumber)"
        }
        if let filePath {
            return filePath
        }
        if let lineNumber {
            return "line \(lineNumber)"
        }
        return nil
    }

    private func outputContainsRealTestFailure(_ output: String) -> Bool {
        if output.contains("** TEST FAILED **") || output.contains("TEST FAILED") {
            return true
        }

        for line in output.components(separatedBy: .newlines) {
            if Self.isFailedTestResultLine(line) {
                return true
            }
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
                recordTestProgress()
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
            } else if Self.isXcodebuildTestCaseLine(line) {
                // Standard xcodebuild format: "Test Case '-[ClassName testMethod]' passed/failed"
                testName = Self.extractTestNameFromTestCaseLine(line)
                if Self.isPassedTestResultLine(line) {
                    isPassed = true
                } else if Self.isFailedTestResultLine(line) {
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
                        recordTestProgress()
                        updateCurrentTestRunCounts()
                    }
                } else if isFailed {
                    if !failedTestNames.contains(name) && !passedTestNames.contains(name) {
                        // Only count as failed if not already passed
                        failedTestNames.insert(name)
                        failingCount = failedTestNames.count
                        recordTestProgress()
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
    
    static func isXcodebuildTestCaseLine(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("test case")
    }

    static func isFailedTestResultLine(_ line: String) -> Bool {
        guard isXcodebuildTestCaseLine(line) else { return false }
        return line.localizedCaseInsensitiveContains("failed")
    }

    static func isPassedTestResultLine(_ line: String) -> Bool {
        guard isXcodebuildTestCaseLine(line) else { return false }
        return line.localizedCaseInsensitiveContains("passed")
    }

    static func extractTestNameFromTestCaseLine(_ line: String) -> String? {
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

    private func recordTestProgress(at now: Date = Date()) {
        guard isRunning, !isBuilding else { return }

        if testPhaseStartedAt == nil {
            testPhaseStartedAt = now
        }
        lastTestProgressAt = now
        scheduleWatchdogIfNeeded()
    }

    private func scheduleWatchdogIfNeeded() {
        guard watchdogTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + Self.defaultWatchdogCheckInterval, repeating: Self.defaultWatchdogCheckInterval)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.evaluateWatchdog()
            }
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func invalidateWatchdog() {
        watchdogTimer?.setEventHandler {}
        watchdogTimer?.cancel()
        watchdogTimer = nil
        testPhaseStartedAt = nil
        lastTestProgressAt = nil
    }

    private func evaluateWatchdog(now: Date = Date()) {
        let timeout = Self.xcodebuildTestInactivityTimeoutInterval(from: SettingsStore.shared)
        guard
            Self.watchdogShouldTrigger(
                isBuilding: isBuilding,
                testPhaseStartedAt: testPhaseStartedAt,
                lastProgressAt: lastTestProgressAt,
                now: now,
                timeout: timeout
            )
        else {
            return
        }

        let summary = Self.watchdogTimeoutDescription(
            now: now,
            testPhaseStartedAt: testPhaseStartedAt,
            lastProgressAt: lastTestProgressAt,
            timeout: timeout,
            passingCount: passingCount,
            failingCount: failingCount,
            totalCount: totalCount
        )
        handleWatchdogTimeout(summary: summary)
    }

    private func handleWatchdogTimeout(summary: String) {
        guard watchdogTerminationInfo == nil else { return }

        watchdogTerminationInfo = WatchdogTerminationInfo(summary: summary)
        invalidateWatchdog()

        if var testRun = currentTestRun {
            testRun.status = .error
            testRun.errorDescription = summary
            currentTestRun = testRun
        }

        let rootProcessIDs = trackedRootProcessIDs()
        watchdogQueue.async { [weak self] in
            guard let self = self else { return }
            let diagnostics = self.collectWatchdogDiagnostics(summary: summary, rootProcessIDs: rootProcessIDs)
            DispatchQueue.main.async {
                guard self.watchdogTerminationInfo != nil else { return }

                if !diagnostics.isEmpty {
                    self.output += "\n\(diagnostics)\n"
                }

                if var testRun = self.currentTestRun {
                    testRun.status = .error
                    testRun.errorDescription = summary
                    self.currentTestRun = testRun
                }

                self.terminateProcessesForWatchdogTimeout(rootProcessIDs: rootProcessIDs)
            }
        }
    }

    private func terminateProcessesForWatchdogTimeout(rootProcessIDs: [Int32]) {
        process?.terminate()
        xcodebuildProcess?.terminate()

        let knownProcessIDs = Set(rootProcessIDs + collectProcessTree(rootProcessIDs: rootProcessIDs).map(\.pid))
        guard !knownProcessIDs.isEmpty else { return }

        watchdogQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }

            let livePIDs = knownProcessIDs.filter { self.isProcessAlive($0) }
            guard !livePIDs.isEmpty else { return }

            let result = self.runCommandSync("/bin/kill", arguments: ["-9"] + livePIDs.map(String.init))
            let forceKillMessage = result.success
                ? "Watchdog: force-killed lingering processes: \(livePIDs.map(String.init).joined(separator: ", "))"
                : "Watchdog: failed to force-kill lingering processes (\(livePIDs.map(String.init).joined(separator: ", "))): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"

            DispatchQueue.main.async {
                guard self.watchdogTerminationInfo != nil else { return }
                self.output += "\n\(forceKillMessage)\n"
            }
        }
    }

    private func trackedRootProcessIDs() -> [Int32] {
        var pids: [Int32] = []

        if let process, process.processIdentifier > 0 {
            pids.append(process.processIdentifier)
        }
        if let xcodebuildProcess, xcodebuildProcess.processIdentifier > 0 {
            pids.append(xcodebuildProcess.processIdentifier)
        }

        return Array(Set(pids)).sorted()
    }

    private func collectWatchdogDiagnostics(summary: String, rootProcessIDs: [Int32]) -> String {
        let snapshots = collectProcessTree(rootProcessIDs: rootProcessIDs)
        let interestingSnapshots = snapshots
            .filter { snapshot in
                let executable = URL(fileURLWithPath: snapshot.command).lastPathComponent.lowercased()
                return ["zsh", "xcodebuild", "xctest", "xcbeautify"].contains(executable)
            }
            .sorted { $0.pid < $1.pid }

        var sections: [String] = []
        sections.append("===== Watchdog Timeout =====")
        sections.append(summary)

        if interestingSnapshots.isEmpty {
            sections.append("No tracked xcodebuild/xctest processes were found when diagnostics were collected.")
            return sections.joined(separator: "\n")
        }

        sections.append("Processes:")
        sections.append(
            interestingSnapshots
                .map { "pid=\($0.pid) ppid=\($0.parentPID) cmd=\($0.command)" }
                .joined(separator: "\n")
        )

        for snapshot in interestingSnapshots {
            let executable = URL(fileURLWithPath: snapshot.command).lastPathComponent.lowercased()
            guard executable == "xcodebuild" || executable == "xctest" else { continue }

            let sampleResult = runCommandSync("/usr/bin/sample", arguments: [String(snapshot.pid), "1", "1"])
            let header = "----- sample \(snapshot.pid) (\(executable)) -----"
            let body = sampleResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(header)
            sections.append(body.isEmpty ? "sample produced no output" : body)
        }

        return sections.joined(separator: "\n")
    }

    private func collectProcessTree(rootProcessIDs: [Int32]) -> [ProcessSnapshot] {
        guard !rootProcessIDs.isEmpty else { return [] }

        let psResult = runCommandSync("/bin/ps", arguments: ["-axo", "pid=,ppid=,comm="])
        guard psResult.success else { return [] }

        let allSnapshots = psResult.output
            .split(whereSeparator: \.isNewline)
            .compactMap(Self.parseProcessSnapshot)
        let childrenByParent = Dictionary(grouping: allSnapshots, by: \.parentPID)
        var queue = Array(Set(rootProcessIDs))
        var visited = Set<Int32>()
        var collected: [ProcessSnapshot] = []

        while let pid = queue.first {
            queue.removeFirst()
            guard visited.insert(pid).inserted else { continue }

            if let snapshot = allSnapshots.first(where: { $0.pid == pid }) {
                collected.append(snapshot)
            }

            for child in childrenByParent[pid] ?? [] {
                queue.append(child.pid)
            }
        }

        return collected
    }

    private static func parseProcessSnapshot(from line: Substring) -> ProcessSnapshot? {
        let components = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard components.count == 3,
              let pid = Int32(components[0]),
              let parentPID = Int32(components[1]) else {
            return nil
        }
        return ProcessSnapshot(pid: pid, parentPID: parentPID, command: components[2].trimmingCharacters(in: .whitespaces))
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        let result = runCommandSync("/bin/kill", arguments: ["-0", String(pid)])
        return result.success
    }
    
    func killAllProcesses() {
        killCurrentProcess()
    }

    static func testStartNotificationContent(branchName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Tests Started"
        content.body = "Running tests on branch: \(branchName)"
        content.sound = .default
        content.categoryIdentifier = TestUserNotification.startCategoryIdentifier
        return content
    }
    
    private func sendTestStartNotification(branchName: String) {
        let center = UNUserNotificationCenter.current()
        let content = Self.testStartNotificationContent(branchName: branchName)
        
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

    static func xcodebuildParallelTestingArguments(enabled: Bool) -> [String] {
        guard enabled else { return [] }
        return ["-parallel-testing-enabled", "YES"]
    }

    static func xcodebuildPerformanceArguments() -> [String] {
        [
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "COMPILER_INDEX_STORE_ENABLE=NO",
            "DEBUG_INFORMATION_FORMAT=dwarf",
            "ENABLE_MODULE_VERIFIER=NO"
        ]
    }

    static func xcbeautifyArguments() -> [String] {
        [
            "--renderer", "terminal",
            "--preserve-unbeautified"
        ]
    }

    static func xcodebuildTestInactivityTimeoutInterval(from settings: SettingsStore) -> TimeInterval {
        TimeInterval(max(1, settings.testInactivityTimeoutMinutes) * 60)
    }

    static func watchdogShouldTrigger(
        isBuilding: Bool,
        testPhaseStartedAt: Date?,
        lastProgressAt: Date?,
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        guard !isBuilding,
              let testPhaseStartedAt,
              let lastProgressAt else {
            return false
        }

        guard now >= testPhaseStartedAt, now >= lastProgressAt else {
            return false
        }

        return now.timeIntervalSince(lastProgressAt) >= timeout
    }

    static func watchdogTimeoutDescription(
        now: Date,
        testPhaseStartedAt: Date?,
        lastProgressAt: Date?,
        timeout: TimeInterval,
        passingCount: Int,
        failingCount: Int,
        totalCount: Int
    ) -> String {
        let timeoutText = formatDuration(timeout)
        let idleText = lastProgressAt.map { formatDuration(now.timeIntervalSince($0)) } ?? "unknown"
        let testPhaseText = testPhaseStartedAt.map { formatDuration(now.timeIntervalSince($0)) } ?? "unknown"
        let countedTotal = max(totalCount, passingCount + failingCount)

        return "Watchdog timed out after \(idleText) without test progress (limit \(timeoutText)) during the test phase. Counted \(passingCount) passing, \(failingCount) failing, \(countedTotal) total. Test phase had been running for \(testPhaseText)."
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    static func xcodebuildParallelBuildArguments(enabled: Bool, jobCount: Int) -> [String] {
        guard enabled else { return [] }
        return ["-parallelizeTargets", "-jobs", String(max(1, jobCount))]
    }

    static func schemeParallelizeBuildablesSetting(from contents: String) -> Bool? {
        let pattern = /parallelizeBuildables\s*=\s*"(?<value>YES|NO)"/
        guard let match = contents.firstMatch(of: pattern) else {
            return nil
        }
        return match.output.value == "YES"
    }

    static func projectParallelizationSetting(from contents: String) -> Bool? {
        let pattern = /BuildIndependentTargetsInParallel\s*=\s*(?<value>YES|NO);/
        guard let match = contents.firstMatch(of: pattern) else {
            return nil
        }
        return match.output.value == "YES"
    }

    static let workspaceBuildArtifactDirectoryNames = [".DerivedData", "DerivedData", "build"]

    static func workspaceBuildArtifactDirectory(in workspaceDirectory: URL) -> URL {
        workspaceDirectory.appendingPathComponent(".DerivedData", isDirectory: true)
    }

    static func shouldCleanWorkspaceForRefChange(previousRef: String?, nextRef: String) -> Bool {
        let trimmedNextRef = nextRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNextRef.isEmpty else { return false }

        guard let previousRef = previousRef?.trimmingCharacters(in: .whitespacesAndNewlines), !previousRef.isEmpty else {
            return false
        }

        return previousRef != trimmedNextRef
    }

    private func xcodebuildParallelTestingArguments(from settings: SettingsStore) -> [String] {
        Self.xcodebuildParallelTestingArguments(enabled: settings.parallelTestingEnabled)
    }

    private func xcodebuildParallelBuildArguments(
        workspaceURL: URL,
        workspaceDirectory: URL,
        schemeName: String,
        settings: SettingsStore
    ) -> [String] {
        Self.xcodebuildParallelBuildArguments(
            enabled: buildParallelizationEnabled(
                workspaceURL: workspaceURL,
                workspaceDirectory: workspaceDirectory,
                schemeName: schemeName
            ),
            jobCount: settings.parallelBuildJobCount
        )
    }

    private func buildParallelizationEnabled(
        workspaceURL: URL,
        workspaceDirectory: URL,
        schemeName: String
    ) -> Bool {
        if let schemeValue = loadSchemeParallelizationSetting(
            workspaceURL: workspaceURL,
            workspaceDirectory: workspaceDirectory,
            schemeName: schemeName
        ) {
            return schemeValue
        }

        if let projectValue = loadProjectParallelizationSetting(
            workspaceURL: workspaceURL,
            workspaceDirectory: workspaceDirectory
        ) {
            return projectValue
        }

        return true
    }

    private func loadSchemeParallelizationSetting(
        workspaceURL: URL,
        workspaceDirectory: URL,
        schemeName: String
    ) -> Bool? {
        let candidateRoots = [workspaceURL.deletingLastPathComponent(), workspaceDirectory]
        for root in candidateRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard
                    fileURL.lastPathComponent == "\(schemeName).xcscheme",
                    let contents = try? String(contentsOf: fileURL),
                    let value = Self.schemeParallelizeBuildablesSetting(from: contents)
                else {
                    continue
                }
                return value
            }
        }

        return nil
    }

    private func loadProjectParallelizationSetting(
        workspaceURL: URL,
        workspaceDirectory: URL
    ) -> Bool? {
        let candidateRoots = [workspaceURL.deletingLastPathComponent(), workspaceDirectory]
        for root in candidateRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard
                    fileURL.lastPathComponent == "project.pbxproj",
                    let contents = try? String(contentsOf: fileURL),
                    let value = Self.projectParallelizationSetting(from: contents)
                else {
                    continue
                }
                return value
            }
        }

        return nil
    }

    private func workspaceBuildArtifactDirectory(in workspaceDirectory: URL) -> URL {
        Self.workspaceBuildArtifactDirectory(in: workspaceDirectory)
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
