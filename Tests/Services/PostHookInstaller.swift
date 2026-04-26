//
//  PostHookInstaller.swift
//  Tests
//

import Foundation

enum PostHookInstaller {
    enum State: Equatable {
        case unknown
        case missingRepository
        case missingGitRepository
        case missingBundledHook
        case notInstalled
        case installed
        case existingHook
        case installFailed(String)

        var canInstall: Bool {
            self == .notInstalled
        }

        var canUninstall: Bool {
            self == .installed
        }

        var isError: Bool {
            switch self {
            case .missingGitRepository, .missingBundledHook, .installFailed:
                return true
            case .unknown, .missingRepository, .notInstalled, .installed, .existingHook:
                return false
            }
        }

        var message: String {
            switch self {
            case .unknown:
                return "Checking post-commit hook status..."
            case .missingRepository:
                return "Select a repository to install automatic test triggers."
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled post-commit hook script was not found."
            case .notInstalled:
                return "Not installed."
            case .installed:
                return "Installed already."
            case .existingHook:
                return "A post-commit hook already exists."
            case let .installFailed(message):
                return message
            }
        }
    }

    enum InstallError: LocalizedError {
        case missingGitRepository
        case missingBundledHook
        case hookAlreadyExists
        case hookNotInstalled
        case hookNotManaged

        var errorDescription: String? {
            switch self {
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled post-commit hook script was not found."
            case .hookAlreadyExists:
                return "Installed already."
            case .hookNotInstalled:
                return "Post-commit hook is not installed."
            case .hookNotManaged:
                return "Existing post-commit hook was not installed by Tests."
            }
        }
    }

    static func state(for repositoryURL: URL) -> State {
        guard let hookURL = postCommitHookURL(in: repositoryURL) else {
            return .missingGitRepository
        }

        guard bundledPostCommitHookURL() != nil else {
            return .missingBundledHook
        }

        guard FileManager.default.fileExists(atPath: hookURL.path) else {
            return .notInstalled
        }

        return isInstalledBundledHook(at: hookURL) ? .installed : .existingHook
    }

    static func install(in repositoryURL: URL) throws {
        guard let sourceURL = bundledPostCommitHookURL() else {
            throw InstallError.missingBundledHook
        }

        guard let hookURL = postCommitHookURL(in: repositoryURL) else {
            throw InstallError.missingGitRepository
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: hookURL.path) else {
            throw InstallError.hookAlreadyExists
        }

        try fileManager.createDirectory(
            at: hookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: hookURL,
            withDestinationURL: sourceURL
        )
    }

    static func uninstall(in repositoryURL: URL) throws {
        guard let hookURL = postCommitHookURL(in: repositoryURL) else {
            throw InstallError.missingGitRepository
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: hookURL.path) else {
            throw InstallError.hookNotInstalled
        }

        guard isInstalledBundledHook(at: hookURL) else {
            throw InstallError.hookNotManaged
        }

        try fileManager.removeItem(at: hookURL)
    }

    private static func bundledPostCommitHookURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "post-commit", withExtension: nil) {
            return bundleURL
        }

        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/post-commit")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    private static func postCommitHookURL(in repositoryURL: URL) -> URL? {
        let result = runGitCommand(
            ["rev-parse", "--git-path", "hooks/post-commit"],
            in: repositoryURL
        )
        guard result.success else { return nil }

        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return repositoryURL.appendingPathComponent(path)
    }

    private static func isInstalledBundledHook(at hookURL: URL) -> Bool {
        guard let bundledURL = bundledPostCommitHookURL() else { return false }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: hookURL.path) else {
            return false
        }

        let destinationURL = URL(fileURLWithPath: destination, relativeTo: hookURL.deletingLastPathComponent())
            .standardizedFileURL
        return destinationURL.path == bundledURL.standardizedFileURL.path
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
