//
//  GitHistoryService.swift
//  Tests
//

import Foundation

final class GitHistoryService {
    struct LoadResult {
        let commits: [GitCommitNode]
        let errorMessage: String?
    }

    private struct GitReference {
        let sha: String
        let name: String
    }

    private let gitPath = "/usr/bin/git"
    private let maximumCommitCount: Int

    init(maximumCommitCount: Int = 500) {
        self.maximumCommitCount = maximumCommitCount
    }

    func loadHistory(
        repositoryPath: String,
        testRuns: [TestRun],
        currentTestRun: TestRun?,
        fallbackBranchName: String?
    ) -> LoadResult {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return LoadResult(commits: [], errorMessage: "Set a repository path in Settings to load commit history.")
        }

        var arguments = [
            "log",
            "--first-parent",
            "--date=iso-strict",
            "--pretty=format:%H%x09%h%x09%aI%x09%D%x09%P%x09%s",
            "-n",
            "\(maximumCommitCount)"
        ]
        let availableReferences = gitReferences(repositoryPath: trimmedPath)
        let refs = Self.canonicalHistoryRefs(from: Set(availableReferences.map(\.name)))
        let canonicalBranchHeads = Self.canonicalBranchHeads(
            from: Dictionary(
                uniqueKeysWithValues: availableReferences.map { ($0.name, $0.sha) }
            )
        )
        let branchHeadsByName = canonicalBranchHeads.isEmpty ? nil : canonicalBranchHeads
        if refs.isEmpty {
            arguments += ["--branches", "--remotes=origin"]
        } else {
            arguments += refs
        }

        let result = runGitCommand(
            arguments,
            repositoryPath: trimmedPath
        )

        guard result.success else {
            let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmedOutput.isEmpty ? "Could not load git history." : trimmedOutput
            return LoadResult(commits: [], errorMessage: message)
        }

