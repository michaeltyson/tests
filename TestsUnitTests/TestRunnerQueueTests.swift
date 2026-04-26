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

    func testBundledXcbeautifyPathIsPreferredOverHomebrew() {
        XCTAssertEqual(
            TestRunner.xcbeautifyExecutablePath(
                bundledPath: "/app/xcbeautify",
                homebrewPaths: ["/opt/homebrew/bin/xcbeautify"],
                isExecutable: { $0 == "/app/xcbeautify" || $0 == "/opt/homebrew/bin/xcbeautify" }
            ),
            "/app/xcbeautify"
        )
    }

    func testXcbeautifyPathFallsBackToHomebrew() {
        XCTAssertEqual(
            TestRunner.xcbeautifyExecutablePath(
                bundledPath: "/app/xcbeautify",
                homebrewPaths: ["/opt/homebrew/bin/xcbeautify"],
                isExecutable: { $0 == "/opt/homebrew/bin/xcbeautify" }
            ),
            "/opt/homebrew/bin/xcbeautify"
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
                      "nodeIdentifier" : "ExampleTests/CalculatorTests/testFailure",
                      "result" : "Failed",
                      "children" : [
                        {
                          "nodeType" : "Failure Message",
                          "name" : "XCTAssertEqual failed: (\\"1\\") is not equal to (\\"2\\")",
                          "documentLocationInCreatingWorkspace" : {
                            "url" : "file:///tmp/CalculatorTests.swift",
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
                    identifier: "ExampleTests/CalculatorTests/testFailure",
                    messages: [
                        "/tmp/CalculatorTests.swift:42: XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
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
        let workspaceURL = URL(fileURLWithPath: "/tmp/ExampleWorkspace", isDirectory: true)

        XCTAssertEqual(
            TestRunner.workspaceBuildArtifactDirectory(in: workspaceURL).path,
            "/tmp/ExampleWorkspace/.DerivedData"
        )
    }

    func testWorkspaceBuildArtifactDirectoryNamesCoverCommonBuildCaches() {
        XCTAssertEqual(
            TestRunner.workspaceBuildArtifactDirectoryNames,
            [".DerivedData", "DerivedData", "build"]
        )
    }

    func testWorkspaceFinderUsesPreferredWorkspaceName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let firstWorkspace = root.appendingPathComponent("First.xcworkspace", isDirectory: true)
        let preferredWorkspace = root.appendingPathComponent("Preferred.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: firstWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferredWorkspace, withIntermediateDirectories: true)

        XCTAssertEqual(
            WorkspaceFinder.findWorkspace(in: root, preferredName: "Preferred")?.lastPathComponent,
            "Preferred.xcworkspace"
        )
    }

    func testWorkspaceFinderFallsBackWhenPreferredWorkspaceIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Only.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            WorkspaceFinder.findWorkspace(in: root, preferredName: "Missing")?.lastPathComponent,
            "Only.xcworkspace"
        )
    }

    func testWorkspaceFinderFindsSharedSchemeName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let schemesDirectory = root
            .appendingPathComponent("Example.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemesDirectory, withIntermediateDirectories: true)
        try """
        <Scheme>
          <TestAction>
            <Testables>
              <TestableReference />
            </Testables>
          </TestAction>
        </Scheme>
        """.write(
            to: schemesDirectory.appendingPathComponent("Example.xcscheme"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            WorkspaceFinder.findSchemeName(in: root, preferredWorkspaceName: "Example.xcworkspace"),
            "Example"
        )
    }

    func testWorkspaceFinderPrefersMacSchemeOverAllScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let schemesDirectory = root
            .appendingPathComponent("Example.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemesDirectory, withIntermediateDirectories: true)
        for schemeName in ["all", "Example (iOS)", "Example (macOS)"] {
            let schemeContents = schemeName == "Example (macOS)"
                ? """
                <Scheme>
                  <TestAction>
                    <Testables>
                      <TestableReference />
                      <TestableReference />
                    </Testables>
                  </TestAction>
                </Scheme>
                """
                : "<Scheme />"
            try schemeContents.write(
                to: schemesDirectory.appendingPathComponent("\(schemeName).xcscheme"),
                atomically: true,
                encoding: .utf8
            )
        }

        XCTAssertEqual(
            WorkspaceFinder.findSchemeName(in: root, preferredWorkspaceName: "Example.xcworkspace"),
            "Example (macOS)"
        )
    }

    func testWorkspaceFinderPrefersRootProjectSchemeOverDependencyScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let dependencySchemesDirectory = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("ExampleSupport.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        let rootSchemesDirectory = root
            .appendingPathComponent("Example.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencySchemesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootSchemesDirectory, withIntermediateDirectories: true)
        try """
        <Scheme>
          <TestAction>
            <Testables>
              <TestableReference />
            </Testables>
          </TestAction>
        </Scheme>
        """.write(
            to: dependencySchemesDirectory.appendingPathComponent("ExampleSupport macOS.xcscheme"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <Scheme>
          <TestAction>
            <Testables>
              <TestableReference />
            </Testables>
          </TestAction>
        </Scheme>
        """.write(
            to: rootSchemesDirectory.appendingPathComponent("Example (macOS).xcscheme"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            WorkspaceFinder.findSchemeName(in: root, preferredWorkspaceName: "Example.xcworkspace"),
            "Example (macOS)"
        )
    }

    func testWorkspaceFinderPrefersSchemeWithTestables() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let schemesDirectory = root
            .appendingPathComponent("Example.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemesDirectory, withIntermediateDirectories: true)
        try "<Scheme />".write(
            to: schemesDirectory.appendingPathComponent("Example.xcscheme"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <Scheme>
          <TestAction>
            <Testables>
              <TestableReference />
            </Testables>
          </TestAction>
        </Scheme>
        """.write(
            to: schemesDirectory.appendingPathComponent("Example Tests.xcscheme"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            WorkspaceFinder.findSchemeName(in: root, preferredWorkspaceName: "Example.xcworkspace"),
            "Example Tests"
        )
    }

    func testWorkspaceFinderPrefersFocusedTestSchemeOverProductSchemeWithMoreTestables() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let productSchemesDirectory = root
            .appendingPathComponent("Example Pro.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        let testSchemesDirectory = root
            .appendingPathComponent("Common", isDirectory: true)
            .appendingPathComponent("Example.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: productSchemesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSchemesDirectory, withIntermediateDirectories: true)
        try """
        <Scheme>
          <TestAction>
            <Testables>
              <TestableReference />
              <TestableReference />
              <TestableReference />
              <TestableReference />
              <TestableReference />
              <TestableReference />
            </Testables>
          </TestAction>
        </Scheme>
        """.write(
            to: productSchemesDirectory.appendingPathComponent("Example Pro (macOS).xcscheme"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <Scheme>
          <TestAction>
            <Testables>
              <TestableReference />
            </Testables>
          </TestAction>
        </Scheme>
        """.write(
            to: testSchemesDirectory.appendingPathComponent("Example Tests macOS.xcscheme"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            WorkspaceFinder.findSchemeName(in: root, preferredWorkspaceName: "Example Pro.xcworkspace"),
            "Example Tests macOS"
        )
    }

    func testInferredXcodeDestinationUsesMacOSPlatform() {
        XCTAssertTrue(TestRunner.inferredXcodeDestination().hasPrefix("platform=macOS"))
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

    func testWorkspaceLocalChangeCleanupDiscardsTrackedAndUntrackedFiles() throws {
        XCTAssertEqual(
            TestRunner.discardWorkspaceLocalChangesCommandArguments(),
            [
                ["reset", "--hard", "HEAD"],
                ["clean", "-ffd"]
            ]
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try runGit(["init"], in: root)
        try runGit(["config", "user.email", "tests@example.com"], in: root)
        try runGit(["config", "user.name", "Tests"], in: root)
        let trackedFile = root.appendingPathComponent("tracked.txt")
        try "committed\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], in: root)
        try runGit(["commit", "-m", "Initial commit"], in: root)

        try "dirty\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try "untracked\n".write(
            to: root.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        for arguments in TestRunner.discardWorkspaceLocalChangesCommandArguments() {
            try runGit(arguments, in: root)
        }

        let status = try runGit(["status", "--short"], in: root)
        XCTAssertEqual(status, "")
        XCTAssertEqual(try String(contentsOf: trackedFile, encoding: .utf8), "committed\n")
    }

    func testSourceRemoteTrackingRefspecMirrorsRemoteOnlyBranches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try runGit(["init"], in: source)
        try runGit(["config", "user.email", "tests@example.com"], in: source)
        try runGit(["config", "user.name", "Tests"], in: source)
        let readme = source.appendingPathComponent("README.md")
        try "initial\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: source)
        try runGit(["commit", "-m", "Initial commit"], in: source)
        try runGit(["update-ref", "refs/remotes/origin/release/2.1", "HEAD"], in: source)

        try runGit(["clone", "file://\(source.path)", clone.path], in: root)
        XCTAssertThrowsError(
            try runGit(
                ["show-ref", "--verify", "refs/remotes/origin/release/2.1"],
                in: clone
            )
        )

        try runGit(["fetch", "origin", TestRunner.sourceRemoteTrackingFetchRefspec], in: clone)
        try runGit(
            ["checkout", "-B", "release/2.1", TestRunner.mirroredSourceRemoteTrackingRef(for: "release/2.1")],
            in: clone
        )

        let checkedOutBranch = try runGit(["branch", "--show-current"], in: clone)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(checkedOutBranch, "release/2.1")
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
        XCTAssertEqual(content.userInfo[TestUserNotification.branchUserInfoKey] as? String, "develop")
    }

    func testNotificationCategoriesIncludeStartActions() {
        let categories = AppDelegate.notificationCategories()
        let startCategory = categories.first { $0.identifier == TestUserNotification.startCategoryIdentifier }

        XCTAssertNotNil(startCategory)
        XCTAssertEqual(
            startCategory?.actions.map(\.identifier),
            [
                TestUserNotification.cancelActionIdentifier,
                TestUserNotification.prohibitBranchActionIdentifier,
                TestUserNotification.openReportsActionIdentifier
            ]
        )
    }

    func testIgnoredAutomaticBranchPrefixesAreParsedAndNormalized() {
        XCTAssertEqual(
            SettingsStore.parsedIgnoredAutomaticBranchPrefixes(from: " codex/, , spike/feature , codex/ "),
            ["codex/", "spike/feature", "codex/"]
        )
        XCTAssertEqual(
            SettingsStore.normalizedIgnoredAutomaticBranchPrefixes(" codex/, , spike/feature , codex/ "),
            "codex/, spike/feature"
        )
    }

    func testAutomaticRunIgnoreMatchingUsesPrefixSemantics() {
        XCTAssertTrue(
            SettingsStore.shouldIgnoreAutomaticRun(
                for: "codex/fix-ci",
                ignoredPrefixesText: "codex/, release/"
            )
        )
        XCTAssertFalse(
            SettingsStore.shouldIgnoreAutomaticRun(
                for: "feature/codex-fix-ci",
                ignoredPrefixesText: "codex/, release/"
            )
        )
    }

    func testAddingIgnoredAutomaticBranchPrefixAppendsUniquely() {
        XCTAssertEqual(
            SettingsStore.addingIgnoredAutomaticBranchPrefix("codex/feature-a", to: "codex/, release/"),
            "codex/, release/, codex/feature-a"
        )
        XCTAssertEqual(
            SettingsStore.addingIgnoredAutomaticBranchPrefix("codex/", to: "codex/, release/"),
            "codex/, release/"
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

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "TestRunnerQueueTests.git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(output)"
                ]
            )
        }
        return output
    }
}
