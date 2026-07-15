import Foundation

extension Notification.Name {
    static let testRunDidComplete = Notification.Name("com.atastypixel.Tests.TestRunDidComplete")
}

final class TestAPIController {
    private let testRunner: TestRunner
    private let fileManager: FileManager
    private var requestObserver: NSObjectProtocol?
    private var completionObserver: NSObjectProtocol?
    private var requestsByID: [UUID: TestsAPI.RunRequest] = [:]
    private var requestIDsByCommit: [String: Set<UUID>] = [:]

    init(testRunner: TestRunner, fileManager: FileManager = .default) {
        self.testRunner = testRunner
        self.fileManager = fileManager
    }

    func start() {
        do {
            try TestsAPI.prepareDirectories(fileManager: fileManager)
            removeStaleFiles()
        } catch {
            print("TestAPIController: Failed to prepare API directories: \(error)")
        }

        requestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(TestsAPI.requestNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRequestNotification(notification)
        }

        completionObserver = NotificationCenter.default.addObserver(
            forName: .testRunDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let testRun = notification.userInfo?["testRun"] as? TestRun else { return }
            self?.handleCompletedRun(testRun)
        }
    }

    deinit {
        if let requestObserver {
            DistributedNotificationCenter.default().removeObserver(requestObserver)
        }
        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
        }
    }

    private func handleRequestNotification(_ notification: Notification) {
        guard
            let requestIDString = notification.userInfo?["requestID"] as? String,
            let requestID = UUID(uuidString: requestIDString)
        else {
            print("TestAPIController: Ignoring request notification without a valid request ID")
            return
        }

        if let responseData = try? Data(contentsOf: TestsAPI.responseURL(for: requestID)),
           let existingResponse = try? TestsAPI.decoder().decode(TestsAPI.RunResponse.self, from: responseData),
           existingResponse.state == .completed {
            return
        }

        if let existingRequest = requestsByID[requestID] {
            writeAcceptedResponse(for: existingRequest)
            return
        }

        let requestURL = TestsAPI.requestURL(for: requestID)
        let request: TestsAPI.RunRequest
        do {
            let data = try Data(contentsOf: requestURL)
            request = try TestsAPI.decoder().decode(TestsAPI.RunRequest.self, from: data)
        } catch {
            print("TestAPIController: Could not read request \(requestID): \(error)")
            writeErrorResponse(
                requestID: requestID,
                commitSHA: "unknown",
                branchName: nil,
                message: "Tests could not read the API request: \(error.localizedDescription)"
            )
            return
        }

        guard request.id == requestID else {
            writeErrorResponse(
                requestID: requestID,
                commitSHA: request.commitSHA,
                branchName: request.branchName,
                message: "The API request ID does not match its filename."
            )
            return
        }
        guard request.version == TestsAPI.protocolVersion else {
            writeErrorResponse(
                requestID: requestID,
                commitSHA: request.commitSHA,
                branchName: request.branchName,
                message: "Unsupported Tests API protocol version \(request.version)."
            )
            return
        }

        let settingsRepository = SettingsStore.shared.repositoryPath
        guard !settingsRepository.isEmpty else {
            writeErrorResponse(
                requestID: requestID,
                commitSHA: request.commitSHA,
                branchName: request.branchName,
                message: "Tests has no configured repository. Open Tests Settings and choose one."
            )
            return
        }

        guard repositoriesMatch(request.repositoryPath, settingsRepository) else {
            writeErrorResponse(
                requestID: requestID,
                commitSHA: request.commitSHA,
                branchName: request.branchName,
                message: "The requested repository does not match the repository configured in Tests."
            )
            return
        }

        guard let resolvedCommit = resolvedCommitSHA(request.commitSHA, repositoryPath: settingsRepository),
              resolvedCommit.caseInsensitiveCompare(request.commitSHA) == .orderedSame else {
            writeErrorResponse(
                requestID: requestID,
                commitSHA: request.commitSHA,
                branchName: request.branchName,
                message: "Commit \(request.commitSHA) is not available in the repository configured in Tests."
            )
            return
        }

        let commitKey = normalizedCommit(request.commitSHA)
        requestsByID[requestID] = request
        requestIDsByCommit[commitKey, default: []].insert(requestID)
        writeAcceptedResponse(for: request)

        if testRunner.containsRun(ref: request.commitSHA) {
            print("TestAPIController: Attached request \(requestID) to existing run for \(request.commitSHA)")
            return
        }

        print("TestAPIController: Starting Tests-owned run for API request \(requestID), commit \(request.commitSHA)")
        testRunner.runTests(
            branchName: request.commitSHA,
            isManualRun: true,
            displayBranchName: request.branchName,
            showsErrors: false
        )
    }

    private func handleCompletedRun(_ testRun: TestRun) {
        guard let commitSHA = testRun.commitSHA else { return }
        let commitKey = normalizedCommit(commitSHA)
        guard let requestIDs = requestIDsByCommit.removeValue(forKey: commitKey) else { return }

        for requestID in requestIDs {
            guard let request = requestsByID.removeValue(forKey: requestID) else { continue }
            let failureSummary = testRun.failureSummary
                ?? testRun.errorDescription
                ?? Self.conciseFailureDetails(from: testRun.outputLog)
            let response = TestsAPI.RunResponse(
                version: TestsAPI.protocolVersion,
                requestID: request.id,
                state: .completed,
                status: testRun.status.rawValue,
                runID: testRun.id,
                commitSHA: commitSHA,
                branchName: testRun.branchName ?? request.branchName,
                duration: testRun.duration,
                passingCount: testRun.passingCount,
                failingCount: testRun.failingCount,
                totalCount: testRun.totalCount,
                errorDescription: testRun.errorDescription,
                failureSummary: failureSummary,
                outputLog: request.outputMode == .full ? testRun.outputLog : nil
            )
            writeResponse(response)
        }
    }

    private func writeAcceptedResponse(for request: TestsAPI.RunRequest) {
        let response = TestsAPI.RunResponse(
            version: TestsAPI.protocolVersion,
            requestID: request.id,
            state: .accepted,
            status: nil,
            runID: nil,
            commitSHA: request.commitSHA,
            branchName: request.branchName,
            duration: nil,
            passingCount: nil,
            failingCount: nil,
            totalCount: nil,
            errorDescription: nil,
            failureSummary: nil,
            outputLog: nil
        )
        writeResponse(response)
    }

    private func writeErrorResponse(
        requestID: UUID,
        commitSHA: String,
        branchName: String?,
        message: String
    ) {
        let response = TestsAPI.RunResponse(
            version: TestsAPI.protocolVersion,
            requestID: requestID,
            state: .completed,
            status: TestRunStatus.error.rawValue,
            runID: nil,
            commitSHA: commitSHA,
            branchName: branchName,
            duration: nil,
            passingCount: nil,
            failingCount: nil,
            totalCount: nil,
            errorDescription: message,
            failureSummary: message,
            outputLog: nil
        )
        writeResponse(response)
    }

    private func writeResponse(_ response: TestsAPI.RunResponse) {
        do {
            try TestsAPI.write(response, to: TestsAPI.responseURL(for: response.requestID))
        } catch {
            print("TestAPIController: Failed to write response \(response.requestID): \(error)")
        }
    }

    private func repositoriesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsIdentity = repositoryIdentity(at: lhs),
              let rhsIdentity = repositoryIdentity(at: rhs) else {
            return false
        }
        return lhsIdentity == rhsIdentity
    }

    private func repositoryIdentity(at path: String) -> String? {
        guard let repositoryRoot = resolvedRepositoryRoot(at: path) else { return nil }
        return URL(fileURLWithPath: repositoryRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func resolvedCommitSHA(_ commit: String, repositoryPath: String) -> String? {
        guard let repositoryRoot = resolvedRepositoryRoot(at: repositoryPath) else { return nil }
        return runGit(["-C", repositoryRoot, "rev-parse", "--verify", "\(commit)^{commit}"])
    }

    private func resolvedRepositoryRoot(at path: String) -> String? {
        let commonDirectoryResult = runGitResult(
            ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        )
        if commonDirectoryResult.success {
            let commonDirectoryURL = URL(fileURLWithPath: commonDirectoryResult.output)
            if commonDirectoryURL.lastPathComponent == ".git" {
                return commonDirectoryURL.deletingLastPathComponent().path
            }
        }

        return GitHistoryService.repositoryRootFromLinkedWorktree(at: path)
            ?? GitHistoryService.repositoryRootFromStaleWorktreeMetadata(in: commonDirectoryResult.output)
    }

    private func runGit(_ arguments: [String]) -> String? {
        let result = runGitResult(arguments)
        return result.success ? result.output : nil
    }

    private func runGitResult(_ arguments: [String]) -> (success: Bool, output: String) {
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
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0 && !output.isEmpty, output)
    }

    private func normalizedCommit(_ commit: String) -> String {
        commit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func conciseFailureDetails(from output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        let markers = ["error:", "failed", "failure", "assert", "❌", "fatal error"]
        var seen = Set<String>()
        let matchingLines = output.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  markers.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }),
                  seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        let limited = matchingLines.prefix(120).joined(separator: "\n")
        guard !limited.isEmpty else { return nil }
        return String(limited.prefix(24_000))
    }

    private func removeStaleFiles(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for directory in [TestsAPI.requestsDirectoryURL, TestsAPI.responsesDirectoryURL] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files {
                let modificationDate = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if let modificationDate, modificationDate < cutoff {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}
