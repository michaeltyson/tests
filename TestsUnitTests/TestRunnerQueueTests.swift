import XCTest
@testable import Tests

final class TestRunnerQueueTests: XCTestCase {
    func testPerformanceArgumentsIncluded() {
        XCTAssertEqual(
            TestRunner.xcodebuildPerformanceArguments(),
            [
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGN_IDENTITY=",
                "COMPILER_INDEX_STORE_ENABLE=NO",
                "DEBUG_INFORMATION_FORMAT=dwarf",
                "ENABLE_MODULE_VERIFIER=NO"
            ]
        )
    }

    func testXcbeautifyArgumentsPreserveUnbeautifiedOutput() {
        XCTAssertEqual(
            TestRunner.xcbeautifyArguments(),
            [
                "--renderer", "terminal",
                "--preserve-unbeautified"
            ]
        )
    }

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

    func testSchemeParallelizeBuildablesSettingReadsYes() {
        let contents = """
        <BuildAction
           parallelizeBuildables = "YES"
           buildImplicitDependencies = "YES">
        """

        XCTAssertEqual(TestRunner.schemeParallelizeBuildablesSetting(from: contents), true)
    }

    func testSchemeParallelizeBuildablesSettingReadsNo() {
        let contents = """
        <BuildAction
           parallelizeBuildables = "NO"
           buildImplicitDependencies = "YES">
        """

        XCTAssertEqual(TestRunner.schemeParallelizeBuildablesSetting(from: contents), false)
    }

    func testRawPreservedFailedTestCaseLineIsRecognizedAsFailure() {
        let line = "Test case '-[LPClockPhaseLayerTests testMetalClockPhaseLayerDuplicatesCircleVerticesForWrappedForegroundArc]' failed on 'My Mac - xctest (70810)' (0.804 seconds)"

        XCTAssertTrue(TestRunner.isXcodebuildTestCaseLine(line))
        XCTAssertTrue(TestRunner.isFailedTestResultLine(line))
        XCTAssertFalse(TestRunner.isPassedTestResultLine(line))
        XCTAssertEqual(
            TestRunner.extractTestNameFromTestCaseLine(line),
            "testMetalClockPhaseLayerDuplicatesCircleVerticesForWrappedForegroundArc"
        )
    }

    func testRawPreservedPassedTestCaseLineIsRecognizedAsSuccess() {
        let line = "Test case '-[LPClockPhaseLayerTests testMetalClockPhaseLayerDuplicatesCircleVerticesForWrappedForegroundArc]' passed on 'My Mac - xctest (70810)' (0.804 seconds)"

        XCTAssertTrue(TestRunner.isXcodebuildTestCaseLine(line))
        XCTAssertFalse(TestRunner.isFailedTestResultLine(line))
        XCTAssertTrue(TestRunner.isPassedTestResultLine(line))
        XCTAssertEqual(
            TestRunner.extractTestNameFromTestCaseLine(line),
            "testMetalClockPhaseLayerDuplicatesCircleVerticesForWrappedForegroundArc"
        )
    }

    func testXCResultFailureSummaryParsingIncludesIdentifiersAndLocations() throws {
        let json = """
        {
          "testNodes" : [
            {
              "nodeType" : "Test Plan",
              "children" : [
                {
                  "nodeType" : "Test Suite",
                  "children" : [
                    {
                      "nodeType" : "Test Case",
                      "nodeIdentifier" : "LoopyTests/LPExampleTests/testFailure",
                      "result" : "Failed",
                      "children" : [
                        {
                          "nodeType" : "Failure Message",
                          "name" : "XCTAssertEqual failed: (\\"1\\") is not equal to (\\"2\\")",
                          "documentLocationInCreatingWorkspace" : {
                            "url" : "file:///tmp/LPExampleTests.swift",
                            "lineNumber" : 42
                          }
                        },
                        {
                          "nodeType" : "Failure Message",
                          "name" : "Additional context"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
        """

        let summaries = try XCTUnwrap(TestRunner.parseXCResultFailureSummaries(from: Data(json.utf8)))
        XCTAssertEqual(
            summaries,
            [
                TestRunner.XCResultFailureSummary(
                    identifier: "LoopyTests/LPExampleTests/testFailure",
                    messages: [
                        "/tmp/LPExampleTests.swift:42: XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
                        "Additional context"
                    ]
                )
            ]
        )
    }

