import XCTest
@testable import Tests

final class TestAPIControllerTests: XCTestCase {
    func testAPIRequestRoundTripsWithISO8601Date() throws {
        let request = TestsAPI.RunRequest(
            version: TestsAPI.protocolVersion,
            id: UUID(),
            commitSHA: String(repeating: "a", count: 40),
            branchName: "feature/api",
            repositoryPath: "/tmp/repository",
            outputMode: .failures,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try TestsAPI.encoder().encode(request)
        let decoded = try TestsAPI.decoder().decode(TestsAPI.RunRequest.self, from: data)

        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.commitSHA, request.commitSHA)
        XCTAssertEqual(decoded.branchName, request.branchName)
        XCTAssertEqual(decoded.outputMode, .failures)
        XCTAssertEqual(decoded.createdAt, request.createdAt)
    }

    func testConciseFailureDetailsKeepsRelevantLinesAndDeduplicates() {
        let output = """
        Preparing workspace...
        /tmp/Project.swift:42: error: missing package product
        Test Case '-[EngineTests testRestore]' failed (0.1 seconds).
        /tmp/Project.swift:42: error: missing package product
        ** TEST FAILED **
        """

        let summary = TestAPIController.conciseFailureDetails(from: output)

        XCTAssertEqual(
            summary,
            """
            /tmp/Project.swift:42: error: missing package product
            Test Case '-[EngineTests testRestore]' failed (0.1 seconds).
            ** TEST FAILED **
            """
        )
    }

    func testExactCommitRecognitionRequiresFullHexSHA() {
        XCTAssertTrue(TestRunner.looksLikeCommitSHA(String(repeating: "a", count: 40)))
        XCTAssertTrue(TestRunner.looksLikeCommitSHA(String(repeating: "B", count: 64)))
        XCTAssertFalse(TestRunner.looksLikeCommitSHA("HEAD"))
        XCTAssertFalse(TestRunner.looksLikeCommitSHA(String(repeating: "z", count: 40)))
        XCTAssertFalse(TestRunner.looksLikeCommitSHA(String(repeating: "a", count: 12)))
    }

    func testContainsRunMatchesActiveCommitCaseInsensitively() {
        let runner = TestRunner()
        let commit = String(repeating: "a", count: 40)
        var run = TestRun(status: .running)
        run.commitSHA = commit.uppercased()
        runner.currentTestRun = run
        runner.isRunning = true

        XCTAssertTrue(runner.containsRun(ref: commit))
        XCTAssertFalse(runner.containsRun(ref: String(repeating: "b", count: 40)))
    }

    func testContainsRunMatchesQueuedExactCommit() {
        let runner = TestRunner()
        let activeCommit = String(repeating: "a", count: 40)
        let queuedCommit = String(repeating: "b", count: 40)
        var run = TestRun(status: .running)
        run.commitSHA = activeCommit
        runner.currentTestRun = run
        runner.isRunning = true

        XCTAssertEqual(
            runner.dispatchIncomingRun(branchName: queuedCommit, isManualRun: true),
            .queued
        )
        XCTAssertTrue(runner.containsRun(ref: queuedCommit))
    }
}
