import XCTest
@testable import Tests

final class GitHistoryServiceTests: XCTestCase {
    func testParseGitLogReadsCommitFields() throws {
        let output = """
        abcdef1234567890\tabcdef1\t2026-04-26T09:30:00+10:00\tHEAD -> main, origin/main\t1111111 2222222\tMerge branch feature
        1111111111111111\t1111111\t2026-04-25T09:30:00+10:00\torigin/feature\t\tFeature work
        """

        let commits = GitHistoryService.parseGitLog(output)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, "abcdef1234567890")
        XCTAssertEqual(commits[0].shortSHA, "abcdef1")
        XCTAssertEqual(commits[0].decorations, "HEAD -> main, origin/main")
        XCTAssertEqual(commits[0].parentSHAs, ["1111111", "2222222"])
        XCTAssertEqual(commits[0].subject, "Merge branch feature")
        XCTAssertNotNil(commits[0].authorDate)
        XCTAssertEqual(commits[1].parentSHAs, [])
    }

    func testNormalizedBranchNamesRemovesRemotePrefixesAndTags() {
        XCTAssertEqual(
            GitHistoryService.normalizedBranchNames(
                from: "HEAD -> main, origin/main, tag: v1.0, remotes/origin/develop, source-origin/release"
            ),
            ["main", "develop", "release"]
        )
    }

    func testNormalizedBranchNamesFromBranchListDeduplicatesLocalAndRemoteBranches() {
        let output = """
          feature/login
        * main
          remotes/origin/codex/very-specific-working-branch
          remotes/origin/HEAD -> origin/main
          remotes/origin/feature/login
          remotes/origin/release/1.0
        """

        XCTAssertEqual(
            GitHistoryService.normalizedBranchNames(fromBranchList: output),
            ["main", "release/1.0", "feature/login", "codex/very-specific-working-branch"]
        )
    }

    func testDefaultBranchNamePrefersOriginHead() {
        XCTAssertEqual(
            GitHistoryService.defaultBranchName(
                remoteHeadOutput: "origin/release/1.0\n",
                currentBranchOutput: "develop\n",
                branchNames: ["develop", "main", "release/1.0"]
            ),
            "release/1.0"
        )
    }

    func testDefaultBranchNameFallsBackToConventionalNamesBeforeCurrentBranch() {
        XCTAssertEqual(
            GitHistoryService.defaultBranchName(
                remoteHeadOutput: nil,
                currentBranchOutput: "feature/login\n",
                branchNames: ["feature/login", "main"]
            ),
            "main"
        )
    }

    func testDefaultBranchNameFallsBackToCurrentBranch() {
        XCTAssertEqual(
            GitHistoryService.defaultBranchName(
                remoteHeadOutput: nil,
                currentBranchOutput: "feature/login\n",
                branchNames: ["feature/login", "release/1.0"]
            ),
            "feature/login"
        )
    }

    func testRelevantBranchNamesUseTestedBranchesBeforeFallback() {
        var run = TestRun(status: .success)
        run.branchName = "origin/develop"

        XCTAssertEqual(
            GitHistoryService.relevantBranchNames(
                testRuns: [run],
                currentTestRun: nil,
                fallbackBranchName: "main"
            ),
            ["develop"]
        )
    }

    func testRelevantBranchNamesFallbackWhenNoRunsHaveBranches() {
        XCTAssertEqual(
            GitHistoryService.relevantBranchNames(
                testRuns: [],
                currentTestRun: nil,
                fallbackBranchName: "origin/main"
            ),
            ["main"]
        )
    }

    func testCanonicalHistoryRefsDeduplicatesLocalAndOriginBranches() {
        let refs: Set<String> = [
            "refs/heads/main",
            "refs/remotes/origin/main",
            "refs/heads/codex/retry",
            "refs/remotes/origin/codex/retry",
            "refs/remotes/origin/release/2.1",
            "refs/remotes/origin/HEAD",
            "refs/tags/v1"
        ]

        XCTAssertEqual(
            GitHistoryService.canonicalHistoryRefs(from: refs),
            [
                "refs/heads/codex/retry",
                "refs/heads/main",
                "refs/remotes/origin/release/2.1"
            ]
        )
    }

    func testLatestTestRunsByCommitSHAPrefersNewestRun() {
        var older = TestRun(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 10),
            status: .failed
        )
        older.commitSHA = "ABCDEF"

        var newer = TestRun(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 20),
            status: .success
        )
        newer.commitSHA = "abcdef"

        let runs = GitHistoryService.latestTestRunsByCommitSHA(
            testRuns: [older, newer],
            currentTestRun: nil
        )

        XCTAssertEqual(runs["abcdef"]?.status, .success)
    }

    func testCurrentTestRunOverridesSavedRunsForSameID() {
        let runID = UUID()
        var saved = TestRun(
            id: runID,
            timestamp: Date(timeIntervalSince1970: 10),
            status: .failed
        )
        saved.commitSHA = "abcdef"

        var current = TestRun(
            id: runID,
            timestamp: Date(timeIntervalSince1970: 20),
            status: .running
        )
        current.commitSHA = "abcdef"

        let runs = GitHistoryService.latestTestRunsByCommitSHA(
            testRuns: [saved],
            currentTestRun: current
        )

        XCTAssertEqual(runs["abcdef"]?.status, .running)
    }

    func testMakeCommitNodesAssignsTestStatusAndBranchNames() {
        let newestDate = Date(timeIntervalSince1970: 30)
        let middleDate = Date(timeIntervalSince1970: 20)
        let oldestDate = Date(timeIntervalSince1970: 10)
        let commits = [
            GitLogCommit(
                sha: "a",
                shortSHA: "a",
                authorDate: newestDate,
                decorations: "HEAD -> main",
                parentSHAs: ["b", "c"],
                subject: "Merge"
            ),
            GitLogCommit(
                sha: "b",
                shortSHA: "b",
                authorDate: middleDate,
                decorations: "",
                parentSHAs: [],
                subject: "Main parent"
            ),
            GitLogCommit(
                sha: "c",
                shortSHA: "c",
                authorDate: oldestDate,
                decorations: "origin/feature",
                parentSHAs: [],
                subject: "Feature parent"
            )
        ]

        var run = TestRun(status: .warnings)
        run.commitSHA = "c"

        let nodes = GitHistoryService.makeCommitNodes(
            from: commits,
            testRunsByCommitSHA: ["c": run]
        )

        XCTAssertEqual(nodes[0].branchNames, ["main"])
        XCTAssertEqual(nodes[0].bottomConnections, [
            GitGraphLaneConnection(fromLane: 0, toLane: 0),
            GitGraphLaneConnection(fromLane: 0, toLane: 1)
        ])
        XCTAssertEqual(nodes[1].topLanes, [0, 1])
        XCTAssertEqual(nodes[1].bottomLanes, [0])
        XCTAssertEqual(nodes[2].topLanes, [0])
        XCTAssertEqual(nodes[2].topConnections, [])
        XCTAssertEqual(nodes[2].branchNames, ["feature"])
        XCTAssertEqual(nodes[2].testStatus, .warnings)
    }

    func testMakeCommitNodesFiltersVisibleBranchBadges() {
        let commits = [
            GitLogCommit(
                sha: "a",
                shortSHA: "a",
                authorDate: nil,
                decorations: "origin/main, origin/codex/no-test",
                parentSHAs: [],
                subject: "Commit"
            )
        ]

        let nodes = GitHistoryService.makeCommitNodes(
            from: commits,
            testRunsByCommitSHA: [:],
            visibleBranchNames: ["main"]
        )

        XCTAssertEqual(nodes[0].branchNames, ["main"])
    }

    func testMakeCommitNodesSortsNewestCommitsFirst() {
        let commits = [
            GitLogCommit(
                sha: "old",
                shortSHA: "old",
                authorDate: Date(timeIntervalSince1970: 1),
                decorations: "",
                parentSHAs: [],
                subject: "Old"
            ),
            GitLogCommit(
                sha: "new",
                shortSHA: "new",
                authorDate: Date(timeIntervalSince1970: 2),
                decorations: "",
                parentSHAs: [],
                subject: "New"
            )
        ]

        let nodes = GitHistoryService.makeCommitNodes(from: commits, testRunsByCommitSHA: [:])

        XCTAssertEqual(nodes.map(\.sha), ["new", "old"])
    }

    func testMakeCommitNodesRepresentsJoinAcrossTopLanes() {
        let commits = [
            GitLogCommit(
                sha: "a",
                shortSHA: "a",
                authorDate: Date(timeIntervalSince1970: 40),
                decorations: "",
                parentSHAs: ["c"],
                subject: "Left child"
            ),
            GitLogCommit(
                sha: "b",
                shortSHA: "b",
                authorDate: Date(timeIntervalSince1970: 30),
                decorations: "",
                parentSHAs: ["c"],
                subject: "Right child"
            ),
            GitLogCommit(
                sha: "filler",
                shortSHA: "filler",
                authorDate: Date(timeIntervalSince1970: 20),
                decorations: "",
                parentSHAs: [],
                subject: "Other branch"
            ),
            GitLogCommit(
                sha: "c",
                shortSHA: "c",
                authorDate: Date(timeIntervalSince1970: 10),
                decorations: "",
                parentSHAs: [],
                subject: "Shared parent"
            )
        ]

        let nodes = GitHistoryService.makeCommitNodes(from: commits, testRunsByCommitSHA: [:])

        XCTAssertEqual(nodes[2].sha, "filler")
        XCTAssertTrue(nodes[2].topLanes.contains(0))
        XCTAssertTrue(nodes[2].bottomLanes.contains(0))
        XCTAssertEqual(nodes[3].sha, "c")
        XCTAssertEqual(nodes[3].topConnections, [
            GitGraphLaneConnection(fromLane: 1, toLane: 0)
        ])
    }

    func testMakeCommitNodesDropsParentsOutsideVisibleHistory() {
        let commits = [
            GitLogCommit(
                sha: "visible",
                shortSHA: "visible",
                authorDate: Date(timeIntervalSince1970: 20),
                decorations: "",
                parentSHAs: ["missing"],
                subject: "Visible commit"
            )
        ]

        let nodes = GitHistoryService.makeCommitNodes(from: commits, testRunsByCommitSHA: [:])

        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].bottomLanes, [])
        XCTAssertEqual(nodes[0].bottomConnections, [])
        XCTAssertEqual(nodes[0].laneCount, 1)
    }
}