        let parsedCommits = Self.parseGitLog(result.output)
        let runsByCommit = Self.latestTestRunsByCommitSHA(testRuns: testRuns, currentTestRun: currentTestRun)
        let nodes = Self.makeCommitNodes(
            from: parsedCommits,
            testRunsByCommitSHA: runsByCommit,
            branchHeadsByName: branchHeadsByName
        )
        return LoadResult(commits: nodes, errorMessage: nil)
    }

    private func runGitCommand(_ arguments: [String], repositoryPath: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let outputHandle = pipe.fileHandleForReading
        let outputLock = NSLock()
        var collectedOutput = Data()

        do {
            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputLock.lock()
                collectedOutput.append(data)
                outputLock.unlock()
            }

            try process.run()

            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                outputHandle.readabilityHandler = nil
                let trailingData = outputHandle.readDataToEndOfFile()
                if !trailingData.isEmpty {
                    outputLock.lock()
                    collectedOutput.append(trailingData)
                    outputLock.unlock()
                }
                return (false, "Timed out while loading git history.")
            }

            process.waitUntilExit()
            outputHandle.readabilityHandler = nil
            let trailingData = outputHandle.readDataToEndOfFile()
            if !trailingData.isEmpty {
                outputLock.lock()
                collectedOutput.append(trailingData)
                outputLock.unlock()
            }

            outputLock.lock()
            let output = String(data: collectedOutput, encoding: .utf8) ?? ""
            outputLock.unlock()
            return (process.terminationStatus == 0, output)
        } catch {
            outputHandle.readabilityHandler = nil
            return (false, error.localizedDescription)
        }
    }

    static func parseGitLog(_ output: String) -> [GitLogCommit] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        return output.components(separatedBy: .newlines).compactMap { line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 6 else { return nil }

            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let shortSHA = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let dateText = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let decorations = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let parents = fields[4]
                .split(separator: " ")
                .map { String($0) }
                .filter { !$0.isEmpty }
            let subject = fields.dropFirst(5).joined(separator: "\t")

            guard !sha.isEmpty, !shortSHA.isEmpty else { return nil }

            return GitLogCommit(
                sha: sha,
                shortSHA: shortSHA,
                authorDate: formatter.date(from: dateText) ?? fallbackFormatter.date(from: dateText),
                decorations: decorations,
                parentSHAs: parents,
                subject: subject
            )
        }
    }

    static func normalizedBranchNames(from decorations: String) -> [String] {
        var seen = Set<String>()
        return decorations
            .split(separator: ",")
            .map { decoration in
                var value = decoration.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("HEAD -> ") {
                    value = String(value.dropFirst("HEAD -> ".count))
                }
                if value.hasPrefix("tag: ") {
                    return ""
                }
                if value.hasPrefix("origin/") {
                    value = String(value.dropFirst("origin/".count))
                } else if value.hasPrefix("remotes/origin/") {
                    value = String(value.dropFirst("remotes/origin/".count))
                } else if value.hasPrefix("source-origin/") {
                    value = String(value.dropFirst("source-origin/".count))
                }
                if value == "HEAD" || value.hasPrefix("HEAD") || value.contains(" -> ") {
                    return ""
                }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    static func normalizedBranchNames(fromBranchList output: String) -> [String] {
        var seen = Set<String>()
        return output
            .components(separatedBy: .newlines)
            .compactMap { normalizedBranchName($0) }
            .filter { !$0.hasPrefix("HEAD") }
            .filter { !$0.contains("->") }
            .filter { seen.insert($0).inserted }
            .sorted {
                $0.count == $1.count
                    ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                    : $0.count < $1.count
            }
    }

    static func defaultBranchName(
        remoteHeadOutput: String?,
        currentBranchOutput: String?,
        branchNames: [String]
    ) -> String? {
        if let remoteHeadBranch = normalizedBranchName(remoteHeadOutput),
           branchNames.contains(remoteHeadBranch) {
            return remoteHeadBranch
        }

        for conventionalName in ["main", "master", "develop"] where branchNames.contains(conventionalName) {
            return conventionalName
        }

        if let currentBranch = normalizedBranchName(currentBranchOutput),
           branchNames.contains(currentBranch) {
            return currentBranch
        }

        return branchNames.first
    }

    static func relevantBranchNames(
        testRuns: [TestRun],
        currentTestRun: TestRun?,
        fallbackBranchName: String?
    ) -> Set<String> {
        var branchNames = Set<String>()
        var runs = testRuns
        if let currentTestRun {
            runs.append(currentTestRun)
        }

        for run in runs {
            if let branchName = normalizedBranchName(run.branchName) {
                branchNames.insert(branchName)
            }
        }

        if branchNames.isEmpty, let fallbackBranchName = normalizedBranchName(fallbackBranchName) {
            branchNames.insert(fallbackBranchName)
        }

        return branchNames
    }

    static func canonicalHistoryRefs(from referenceNames: Set<String>) -> [String] {
        var refsByBranchName: [String: String] = [:]

        for ref in referenceNames {
            if ref.hasPrefix("refs/heads/") {
                let branchName = String(ref.dropFirst("refs/heads/".count))
                refsByBranchName[branchName] = ref
            }
        }

        for ref in referenceNames {
            guard ref.hasPrefix("refs/remotes/origin/"),
                  !ref.hasSuffix("/HEAD") else {
                continue
            }

            let branchName = String(ref.dropFirst("refs/remotes/origin/".count))
            if refsByBranchName[branchName] == nil {
                refsByBranchName[branchName] = ref
            }
        }

        return refsByBranchName
            .sorted { lhs, rhs in
                lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map(\.value)
    }

    static func canonicalBranchHeads(from referencesByName: [String: String]) -> [String: String] {
        var headsByBranchName: [String: String] = [:]

        for (ref, sha) in referencesByName where ref.hasPrefix("refs/heads/") {
            let branchName = String(ref.dropFirst("refs/heads/".count))
            headsByBranchName[branchName] = sha
        }

        for (ref, sha) in referencesByName where ref.hasPrefix("refs/remotes/origin/") && !ref.hasSuffix("/HEAD") {
            let branchName = String(ref.dropFirst("refs/remotes/origin/".count))
            if headsByBranchName[branchName] == nil {
                headsByBranchName[branchName] = sha
            }
        }

        for (ref, sha) in referencesByName where ref.hasPrefix("refs/remotes/source-origin/") && !ref.hasSuffix("/HEAD") {
            let branchName = String(ref.dropFirst("refs/remotes/source-origin/".count))
            if headsByBranchName[branchName] == nil {
                headsByBranchName[branchName] = sha
            }
        }

        return headsByBranchName
    }

    static func latestTestRunsByCommitSHA(testRuns: [TestRun], currentTestRun: TestRun?) -> [String: TestRun] {
        var runs = testRuns
        if let currentTestRun {
            runs.removeAll { $0.id == currentTestRun.id }
            runs.append(currentTestRun)
        }

        var index: [String: TestRun] = [:]
        for run in runs.sorted(by: { $0.timestamp > $1.timestamp }) {
            guard let sha = normalizedSHA(run.commitSHA), index[sha] == nil else {
                continue
            }
            index[sha] = run
        }
        return index
    }

    static func makeCommitNodes(
        from commits: [GitLogCommit],
        testRunsByCommitSHA: [String: TestRun],
        visibleBranchNames: Set<String>? = nil,
        branchHeadsByName: [String: String]? = nil
    ) -> [GitCommitNode] {
        let sortedCommits = commits.sorted { lhs, rhs in
            switch (lhs.authorDate, rhs.authorDate) {
            case let (lhsDate?, rhsDate?):
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }
        let visibleCommitSHAs = Set(sortedCommits.map(\.sha))
        var activeLanes: [String] = []

        return sortedCommits.map { commit in
            let incomingLanes = Set(activeLanes.indices)
            let matchingLaneIndices = activeLanes.indices.filter { activeLanes[$0] == commit.sha }
            let laneIndex: Int
            if let firstMatch = matchingLaneIndices.first {
                laneIndex = firstMatch
            } else {
                laneIndex = activeLanes.count
                activeLanes.append(commit.sha)
            }

            var nextLanes = activeLanes
            let parents = commit.parentSHAs.filter { visibleCommitSHAs.contains($0) }
            let duplicateIncomingLanes = matchingLaneIndices.dropFirst()
            let topConnections = duplicateIncomingLanes.map {
                GitGraphLaneConnection(fromLane: $0, toLane: laneIndex)
            }
            var bottomConnections: [GitGraphLaneConnection] = []

            for duplicateLane in duplicateIncomingLanes.sorted(by: >) {
                nextLanes.remove(at: duplicateLane)
            }

            if parents.isEmpty {
                if laneIndex < nextLanes.count {
                    nextLanes.remove(at: laneIndex)
                }
            } else {
                nextLanes[laneIndex] = parents[0]
                bottomConnections.append(GitGraphLaneConnection(fromLane: laneIndex, toLane: laneIndex))

                for (extraParentOffset, parent) in parents.dropFirst().enumerated() {
                    if let existingParentIndex = nextLanes.firstIndex(of: parent) {
                        bottomConnections.append(GitGraphLaneConnection(fromLane: laneIndex, toLane: existingParentIndex))
                    } else {
                        let insertIndex = min(laneIndex + 1 + extraParentOffset, nextLanes.count)
                        nextLanes.insert(parent, at: insertIndex)
                        bottomConnections.append(GitGraphLaneConnection(fromLane: laneIndex, toLane: insertIndex))
                    }
                }
            }

            let outgoingLanes = Set(nextLanes.indices)
            let laneCount = max(incomingLanes.count, outgoingLanes.count, laneIndex + 1)
            activeLanes = nextLanes

            let normalizedCommitSHA = normalizedSHA(commit.sha) ?? commit.sha
            let branchNames = normalizedBranchNames(from: commit.decorations).filter { branchName in
                guard visibleBranchNames?.contains(branchName) ?? true else { return false }
                guard let branchHeadsByName else { return true }
                return normalizedSHA(branchHeadsByName[branchName]) == normalizedCommitSHA
            }

            return GitCommitNode(
                sha: commit.sha,
                shortSHA: commit.shortSHA,
                subject: commit.subject,
                authorDate: commit.authorDate,
                parentSHAs: commit.parentSHAs,
                branchNames: branchNames,
                laneIndex: laneIndex,
                laneCount: laneCount,
                topLanes: incomingLanes,
                bottomLanes: outgoingLanes,
                topConnections: topConnections,
                bottomConnections: bottomConnections,
                testRun: testRunsByCommitSHA[normalizedSHA(commit.sha) ?? commit.sha]
            )
        }
    }

    private static func normalizedSHA(_ sha: String?) -> String? {
        guard let sha else { return nil }
        let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func relevantHistoryRefs(
        repositoryPath: String,
        testRuns: [TestRun],
        currentTestRun: TestRun?,
        fallbackBranchName: String?
    ) -> [String] {
        let branchNames = Self.relevantBranchNames(
            testRuns: testRuns,
            currentTestRun: currentTestRun,
            fallbackBranchName: fallbackBranchName
        )
        var refs: [String] = []
        var seen = Set<String>()
        let availableRefs = gitReferenceNames(repositoryPath: repositoryPath)

        for branchName in branchNames.sorted() {
            for candidate in [
                "refs/heads/\(branchName)",
                "refs/remotes/origin/\(branchName)",
                "refs/remotes/source-origin/\(branchName)"
            ] where seen.insert(candidate).inserted && availableRefs.contains(candidate) {
                refs.append(candidate)
            }
        }

        return refs
    }

    private func gitReferenceNames(repositoryPath: String) -> Set<String> {
        Set(gitReferences(repositoryPath: repositoryPath).map(\.name))
    }

    private func gitReferences(repositoryPath: String) -> [GitReference] {
        let result = runGitCommand(["show-ref"], repositoryPath: repositoryPath)
        guard result.success else { return [] }

        return result.output
            .components(separatedBy: .newlines)
            .compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { return nil }
                return GitReference(sha: String(fields[0]), name: String(fields[1]))
            }
    }

    private static func normalizedBranchName(_ branchName: String?) -> String? {
        guard var branchName else { return nil }
        branchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if branchName.hasPrefix("+") {
            branchName = String(branchName.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if branchName.hasPrefix("*") {
            branchName = String(branchName.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if branchName.hasPrefix("origin/") {
            branchName = String(branchName.dropFirst("origin/".count))
        } else if branchName.hasPrefix("remotes/origin/") {
            branchName = String(branchName.dropFirst("remotes/origin/".count))
        } else if branchName.hasPrefix("source-origin/") {
            branchName = String(branchName.dropFirst("source-origin/".count))
        }
        return branchName.isEmpty ? nil : branchName
    }
}

enum GitBranchFinder {
    static func findBranchNames(in repositoryURL: URL) -> [String] {
        let result = runGitCommand(["branch", "-a"], in: repositoryURL)
        guard result.success else { return [] }
        return GitHistoryService.normalizedBranchNames(fromBranchList: result.output)
    }

    static func findDefaultBranchName(in repositoryURL: URL, branchNames: [String]) -> String? {
        let remoteHeadResult = runGitCommand(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: repositoryURL
        )
        let currentBranchResult = runGitCommand(
            ["branch", "--show-current"],
            in: repositoryURL
        )

        return GitHistoryService.defaultBranchName(
            remoteHeadOutput: remoteHeadResult.success ? remoteHeadResult.output : nil,
            currentBranchOutput: currentBranchResult.success ? currentBranchResult.output : nil,
            branchNames: branchNames
        )
    }

    private static func runGitCommand(_ arguments: [String], in repositoryURL: URL) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