    func testXCResultFailureSummaryParsingDedupesRepeatedMessagesInOrder() throws {
        let json = """
        {
          "testNodes" : [
            {
              "nodeType" : "Test Case",
              "name" : "FallbackIdentifier",
              "result" : "Failed",
              "children" : [
                {
                  "nodeType" : "Failure Message",
                  "name" : "Repeated failure"
                },
                {
                  "nodeType" : "Failure Message",
                  "name" : "Repeated failure"
                },
                {
                  "nodeType" : "Failure Message",
                  "name" : "Second failure"
                }
              ]
            }
          ]
        }
        """

        let summaries = try XCTUnwrap(TestRunner.parseXCResultFailureSummaries(from: Data(json.utf8)))
        XCTAssertEqual(
            summaries,
            [
                TestRunner.XCResultFailureSummary(
                    identifier: "FallbackIdentifier",
                    messages: ["Repeated failure", "Second failure"]
                )
            ]
        )
    }

    func testProjectParallelizationSettingReadsYes() {
        let contents = """
        attributes = {
            BuildIndependentTargetsInParallel = YES;
        };
        """

        XCTAssertEqual(TestRunner.projectParallelizationSetting(from: contents), true)
    }

    func testProjectParallelizationSettingReadsNo() {
        let contents = """
        attributes = {
            BuildIndependentTargetsInParallel = NO;
        };
        """

        XCTAssertEqual(TestRunner.projectParallelizationSetting(from: contents), false)
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

    func testWorkspaceCleanupTriggeredWhenPreviousRefContainsWhitespace() {
        XCTAssertTrue(
            TestRunner.shouldCleanWorkspaceForRefChange(previousRef: " develop \n", nextRef: "release/2.1")
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

    func testCancelPreservesQueuedRuns() {
        let runner = TestRunner()
        runner.isRunning = true
        var current = TestRun(status: .running)
        current.branchName = "develop"
        runner.currentTestRun = current

        XCTAssertEqual(runner.dispatchIncomingRun(branchName: "release", isManualRun: false), .queued)
        XCTAssertEqual(runner.queuedRunCount, 1)

        runner.cancel()

        XCTAssertEqual(runner.queuedRunCount, 1)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["release"])
    }

    func testIdleRunnerReturnsStartNow() {
        let runner = TestRunner()

        let action = runner.dispatchIncomingRun(branchName: "develop", isManualRun: false)

        XCTAssertEqual(action, .startNow)
        XCTAssertEqual(runner.queuedRunCount, 0)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, [])
    }

    func testStartNotificationContentUsesInteractiveCategory() {
        let content = TestRunner.testStartNotificationContent(branchName: "develop")

        XCTAssertEqual(content.title, "Tests Started")
        XCTAssertEqual(content.body, "Running tests on branch: develop")
        XCTAssertEqual(content.categoryIdentifier, TestUserNotification.startCategoryIdentifier)
    }

    func testNotificationCategoriesIncludeStartActions() {
        let categories = AppDelegate.notificationCategories()
        let startCategory = categories.first { $0.identifier == TestUserNotification.startCategoryIdentifier }

        XCTAssertNotNil(startCategory)
        XCTAssertEqual(
            startCategory?.actions.map(\.identifier),
            [
                TestUserNotification.cancelActionIdentifier,
                TestUserNotification.openReportsActionIdentifier
            ]
        )
    }

    func testWatchdogDoesNotTriggerDuringBuildPhase() {
        let now = Date()

        XCTAssertFalse(
            TestRunner.watchdogShouldTrigger(
                isBuilding: true,
                testPhaseStartedAt: now.addingTimeInterval(-600),
                lastProgressAt: now.addingTimeInterval(-600),
                now: now,
                timeout: 300
            )
        )
    }

    func testWatchdogTriggersAfterProgressStallsInTestPhase() {
        let now = Date()

        XCTAssertTrue(
            TestRunner.watchdogShouldTrigger(
                isBuilding: false,
                testPhaseStartedAt: now.addingTimeInterval(-900),
                lastProgressAt: now.addingTimeInterval(-601),
                now: now,
                timeout: 600
            )
        )
    }

    func testWatchdogTimeoutDescriptionIncludesTimingAndCounts() {
        let now = Date(timeIntervalSince1970: 1_000)
        let summary = TestRunner.watchdogTimeoutDescription(
            now: now,
            testPhaseStartedAt: now.addingTimeInterval(-900),
            lastProgressAt: now.addingTimeInterval(-610),
            timeout: 600,
            passingCount: 358,
            failingCount: 0,
            totalCount: 400
        )

        XCTAssertEqual(
            summary,
            "Watchdog timed out after 10m 10s without test progress (limit 10m 0s) during the test phase. Counted 358 passing, 0 failing, 400 total. Test phase had been running for 15m 0s."
        )
    }
}
