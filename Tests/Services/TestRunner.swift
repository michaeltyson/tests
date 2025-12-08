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
    
    private let tempFolder: URL
    private let fileManager = FileManager.default
    
    private static let totalCountKey = "com.atastypixel.Tests.lastTotalCount"
    
    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        tempFolder = appSupport.appendingPathComponent("Tests/TempWorkspace", isDirectory: true)
    }
    
    func runTests(branchName: String? = nil) {
        print("TestRunner: runTests() called with branch: \(branchName ?? "nil")")
        
        // If paused, ignore the request
        if isPaused {
            print("TestRunner: Tests are paused, ignoring run request")
            return
        }
        
        // If already running, kill current process and start new one
        if isRunning {
            print("TestRunner: Test already running, killing current process")
            killCurrentProcess()
        }
        
        // Reset cancellation flag when starting new tests
        isCancelled = false
        
        let settings = SettingsStore.shared
        
        // Repository path is required
        guard !settings.repositoryPath.isEmpty else {
            print("TestRunner: ERROR - Repository path not configured. Please set it in Settings.")
            showError("Repository path not configured", message: "Please configure the repository path in Settings.")
            return
        }
        
        // Determine which branch to use: notification branch > settings branch > "develop"
        let branchToUse = branchName ?? settings.branchName ?? "develop"
        
        print("TestRunner: Using repository path: \(settings.repositoryPath)")
        print("TestRunner: Using branch: \(branchToUse)")
        let repositoryRoot = URL(fileURLWithPath: settings.repositoryPath)
        
        // Set running state and initialize output immediately so UI shows progress
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = true
            self.output = ""
            
            // Load total count from UserDefaults (from previous run)
            let savedTotalCount = UserDefaults.standard.integer(forKey: Self.totalCountKey)
            if savedTotalCount > 0 {
                self.totalCount = savedTotalCount
            }
            
            // Reset counts for new run
            self.passingCount = 0
            self.failingCount = 0
            self.passedTestNames.removeAll()
            self.failedTestNames.removeAll()
            self.isBuilding = true // Start in building phase
            
            var testRun = TestRun(status: .running)
            testRun.totalCount = savedTotalCount > 0 ? savedTotalCount : nil
            testRun.branchName = branchToUse
            self.currentTestRun = testRun
            
            // Send notification that tests have started
            self.sendTestStartNotification(branchName: branchToUse)
        }
        
        // Move all setup work to background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Verify repository path exists
            guard self.fileManager.fileExists(atPath: repositoryRoot.path) else {
                print("TestRunner: ERROR - Repository path does not exist: \(repositoryRoot.path)")
                self.showError("Repository path not found", message: "The configured repository path does not exist. Please check Settings.")
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return
            }
            
            // Ensure temp folder exists
            DispatchQueue.main.async {
                self.output += "Preparing workspace...\n"
            }
            do {
                try self.fileManager.createDirectory(at: self.tempFolder, withIntermediateDirectories: true)
                print("TestRunner: Temp folder ready: \(self.tempFolder.path)")
            } catch {
                print("TestRunner: ERROR - Failed to create temp folder: \(error)")
                self.showError("Failed to create temp folder", message: error.localizedDescription)
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return
            }
            
            // Clone or update repository (synchronous on background thread)
            if !self.fileManager.fileExists(atPath: self.tempFolder.appendingPathComponent(".git").path) {
                DispatchQueue.main.async {
                    self.output += "Cloning repository...\n"
                }
                print("TestRunner: Cloning repository...")
                self.cloneRepositorySync(from: repositoryRoot, to: self.tempFolder)
            } else {
                DispatchQueue.main.async {
                    self.output += "Pulling repository updates...\n"
                }
                print("TestRunner: Pulling repository updates...")
                self.pullRepositorySync(in: self.tempFolder)
            }
            
            // Checkout branch (always checkout, defaulting to "develop")
            DispatchQueue.main.async {
                self.output += "Checking out branch '\(branchToUse)'...\n"
            }
            print("TestRunner: Checking out branch: \(branchToUse)")
            if !self.checkoutBranchSync(branchToUse, in: self.tempFolder) {
                self.showError("Failed to checkout branch", message: "Could not checkout branch '\(branchToUse)'. Please verify the branch exists.")
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return
            }
            
            // Find workspace file within the cloned repository
            DispatchQueue.main.async {
                self.output += "Finding workspace...\n"
            }
            print("TestRunner: Searching for workspace file in: \(self.tempFolder.path)")
            guard let workspaceURL = WorkspaceFinder.findWorkspace(in: self.tempFolder) else {
                print("TestRunner: ERROR - Could not find .xcworkspace file in repository root")
                self.showError("Workspace not found", message: "Could not find .xcworkspace file in repository root. Please check the repository path in Settings.")
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return
            }
            
            print("TestRunner: Found workspace: \(workspaceURL.path)")
            
            // Run tests on main thread
            DispatchQueue.main.async {
                self.output += "Starting tests...\n\n"
                print("TestRunner: Starting xcodebuild tests...")
                self.runXcodebuildTests(workspaceURL: workspaceURL, testRun: self.currentTestRun!)
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
        guard let process = process else { return }
        process.terminate()
        // Don't wait synchronously - let it terminate in background
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
        }
        self.process = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
    }
    
    private func cloneRepositorySync(from source: URL, to destination: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Remove --depth 1 to get all branches (needed for branch checkout)
        process.arguments = ["clone", "file://\(source.path)", destination.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up output reading
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                guard let string = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.output += string
                }
            }
        }
        
        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                guard let string = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.output += string
                }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Clean up handlers
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
        } catch {
            print("Failed to clone repository: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "Error: Failed to clone repository: \(error.localizedDescription)\n"
            }
        }
    }
    
    private func pullRepositorySync(in directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["pull"]
        process.currentDirectoryURL = directory
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up output reading
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                guard let string = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.output += string
                }
            }
        }
        
        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                guard let string = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.output += string
                }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Clean up handlers
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
        } catch {
            print("Failed to pull repository: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "Error: Failed to pull repository: \(error.localizedDescription)\n"
            }
        }
    }
    
    private func checkoutBranchSync(_ branchName: String, in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", branchName]
        process.currentDirectoryURL = directory
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up output reading
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                guard let string = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.output += string
                }
            }
        }
        
        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                guard let string = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.output += string
                }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Clean up handlers
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            
            if process.terminationStatus == 0 {
                return true
            }
            
            // If checkout failed, read error output for debugging
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorString = String(data: errorData, encoding: .utf8) {
                print("TestRunner: Git checkout error: \(errorString)")
            }
            
            return false
        } catch {
            print("Failed to checkout branch: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.output += "Error: Failed to checkout branch: \(error.localizedDescription)\n"
            }
            return false
        }
    }
    
    private func runXcodebuildTests(workspaceURL: URL, testRun: TestRun) {
        // isRunning and output are already set in runTests()
        
        // Check if xcbeautify is available
        let xcbeautifyPaths = ["/usr/local/bin/xcbeautify", "/opt/homebrew/bin/xcbeautify"]
        var xcbeautifyPath: String?
        for path in xcbeautifyPaths {
            if fileManager.fileExists(atPath: path) {
                xcbeautifyPath = path
                break
            }
        }
        
        // Create xcodebuild process
        let xcodebuildProcess = Process()
        xcodebuildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        xcodebuildProcess.arguments = [
            "-workspace", workspaceURL.path,
            "-scheme", "Loopy Pro (macOS)",
            "-destination", "platform=macOS,arch=arm64",
            "test"
        ]
        xcodebuildProcess.currentDirectoryURL = tempFolder
        
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
                self.outputHandle = nil
                self.errorHandle = nil
                
                // Don't save if cancelled
                if self.isCancelled {
                    self.isCancelled = false
                    self.currentTestRun = nil
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
                    } else if self.failingCount > 0 || finalOutput.contains("** TEST FAILED **") || finalOutput.contains("TEST FAILED") || finalOutput.contains("failed") {
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
                if var testRun = self.currentTestRun {
                    testRun.status = .error
                    testRun.errorDescription = error.localizedDescription
                    self.currentTestRun = testRun
                }
            }
        }
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

