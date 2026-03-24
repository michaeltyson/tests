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

    func testParallelBuildArgumentsIncludedWhenEnabled() {
        XCTAssertEqual(
            TestRunner.xcodebuildParallelBuildArguments(enabled: true, jobCount: 6),
            ["-parallelizeTargets", "-jobs", "6"]
        )
    }

    func testParallelBuildArgumentsOmittedWhenDisabled() {
        XCTAssertEqual(
            TestRunner.xcodebuildParallelBuildArguments(enabled: false, jobCount: 6),
            []
        )
    }

    func testWorkspaceBuildArtifactDirectoryUsesLocalDerivedDataFolder() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/LoopyWorkspace", isDirectory: true)

        XCTAssertEqual(
            TestRunner.workspaceBuildArtifactDirectory(in: workspaceURL).path,
            "/tmp/LoopyWorkspace/.DerivedData"
        )
    }

    func testWorkspaceBuildArtifactDirectoryNamesCoverCommonBuildCaches() {
        XCTAssertEqual(
            TestRunner.workspaceBuildArtifactDirectoryNames,
            [".DerivedData", "DerivedData", "build"]
        )
    }

    func testWorkspaceCleanupSkippedWithoutPreviousRef() {
        XCTAssertFalse(
            TestRunner.shouldCleanWorkspaceForRefChange(previousRef: nil, nextRef: "release/2.1")
        )
    }

    func testWorkspaceCleanupSkippedWhenRefUnchanged() {
        XCTAssertFalse(
            TestRunner.shouldCleanWorkspaceForRefChange(previousRef: "release/2.1", nextRef: "release/2.1")
        )
    }

    func testWorkspaceCleanupTriggeredWhenRefChanges() {
        XCTAssertTrue(
            TestRunner.shouldCleanWorkspaceForRefChange(previousRef: "develop", nextRef: "release/2.1")
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
