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
        case installFailed(String)

        var canInstall: Bool {
            self == .notInstalled
        }

        var isError: Bool {
            switch self {
            case .missingGitRepository, .missingBundledHook, .installFailed:
                return true
            case .unknown, .missingRepository, .notInstalled, .installed:
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
            case let .installFailed(message):
                return message
            }
        }
    }

    enum InstallError: LocalizedError {
        case missingGitRepository
        case missingBundledHook
        case hookAlreadyExists

        var errorDescription: String? {
            switch self {
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled post-commit hook script was not found."
            case .hookAlreadyExists:
                return "Installed already."
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

        return FileManager.default.fileExists(atPath: hookURL.path) ? .installed : .notInstalled
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
