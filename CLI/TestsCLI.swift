import AppKit
import Foundation

private let triggerNotificationName = "com.atastypixel.Tests.TriggerRun"
private let appBundleIdentifier = "com.atastypixel.Tests"

@main
struct TestsCLI {
    private struct RunOptions {
        var commit: String?
        var branchName: String?
        var repositoryPath: String?
        var outputMode: TestsAPI.OutputMode = .failures
        var timeout: TimeInterval?
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printGeneralHelp()
            exit(64)
        }

        switch command {
        case "run":
            runCommand(arguments: Array(arguments.dropFirst()))
        case "trigger":
            triggerCommand(arguments: Array(arguments.dropFirst()))
        case "help", "--help", "-h":
            printGeneralHelp()
        default:
            writeError("Unknown command: \(command)\n")
            printGeneralHelp(toStandardError: true)
            exit(64)
        }
    }

    private static func runCommand(arguments: [String]) {
        if arguments.contains("--help") || arguments.contains("-h") {
            printRunHelp()
            return
        }

        let options: RunOptions
        do {
            options = try parseRunOptions(arguments)
        } catch {
            writeError("\(error.localizedDescription)\n\n")
            printRunHelp(toStandardError: true)
            exit(64)
        }

        guard let requestedCommit = options.commit else {
            writeError("Missing required option: --commit <commit>\n\n")
            printRunHelp(toStandardError: true)
            exit(64)
        }

        let repositoryPath: String
        do {
            repositoryPath = try resolveRepositoryPath(options.repositoryPath)
        } catch {
            writeError("\(error.localizedDescription)\n")
            exit(2)
        }

        let commitSHA: String
        do {
            commitSHA = try resolveCommit(requestedCommit, repositoryPath: repositoryPath)
        } catch {
            writeError("\(error.localizedDescription)\n")
            exit(2)
        }

        let request = TestsAPI.RunRequest(
            version: TestsAPI.protocolVersion,
            id: UUID(),
            commitSHA: commitSHA,
            branchName: options.branchName ?? currentBranch(in: repositoryPath),
            repositoryPath: repositoryPath,
            outputMode: options.outputMode,
            createdAt: Date()
        )

        let requestURL = TestsAPI.requestURL(for: request.id)
        let responseURL = TestsAPI.responseURL(for: request.id)

        do {
            try TestsAPI.prepareDirectories()
            try TestsAPI.write(request, to: requestURL)
            try launchAppIfNeeded()
        } catch {
            writeError("Unable to submit test run: \(error.localizedDescription)\n")
            try? FileManager.default.removeItem(at: requestURL)
            exit(2)
        }

        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        do {
            let response = try waitForResponse(
                requestID: request.id,
                responseURL: responseURL,
                timeout: options.timeout
            )
            printResponse(response, outputMode: options.outputMode)
            exit(exitCode(for: response.status))
        } catch {
            writeError("Tests run failed: \(error.localizedDescription)\n")
            exit(2)
        }
    }

    private static func triggerCommand(arguments: [String]) {
        if arguments.contains("--help") || arguments.contains("-h") {
            printTriggerHelp()
            return
        }

        var branchName: String?
        var commitSHA: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--branch":
                guard index + 1 < arguments.count else {
                    usageError("Missing value for --branch", help: printTriggerHelp)
                }
                branchName = arguments[index + 1]
                index += 2
            case "--commit":
                guard index + 1 < arguments.count else {
                    usageError("Missing value for --commit", help: printTriggerHelp)
                }
                commitSHA = arguments[index + 1]
                index += 2
            default:
                usageError("Unknown option: \(arguments[index])", help: printTriggerHelp)
            }
        }

        do {
            try launchAppIfNeeded()
        } catch {
            writeError("Failed to launch Tests: \(error.localizedDescription)\n")
            exit(1)
        }

        var userInfo: [String: Any] = [:]
        if let branchName { userInfo["branch"] = branchName }
        if let commitSHA { userInfo["commit"] = commitSHA }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(triggerNotificationName),
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo,
            deliverImmediately: true
        )
    }

    private static func parseRunOptions(_ arguments: [String]) throws -> RunOptions {
        var options = RunOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--commit":
                options.commit = try value(after: argument, at: index, in: arguments)
                index += 2
            case "--branch":
                options.branchName = try value(after: argument, at: index, in: arguments)
                index += 2
            case "--repository":
                options.repositoryPath = try value(after: argument, at: index, in: arguments)
                index += 2
            case "--output":
                let value = try value(after: argument, at: index, in: arguments)
                guard let outputMode = TestsAPI.OutputMode(rawValue: value) else {
                    throw CLIError("Invalid --output value '\(value)'; expected 'failures' or 'full'.")
                }
                options.outputMode = outputMode
                index += 2
            case "--timeout":
                let value = try value(after: argument, at: index, in: arguments)
                guard let timeout = TimeInterval(value), timeout > 0 else {
                    throw CLIError("Invalid --timeout value '\(value)'; expected a positive number of seconds.")
                }
                options.timeout = timeout
                index += 2
            default:
                throw CLIError("Unknown option: \(argument)")
            }
        }
        return options
    }

    private static func value(after option: String, at index: Int, in arguments: [String]) throws -> String {
        guard index + 1 < arguments.count else {
            throw CLIError("Missing value for \(option).")
        }
        return arguments[index + 1]
    }

    private static func waitForResponse(
        requestID: UUID,
        responseURL: URL,
        timeout: TimeInterval?
    ) throws -> TestsAPI.RunResponse {
        let startedAt = Date()
        var lastNotificationAt = Date.distantPast
        var wasAccepted = false

        while true {
            if let data = try? Data(contentsOf: responseURL),
               let response = try? TestsAPI.decoder().decode(TestsAPI.RunResponse.self, from: data) {
                guard response.version == TestsAPI.protocolVersion else {
                    throw CLIError("Tests uses an incompatible API protocol version (\(response.version)).")
                }
                switch response.state {
                case .accepted:
                    wasAccepted = true
                case .completed:
                    return response
                }
            }

            if let timeout, Date().timeIntervalSince(startedAt) >= timeout {
                throw CLIError("Timed out after \(formatDuration(timeout)) while waiting for Tests.")
            }

            if !wasAccepted, Date().timeIntervalSince(startedAt) >= 15 {
                throw CLIError(
                    "The Tests app did not accept the request. Make sure the running app version supports 'TestsCLI run'."
                )
            }

            if wasAccepted && !isAppRunning() {
                throw CLIError("The Tests app exited before the run completed.")
            }

            if !wasAccepted && Date().timeIntervalSince(lastNotificationAt) >= 1 {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name(TestsAPI.requestNotificationName),
                    object: nil,
                    userInfo: ["requestID": requestID.uuidString],
                    deliverImmediately: true
                )
                lastNotificationAt = Date()
            }

            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func printResponse(_ response: TestsAPI.RunResponse, outputMode: TestsAPI.OutputMode) {
        let status = (response.status ?? "error").uppercased()
        let shortSHA = String(response.commitSHA.prefix(12))
        var details: [String] = []
        if let passing = response.passingCount { details.append("\(passing) passed") }
        if let failing = response.failingCount { details.append("\(failing) failed") }
        if let duration = response.duration { details.append(formatDuration(duration)) }

        let suffix = details.isEmpty ? "" : " — " + details.joined(separator: ", ")
        print("\(status) \(shortSHA)\(suffix)")

        switch outputMode {
        case .failures:
            let failureText = response.failureSummary ?? response.errorDescription
            if let failureText, !failureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("\n\(failureText.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        case .full:
            if let output = response.outputLog, !output.isEmpty {
                print("\n\(output)", terminator: output.hasSuffix("\n") ? "" : "\n")
            } else if let error = response.errorDescription, !error.isEmpty {
                print("\n\(error)")
            }
        }
    }

    private static func exitCode(for status: String?) -> Int32 {
        switch status {
        case "success", "warnings": return 0
        case "failed": return 1
        default: return 2
        }
    }

    private static func resolveRepositoryPath(_ suppliedPath: String?) throws -> String {
        let path = suppliedPath ?? FileManager.default.currentDirectoryPath
        return try runGit(["-C", path, "rev-parse", "--show-toplevel"])
    }

    private static func resolveCommit(_ commit: String, repositoryPath: String) throws -> String {
        try runGit(["-C", repositoryPath, "rev-parse", "--verify", "\(commit)^{commit}"])
    }

    private static func currentBranch(in repositoryPath: String) -> String? {
        try? runGit(["-C", repositoryPath, "symbolic-ref", "--quiet", "--short", "HEAD"])
    }

    private static func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError("Unable to run git: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !output.isEmpty else {
            throw CLIError(output.isEmpty ? "Git command failed." : output)
        }
        return output
    }

    private static func launchAppIfNeeded() throws {
        guard !isAppRunning() else { return }
        guard let appURL = findAppBundle() else {
            throw CLIError("Could not find Tests.app. Install it in /Applications or run the bundled TestsCLI executable.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        if let launchError { throw launchError }

        let deadline = Date().addingTimeInterval(5)
        while !isAppRunning(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard isAppRunning() else {
            throw CLIError("Tests.app did not finish launching.")
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func isAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleIdentifier }
    }

    private static func findAppBundle() -> URL? {
        var executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        while executableURL.path != "/" {
            if executableURL.pathExtension == "app" { return executableURL }
            executableURL.deleteLastPathComponent()
        }

        for path in [
            "/Applications/Tests.app",
            NSHomeDirectory() + "/Applications/Tests.app",
            NSHomeDirectory() + "/Desktop/Tests.app"
        ] where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    private static func printGeneralHelp(toStandardError: Bool = false) {
        write("""
        Usage: TestsCLI <command> [options]

        Commands:
          run       Run an exact commit in the Tests-owned environment and wait for the result.
          trigger   Asynchronously ask Tests to start a run.

        Run 'TestsCLI <command> --help' for command-specific help.
        """ + "\n", toStandardError: toStandardError)
    }

    private static func printRunHelp(toStandardError: Bool = false) {
        write("""
        Usage: TestsCLI run --commit <commit> [options]

        Runs the exact commit in the disposable workspace owned by Tests and blocks until
        completion. If that commit is already running or queued, this command attaches to
        the existing run. A different active commit is allowed to finish first.

        Options:
          --commit <commit>       Required. A commit SHA or Git revision such as HEAD.
          --repository <path>     Repository or worktree containing the commit.
                                  Defaults to the current directory's repository.
          --branch <name>         Branch label shown in Tests. Detected automatically when possible.
          --output <mode>         'failures' (default) prints only the result and failure details;
                                  'full' prints the complete Tests-owned build and test log.
          --timeout <seconds>     Stop waiting after this many seconds. The Tests run continues.
          -h, --help              Show this help.

        Exit status:
          0  Tests passed (warnings are considered a pass).
          1  One or more tests failed.
          2  Tests could not run, the app exited, or the request timed out.
         64  Invalid command-line usage.

        Examples:
          TestsCLI run --commit HEAD
          TestsCLI run --commit "$(git rev-parse HEAD)" --output failures
          TestsCLI run --commit HEAD --output full --timeout 3600
        """ + "\n", toStandardError: toStandardError)
    }

    private static func printTriggerHelp(toStandardError: Bool = false) {
        write("""
        Usage: TestsCLI trigger [--commit <commit-sha>] [--branch <branch-name>]

        Sends an asynchronous run request and exits immediately. Git hooks should supply
        both the exact commit SHA and its branch name. Use 'run' when a caller needs the
        authoritative result.

        Options:
          --commit <commit-sha>   Exact commit to test.
          --branch <branch-name>  Branch label, or legacy branch/ref to test when no commit is given.
          -h, --help              Show this help.
        """ + "\n", toStandardError: toStandardError)
    }

    private static func usageError(_ message: String, help: (Bool) -> Void) -> Never {
        writeError("\(message)\n\n")
        help(true)
        exit(64)
    }

    private static func write(_ string: String, toStandardError: Bool) {
        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data(string.utf8))
    }

    private static func writeError(_ string: String) {
        write(string, toStandardError: true)
    }

    private struct CLIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
