import XCTest
@testable import Tests

final class PostHookInstallerTests: XCTestCase {
    func testWrapExistingHookInstallsManagedWrapperAndRestoresOriginalOnUninstall() throws {
        let repositoryURL = try makeGitRepository()
        let hookURL = try postCommitHookURL(in: repositoryURL)
        let originalScript = """
        #!/bin/sh
        echo original
        """

        try originalScript.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .existingHook)

        try PostHookInstaller.wrapExistingHook(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .installed)
        let wrappedScript = try String(contentsOf: hookURL, encoding: .utf8)
        XCTAssertTrue(wrappedScript.contains("# Managed by Tests"))
        XCTAssertTrue(wrappedScript.contains("post-commit.tests-original"))

        let originalHookURL = hookURL.deletingLastPathComponent().appendingPathComponent("post-commit.tests-original")
        XCTAssertEqual(try String(contentsOf: originalHookURL, encoding: .utf8), originalScript)

        try PostHookInstaller.uninstall(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .existingHook)
        XCTAssertEqual(try String(contentsOf: hookURL, encoding: .utf8), originalScript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalHookURL.path))
    }

    func testInstallCreatesBundledSymlinkAndUninstallRemovesIt() throws {
        let repositoryURL = try makeGitRepository()
        let hookURL = try postCommitHookURL(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .notInstalled)

        try PostHookInstaller.install(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .installed)
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: hookURL.path))

        try PostHookInstaller.uninstall(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookURL.path))
    }

    private func makeGitRepository() throws -> URL {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(["init"], in: repositoryURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        return repositoryURL
    }

    private func postCommitHookURL(in repositoryURL: URL) throws -> URL {
        let hooksURL = repositoryURL.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksURL, withIntermediateDirectories: true)
        return hooksURL.appendingPathComponent("post-commit")
    }

    private func runGit(_ arguments: [String], in repositoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
