//
//  PostHookInstaller.swift
//  Tests
//

import Foundation

enum PostHookInstaller {
    private static let wrapperMarker = "# Managed by Tests"
    private static let managedHookNames = ["post-commit", "post-merge"]

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

        var canWrap: Bool {
            self == .existingHook
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
                return "Checking git hook status..."
            case .missingRepository:
                return "Select a repository to install automatic test triggers."
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled hook script was not found."
            case .notInstalled:
                return "Not installed."
            case .installed:
                return "Installed already."
            case .existingHook:
                return "Existing git hooks detected."
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
        case backupAlreadyExists

        var errorDescription: String? {
            switch self {
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled hook script was not found."
            case .hookAlreadyExists:
                return "Installed already."
            case .hookNotInstalled:
                return "Managed hooks are not installed."
            case .hookNotManaged:
                return "Existing git hook was not installed by Tests."
            case .backupAlreadyExists:
                return "A saved original hook already exists."
            }
        }
    }

    static func state(for repositoryURL: URL) -> State {
        guard bundledPostCommitHookURL() != nil else {
            return .missingBundledHook
        }

        let hookURLs = managedHookURLs(in: repositoryURL)
        guard hookURLs.count == managedHookNames.count else {
            return .missingGitRepository
        }

        var hasManagedHook = false
        var hasMissingManagedHook = false

        for hookURL in hookURLs {
            guard FileManager.default.fileExists(atPath: hookURL.path) else {
                hasMissingManagedHook = true
                continue
            }

            if isInstalledBundledHook(at: hookURL) || isManagedWrapper(at: hookURL) {
                hasManagedHook = true
            } else {
                return .existingHook
            }
        }

        if hasManagedHook && !hasMissingManagedHook {
            return .installed
        }

        return .notInstalled
    }

    static func install(in repositoryURL: URL) throws {
        guard let sourceURL = bundledPostCommitHookURL() else {
            throw InstallError.missingBundledHook
        }

        let hookURLs = managedHookURLs(in: repositoryURL)
        guard hookURLs.count == managedHookNames.count else {
            throw InstallError.missingGitRepository
        }

        let fileManager = FileManager.default
        for hookURL in hookURLs {
            if fileManager.fileExists(atPath: hookURL.path) &&
                !isInstalledBundledHook(at: hookURL) &&
                !isManagedWrapper(at: hookURL) {
                throw InstallError.hookAlreadyExists
            }
        }

        for hookURL in hookURLs where !fileManager.fileExists(atPath: hookURL.path) {
            try fileManager.createDirectory(
                at: hookURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(
                at: hookURL,
                withDestinationURL: sourceURL
            )
        }
    }

    static func wrapExistingHook(in repositoryURL: URL) throws {
        guard let sourceURL = bundledPostCommitHookURL() else {
            throw InstallError.missingBundledHook
        }

        let hookURLs = managedHookURLs(in: repositoryURL)
        guard hookURLs.count == managedHookNames.count else {
            throw InstallError.missingGitRepository
        }

        let fileManager = FileManager.default
        var hasUnmanagedExistingHook = false

        for hookURL in hookURLs {
            guard fileManager.fileExists(atPath: hookURL.path) else { continue }
            if !isInstalledBundledHook(at: hookURL), !isManagedWrapper(at: hookURL) {
                hasUnmanagedExistingHook = true
            }
        }

        guard hasUnmanagedExistingHook else {
            throw InstallError.hookAlreadyExists
        }

        for hookURL in hookURLs {
            if fileManager.fileExists(atPath: hookURL.path) {
                guard !isInstalledBundledHook(at: hookURL), !isManagedWrapper(at: hookURL) else {
                    continue
                }

                let originalURL = originalHookURL(for: hookURL)
                guard !fileManager.fileExists(atPath: originalURL.path) else {
                    throw InstallError.backupAlreadyExists
                }

                try fileManager.moveItem(at: hookURL, to: originalURL)
                do {
                    let wrapper = wrapperScript(
                        originalHookName: originalURL.lastPathComponent,
                        bundledHookURL: sourceURL
                    )
                    try wrapper.write(to: hookURL, atomically: true, encoding: .utf8)
                    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
                } catch {
                    if fileManager.fileExists(atPath: hookURL.path) {
                        try? fileManager.removeItem(at: hookURL)
                    }
                    try? fileManager.moveItem(at: originalURL, to: hookURL)
                    throw error
                }
            } else {
                try fileManager.createSymbolicLink(
                    at: hookURL,
                    withDestinationURL: sourceURL
                )
            }
        }
    }

    static func uninstall(in repositoryURL: URL) throws {
        let hookURLs = managedHookURLs(in: repositoryURL)
        guard hookURLs.count == managedHookNames.count else {
            throw InstallError.missingGitRepository
        }

        let fileManager = FileManager.default
        let existingHookURLs = hookURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingHookURLs.isEmpty else {
            throw InstallError.hookNotInstalled
        }

        var removedAnyManagedHook = false
        for hookURL in existingHookURLs {
            if isInstalledBundledHook(at: hookURL) {
                try fileManager.removeItem(at: hookURL)
                removedAnyManagedHook = true
                continue
            }

            if isManagedWrapper(at: hookURL) {
                let originalURL = originalHookURL(for: hookURL)
                guard fileManager.fileExists(atPath: originalURL.path) else {
                    throw InstallError.hookNotManaged
                }

                try fileManager.removeItem(at: hookURL)
                try fileManager.moveItem(at: originalURL, to: hookURL)
                removedAnyManagedHook = true
                continue
            }
        }

        guard removedAnyManagedHook else {
            throw InstallError.hookNotManaged
        }
    }

    private static func bundledPostCommitHookURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "post-commit", withExtension: nil) {
            return bundleURL
        }

        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/post-commit")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    private static func managedHookURLs(in repositoryURL: URL) -> [URL] {
        managedHookNames.compactMap { hookURL(in: repositoryURL, hookName: $0) }
    }

    private static func hookURL(in repositoryURL: URL, hookName: String) -> URL? {
        let result = runGitCommand(
            ["rev-parse", "--git-path", "hooks/\(hookName)"],
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

    private static func isManagedWrapper(at hookURL: URL) -> Bool {
        guard let content = try? String(contentsOf: hookURL, encoding: .utf8) else { return false }
        return content.contains(wrapperMarker) && content.contains(".tests-original")
    }

    private static func originalHookURL(for hookURL: URL) -> URL {
        hookURL.deletingLastPathComponent().appendingPathComponent("\(hookURL.lastPathComponent).tests-original")
    }

    private static func wrapperScript(originalHookName: String, bundledHookURL: URL) -> String {
        """
        #!/bin/sh
        \(wrapperMarker)
        # Original hook: \(originalHookName)

        hook_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
        original_hook="$hook_dir/\(originalHookName)"
        tests_hook=\(shellQuotedPath(bundledHookURL.path))

        original_status=0
        if [ -x "$original_hook" ]; then
            "$original_hook" "$@"
            original_status=$?
        fi

        if [ -x "$tests_hook" ]; then
            "$tests_hook" "$@"
        fi

        exit "$original_status"
        """
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
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
