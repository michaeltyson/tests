import XCTest
@testable import Tests

final class PostHookInstallerTests: XCTestCase {
    func testWrapExistingHookInstallsManagedWrapperAndRestoresOriginalOnUninstall() throws {
        let repositoryURL = try makeGitRepository()
        let postCommitHookURL = try hookURL(in: repositoryURL, name: "post-commit")
        let mergeHookURL = try hookURL(in: repositoryURL, name: "post-merge")
        let originalScript = """
        #!/bin/sh
        echo original
        """

        try originalScript.write(to: postCommitHookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: postCommitHookURL.path)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .existingHook)

        try PostHookInstaller.wrapExistingHook(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .installed)
        let wrappedScript = try String(contentsOf: postCommitHookURL, encoding: .utf8)
        XCTAssertTrue(wrappedScript.contains("# Managed by Tests"))
        XCTAssertTrue(wrappedScript.contains("post-commit.tests-original"))
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: mergeHookURL.path))

        let originalHookURL = postCommitHookURL.deletingLastPathComponent().appendingPathComponent("post-commit.tests-original")
        XCTAssertEqual(try String(contentsOf: originalHookURL, encoding: .utf8), originalScript)

        try PostHookInstaller.uninstall(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .existingHook)
        XCTAssertEqual(try String(contentsOf: postCommitHookURL, encoding: .utf8), originalScript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalHookURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeHookURL.path))
    }

    func testInstallCreatesBundledSymlinksAndUninstallRemovesThem() throws {
        let repositoryURL = try makeGitRepository()
        let postCommitHookURL = try hookURL(in: repositoryURL, name: "post-commit")
        let mergeHookURL = try hookURL(in: repositoryURL, name: "post-merge")

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .notInstalled)

        try PostHookInstaller.install(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .installed)
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: postCommitHookURL.path))
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: mergeHookURL.path))

        try PostHookInstaller.uninstall(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: postCommitHookURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeHookURL.path))
    }

    func testInstallUpgradesExistingManagedPostCommitByAddingPostMergeHook() throws {
        let repositoryURL = try makeGitRepository()
        let postCommitHookURL = try hookURL(in: repositoryURL, name: "post-commit")
        let mergeHookURL = try hookURL(in: repositoryURL, name: "post-merge")
        let bundledHookURL = try bundledHookURL()

        try FileManager.default.createSymbolicLink(at: postCommitHookURL, withDestinationURL: bundledHookURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeHookURL.path))

        try PostHookInstaller.install(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: postCommitHookURL.path))
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: mergeHookURL.path))
    }

    func testWrapExistingHookHandlesManagedAndUnmanagedMixedHooks() throws {
        let repositoryURL = try makeGitRepository()
        let postCommitHookURL = try hookURL(in: repositoryURL, name: "post-commit")
        let mergeHookURL = try hookURL(in: repositoryURL, name: "post-merge")
        let bundledHookURL = try bundledHookURL()
        let originalMergeScript = """
        #!/bin/sh
        echo merge-original
        """

        try FileManager.default.createSymbolicLink(at: postCommitHookURL, withDestinationURL: bundledHookURL)
        try originalMergeScript.write(to: mergeHookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mergeHookURL.path)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .existingHook)

        try PostHookInstaller.wrapExistingHook(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .installed)
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: postCommitHookURL.path))
        let wrappedMergeScript = try String(contentsOf: mergeHookURL, encoding: .utf8)
        XCTAssertTrue(wrappedMergeScript.contains("# Managed by Tests"))
        XCTAssertTrue(wrappedMergeScript.contains("post-merge.tests-original"))

        let originalMergeHookURL = mergeHookURL.deletingLastPathComponent().appendingPathComponent("post-merge.tests-original")
        XCTAssertEqual(try String(contentsOf: originalMergeHookURL, encoding: .utf8), originalMergeScript)

        try PostHookInstaller.uninstall(in: repositoryURL)

        XCTAssertEqual(PostHookInstaller.state(for: repositoryURL), .existingHook)
        XCTAssertFalse(FileManager.default.fileExists(atPath: postCommitHookURL.path))
        XCTAssertEqual(try String(contentsOf: mergeHookURL, encoding: .utf8), originalMergeScript)
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

    private func hookURL(in repositoryURL: URL, name: String) throws -> URL {
        let hooksURL = repositoryURL.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksURL, withIntermediateDirectories: true)
        return hooksURL.appendingPathComponent(name)
    }

    private func bundledHookURL() throws -> URL {
        if let bundleURL = Bundle.main.url(forResource: "post-commit", withExtension: nil) {
            return bundleURL
        }

        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Resources/post-commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: developmentURL.path))
        return developmentURL
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
