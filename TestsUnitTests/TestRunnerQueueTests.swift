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

    func testDetachedCheckoutTargetPrefersFetchedOriginBranch() {
        XCTAssertEqual(
            TestRunner.detachedCheckoutTarget(
                for: "release/2.1",
                localBranchExists: true,
                originBranchExists: true,
                mirroredSourceRemoteBranchExists: true
            ),
            "refs/remotes/origin/release/2.1"
        )
    }

    func testDetachedCheckoutTargetFallsBackToMirroredThenLocalBranch() {
        XCTAssertEqual(
            TestRunner.detachedCheckoutTarget(
                for: "release/2.1",
                localBranchExists: true,
                originBranchExists: false,
                mirroredSourceRemoteBranchExists: true
            ),
            TestRunner.mirroredSourceRemoteTrackingRef(for: "release/2.1")
        )
        XCTAssertEqual(
            TestRunner.detachedCheckoutTarget(
                for: "release/2.1",
                localBranchExists: true,
                originBranchExists: false,
                mirroredSourceRemoteBranchExists: false
            ),
            "refs/heads/release/2.1"
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

    func testCrashReportSummaryParsingIncludesExceptionAndCrashedThread() throws {
        let ips = """
        {"app_name":"xctest","timestamp":"2026-05-19 09:57:32.00 +1000","name":"xctest"}
        {
          "faultingThread" : 0,
          "vmRegionInfo" : "0xbbb563900 is in 0xbbb400000-0xbbb800000; bytes after start: 1456384",
          "exception" : {
            "codes" : "0x0000000000000001, 0x0003000bbb563900",
            "type" : "EXC_BAD_ACCESS",
            "signal" : "SIGSEGV",
            "subtype" : "KERN_INVALID_ADDRESS at 0x0003000bbb563900"
          },
          "termination" : {
            "code" : 11,
            "namespace" : "SIGNAL",
            "indicator" : "Segmentation fault: 11",
            "byProc" : "exc handler",
            "byPid" : 2812
          },
          "threads" : [
            {
              "triggered" : true,
              "queue" : "com.apple.main-thread",
              "frames" : [
                {
                  "imageOffset" : 50387630336,
                  "imageIndex" : 1
                },
                {
                  "symbol" : "Steinberg::IPtr<Steinberg::Vst::IEditController>::~IPtr()",
                  "inline" : true,
                  "imageIndex" : 0,
                  "imageOffset" : 11333848,
                  "symbolLocation" : 20,
                  "sourceLine" : 152,
                  "sourceFile" : "smartpointer.h"
                }
              ]
            }
          ],
          "usedImages" : [
            {
              "base" : 4549853184,
              "name" : "Loopy Tests macOS"
            },
            {
              "name" : "???"
            }
          ]
        }
        """

        let summary = try XCTUnwrap(
            TestRunner.parseCrashReportSummary(
                from: Data(ips.utf8),
                reportPath: "/Users/michael/Library/Logs/DiagnosticReports/xctest-2026-05-19-095732.ips"
            )
        )

        XCTAssertEqual(summary.reportPath, "/Users/michael/Library/Logs/DiagnosticReports/xctest-2026-05-19-095732.ips")
        XCTAssertTrue(summary.lines.contains("Triggered by Thread: 0, Dispatch Queue: com.apple.main-thread"))
        XCTAssertTrue(summary.lines.contains("Exception Type:    EXC_BAD_ACCESS (SIGSEGV)"))
        XCTAssertTrue(summary.lines.contains("Exception Subtype: KERN_INVALID_ADDRESS at 0x0003000bbb563900"))
        XCTAssertTrue(summary.lines.contains("Exception Codes:   0x0000000000000001, 0x0003000bbb563900"))
        XCTAssertTrue(summary.lines.contains("Termination Reason:  Namespace SIGNAL, Code 11, Segmentation fault: 11"))
        XCTAssertTrue(summary.lines.contains("Terminating Process: exc handler [2812]"))
        XCTAssertTrue(summary.lines.contains("VM Region Info: 0xbbb563900 is in 0xbbb400000-0xbbb800000; bytes after start: 1456384"))
        XCTAssertTrue(summary.lines.contains("Thread 0 Crashed::  Dispatch queue: com.apple.main-thread"))
        XCTAssertTrue(
            summary.lines.contains {
                $0.contains("Loopy Tests macOS")
                    && $0.contains("Steinberg::IPtr<Steinberg::Vst::IEditController>::~IPtr() + 20")
                    && $0.contains("(smartpointer.h:152) [inlined]")
            }
        )
    }

    func testTestRunStartDateParsingReadsXCResultTimestamp() throws {
        let date = try XCTUnwrap(
            TestRunner.testRunStartDate(
                fromResultBundleName: "Test-Loopy Pro (macOS)-2026.05.19_09-56-21-+1000.xcresult"
            )
        )

        XCTAssertEqual(date.timeIntervalSince1970, 1_779_148_581)
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

    func testWorkspaceBuildArtifactDirectoryUsesTempRootDerivedDataFolder() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/TempWorkspace/workspace", isDirectory: true)

        XCTAssertEqual(
            TestRunner.workspaceBuildArtifactDirectory(in: workspaceURL).path,
            "/tmp/TempWorkspace/DerivedData"
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

    func testWorkspaceFinderPrefersBroadWorkspaceSchemeOverFocusedTestSchemeWithFewerTestables() throws {
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
            "Example Pro (macOS)"
        )
    }

    func testWorkspaceFinderSelectsAggregateMacOSSchemeOverNarrowTestsScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let schemesDirectory = root
            .appendingPathComponent("Example Pro.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemesDirectory, withIntermediateDirectories: true)

        try schemeContents(testableNames: ["Example Tests macOS"]).write(
            to: schemesDirectory.appendingPathComponent("Example Tests macOS.xcscheme"),
            atomically: true,
            encoding: .utf8
        )
        try schemeContents(
            testableNames: [
                "Example Tests macOS",
                "History Tests macOS",
                "Rendering Tests macOS",
                "Audio Engine Tests macOS",
                "Database Tests macOS",
                "Common Tests macOS"
            ]
        ).write(
            to: schemesDirectory.appendingPathComponent("Example Pro (macOS).xcscheme"),
            atomically: true,
            encoding: .utf8
        )

        let schemeInfo = try XCTUnwrap(
            WorkspaceFinder.findSchemeInfos(in: root, preferredWorkspaceName: "Example Pro.xcworkspace").first
        )
        XCTAssertEqual(schemeInfo.name, "Example Pro (macOS)")
        XCTAssertEqual(schemeInfo.testableReferenceCount, 6)
        XCTAssertTrue(schemeInfo.testableNames.contains("History Tests macOS"))
    }

    func testSettingsInferenceDoesNotReplaceConfiguredBroadSchemeWithInferredNarrowTestScheme() {
        XCTAssertFalse(
            SettingsStore.shouldReplaceConfiguredSchemeName(
                "Example Pro (macOS)",
                with: "Example Tests macOS",
                availableSchemeNames: ["Example Tests macOS", "Example Pro (macOS)"]
            )
        )
    }

    func testSettingsInferenceReplacesEmptyOrInvalidConfiguredScheme() {
        XCTAssertTrue(
            SettingsStore.shouldReplaceConfiguredSchemeName(
                "",
                with: "Example Pro (macOS)",
                availableSchemeNames: ["Example Pro (macOS)"]
            )
        )
        XCTAssertTrue(
            SettingsStore.shouldReplaceConfiguredSchemeName(
                "Missing Scheme",
                with: "Example Pro (macOS)",
                availableSchemeNames: ["Example Pro (macOS)"]
            )
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

    func testWorkspaceCleanupTriggeredWhenCommitChangesUnderSameRef() {
        XCTAssertTrue(
            TestRunner.shouldCleanWorkspaceForPreparedStateChange(
                previousRef: "develop",
                previousCommitSHA: "1111111111111111111111111111111111111111",
                nextRef: "develop",
                nextCommitSHA: "2222222222222222222222222222222222222222"
            )
        )
    }

    func testWorkspaceCleanupSkippedWhenRefAndCommitAreUnchanged() {
        XCTAssertFalse(
            TestRunner.shouldCleanWorkspaceForPreparedStateChange(
                previousRef: "develop",
                previousCommitSHA: "1111111111111111111111111111111111111111",
                nextRef: "develop",
                nextCommitSHA: "1111111111111111111111111111111111111111"
            )
        )
    }

    func testWorkspaceCleanupTriggeredForExistingWorkspaceWithoutStoredCommit() {
        XCTAssertTrue(
            TestRunner.shouldCleanWorkspaceForPreparedStateChange(
                previousRef: "develop",
                previousCommitSHA: nil,
                nextRef: "develop",
                nextCommitSHA: "1111111111111111111111111111111111111111"
            )
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

        var completedRuns: [TestRun] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .testRunDidComplete,
            object: runner,
            queue: nil
        ) { notification in
            if let testRun = notification.userInfo?["testRun"] as? TestRun {
                completedRuns.append(testRun)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let firstAction = runner.dispatchIncomingRun(branchName: "develop", isManualRun: false)
        XCTAssertEqual(firstAction, .queuedAndCancelActive)
        XCTAssertEqual(runner.queuedRunCount, 1)
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["develop"])

        runner.cancelActiveRunForQueueReplacement()
        XCTAssertEqual(completedRuns.count, 1)
        XCTAssertEqual(completedRuns.first?.id, current.id)
        XCTAssertEqual(completedRuns.first?.status, .error)
        XCTAssertEqual(completedRuns.first?.errorDescription, "Run superseded by a newer request.")

        let secondAction = runner.dispatchIncomingRun(branchName: "develop", isManualRun: false)
        XCTAssertEqual(secondAction, .queuedAndCancelActive)
        XCTAssertEqual(runner.queuedRunCount, 1, "Duplicate same-branch trigger should be deduped")
        XCTAssertEqual(runner.queuedRunBranchesForTesting, ["develop"])
        XCTAssertEqual(completedRuns.count, 1)
    }

    func testSynchronousProcessDrainsOutputLargerThanPipeCapacity() {
        let result = TestRunner.runProcessSync(
            "/bin/zsh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x"]
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output.utf8.count, 200_000)
    }

    func testSynchronousProcessTimesOut() {
        let startedAt = Date()
        let result = TestRunner.runProcessSync(
            "/bin/sleep",
            arguments: ["30"],
            timeout: 0.1
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testKillAllProcessesTerminatesTrackedPreparationScript() throws {
        let runner = TestRunner()
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let completed = expectation(description: "Preparation script terminated")
        let resultLock = NSLock()
        var result: TestRunner.ShellCommandResult?

        DispatchQueue.global(qos: .userInitiated).async {
            let commandResult = runner.runShellScriptSync(
                "touch \(markerURL.path.shellQuotedForTest); exec sleep 30",
                in: FileManager.default.temporaryDirectory,
                label: "cancellation test"
            )
            resultLock.lock()
            result = commandResult
            resultLock.unlock()
            completed.fulfill()
        }

        let markerDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: markerURL.path), Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        runner.killAllProcesses()
        wait(for: [completed], timeout: 2)

        resultLock.lock()
        let capturedResult = result
        resultLock.unlock()
        XCTAssertEqual(capturedResult?.success, false)
        XCTAssertEqual(capturedResult?.timedOut, false)
    }

    func testSelectedPreparationPlaceholderShowsLiveOutput() {
        let placeholderID = UUID()

        XCTAssertTrue(
            TestHistoryRunPresentation.shouldShowLiveOutput(
                isRunning: true,
                currentRunID: nil,
                placeholderRunID: placeholderID,
                selectedRunID: placeholderID
            )
        )
    }

    func testPreparationStatusDoesNotClaimBuildHasStarted() {
        XCTAssertEqual(
            TestHistoryRunPresentation.statusText(
                currentRunID: nil,
                isBuilding: true,
                queuedRunCount: 1
            ),
            "Preparing... (1 queued)"
        )
    }

    func testRealRunReplacesSelectedPreparationPlaceholder() {
        let placeholderID = UUID()

        XCTAssertTrue(
            TestHistoryRunPresentation.shouldSelectCurrentRun(
                selectedRunID: placeholderID,
                placeholderRunID: placeholderID
            )
        )
        XCTAssertFalse(
            TestHistoryRunPresentation.shouldSelectCurrentRun(
                selectedRunID: UUID(),
                placeholderRunID: placeholderID
            )
        )
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
        XCTAssertEqual(TestUserNotification.startSoundFilename, "Tests-Ignition.wav")
        XCTAssertEqual(content.categoryIdentifier, TestUserNotification.startCategoryIdentifier)
        XCTAssertEqual(content.userInfo[TestUserNotification.branchUserInfoKey] as? String, "develop")
    }

    func testCompletionNotificationContentUsesCustomOutcomeSounds() {
        var success = TestRun(status: .success)
        success.passingCount = 12
        success.totalCount = 12
        let successContent = TestRunner.testCompletionNotificationContent(testRun: success)

        var failure = TestRun(status: .failed)
        failure.passingCount = 10
        failure.failingCount = 2
        failure.totalCount = 12
        let failureContent = TestRunner.testCompletionNotificationContent(testRun: failure)

        XCTAssertEqual(TestUserNotification.successSoundFilename, "Tests-Resolved.wav")
        XCTAssertEqual(TestUserNotification.failureSoundFilename, "Tests-Fracture.wav")
        XCTAssertEqual(TestRunner.notificationSoundFilename(for: .success), "Tests-Resolved.wav")
        XCTAssertEqual(TestRunner.notificationSoundFilename(for: .warnings), "Tests-Resolved.wav")
        XCTAssertEqual(TestRunner.notificationSoundFilename(for: .failed), "Tests-Fracture.wav")
        XCTAssertEqual(TestRunner.notificationSoundFilename(for: .error), "Tests-Fracture.wav")
        XCTAssertNil(TestRunner.notificationSoundFilename(for: .running))
        XCTAssertNil(TestRunner.notificationSoundFilename(for: .paused))
        XCTAssertEqual(successContent.title, "Tests Passed ✅")
        XCTAssertEqual(failureContent.title, "Tests Failed ❌")
        XCTAssertEqual(failureContent.categoryIdentifier, TestUserNotification.failureCategoryIdentifier)
        XCTAssertNil(successContent.sound)
        XCTAssertNil(failureContent.sound)
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

    private func schemeContents(testableNames: [String]) -> String {
        let testables = testableNames.map { name in
            """
                  <TestableReference>
                    <BuildableReference
                       BlueprintName = "\(name)" />
                  </TestableReference>
            """
        }.joined(separator: "\n")

        return """
        <Scheme>
          <TestAction>
            <Testables>
        \(testables)
            </Testables>
          </TestAction>
        </Scheme>
        """
    }
}

private extension String {
    var shellQuotedForTest: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
