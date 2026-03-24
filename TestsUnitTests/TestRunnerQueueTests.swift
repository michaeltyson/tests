import XCTest
@testable import Tests

final class TestRunnerQueueTests: XCTestCase {
    func testParallelTestingArgumentsIncludedWhenEnabled() {
        XCTAssertEqual(
            TestRunner.xcodebuildParallelTestingArguments(enabled: true),
            ["-parallel-testing-enabled", "YES"]
        )
    }

    func testParallelTestingArgumentsOmittedWhenDisabled() {
        XCTAssertEqual(
            TestRunner.xcodebuildParallelTestingArguments(enabled: false),
            []
        )
    }

    func testSameBranchTriggerQueuesOnceAndRequestsCancellation() {
        let runner = TestRunner()
        runner.isRunning = true
        var current = TestRun(status: .running)
        current.branchName = "develop"
        runner.currentTestRun = current

        let firstAction = runner.dispatchIncomingRun(branchName: "develop", isManualRun: false)
        XCTAssertEqual(firstAction, .queuedAndCancelActive)
        XCTAssertEqual(runner.queuedRunCount, 1)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["develop"])

        let secondAction = runner.dispatchIncomingRun(branchName: "develop", isManualRun: false)
        XCTAssertEqual(secondAction, .queuedAndCancelActive)
        XCTAssertEqual(runner.queuedRunCount, 1, "Duplicate same-branch trigger should be deduped")
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["develop"])
    }

    func testDifferentBranchTriggerQueuesWithoutCancellationRequest() {
        let runner = TestRunner()
        runner.isRunning = true
        var current = TestRun(status: .running)
        current.branchName = "develop"
        runner.currentTestRun = current

        let action = runner.dispatchIncomingRun(branchName: "release", isManualRun: false)

        XCTAssertEqual(action, .queued)
        XCTAssertEqual(runner.queuedRunCount, 1)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["release"])
    }

    func testDifferentBranchesQueueInArrivalOrderAndDedupePerBranch() {
        let runner = TestRunner()
        runner.isRunning = true
        var current = TestRun(status: .running)
        current.branchName = "develop"
        runner.currentTestRun = current

        XCTAssertEqual(runner.dispatchIncomingRun(branchName: "release", isManualRun: false), .queued)
        XCTAssertEqual(runner.dispatchIncomingRun(branchName: "hotfix", isManualRun: false), .queued)
        XCTAssertEqual(runner.dispatchIncomingRun(branchName: "release", isManualRun: false), .queued)

        XCTAssertEqual(runner.queuedRunCount, 2)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["release", "hotfix"])
    }

    func testIdleRunnerReturnsStartNow() {
        let runner = TestRunner()

        let action = runner.dispatchIncomingRun(branchName: "develop", isManualRun: false)

        XCTAssertEqual(action, .startNow)
        XCTAssertEqual(runner.queuedRunCount, 0)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, [])
    }
}
