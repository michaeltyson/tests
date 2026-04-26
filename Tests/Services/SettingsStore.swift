//
//  SettingsStore.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation
import Combine

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let repositoryPath = "repositoryPath"
        static let workspaceName = "workspaceName"
        static let xcodeSchemeName = "xcodeSchemeName"
        static let branchName = "branchName"
        static let ignoredAutomaticBranchPrefixes = "ignoredAutomaticBranchPrefixes"
        static let parallelTestingEnabled = "parallelTestingEnabled"
        static let parallelBuildJobCount = "parallelBuildJobCount"
        static let preBuildScript = "preBuildScript"
    }

    private static func sanitizedParallelBuildJobCount(_ value: Int) -> Int {
        max(1, value)
    }
    
    @Published var repositoryPath: String {
        didSet {
            UserDefaults.standard.set(repositoryPath, forKey: Keys.repositoryPath)
        }
    }

    @Published var workspaceName: String {
        didSet {
            let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.workspaceName)
            } else {
                UserDefaults.standard.set(trimmedName, forKey: Keys.workspaceName)
            }
        }
    }

    @Published var xcodeSchemeName: String {
        didSet {
            let trimmedName = xcodeSchemeName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.xcodeSchemeName)
            } else {
                UserDefaults.standard.set(trimmedName, forKey: Keys.xcodeSchemeName)
            }
        }
    }
    
    @Published var branchName: String? {
        didSet {
            if let branch = branchName, !branch.isEmpty {
                UserDefaults.standard.set(branch, forKey: Keys.branchName)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.branchName)
            }
        }
    }

    @Published var ignoredAutomaticBranchPrefixes: String {
        didSet {
            let normalizedPrefixes = Self.normalizedIgnoredAutomaticBranchPrefixes(ignoredAutomaticBranchPrefixes)
            if normalizedPrefixes.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.ignoredAutomaticBranchPrefixes)
            } else {
                UserDefaults.standard.set(normalizedPrefixes, forKey: Keys.ignoredAutomaticBranchPrefixes)
            }
        }
    }

    @Published var parallelTestingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(parallelTestingEnabled, forKey: Keys.parallelTestingEnabled)
        }
    }

    @Published var parallelBuildJobCount: Int {
        didSet {
            UserDefaults.standard.set(parallelBuildJobCount, forKey: Keys.parallelBuildJobCount)
        }
    }

    @Published var preBuildScript: String {
        didSet {
            let trimmedScript = preBuildScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedScript.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.preBuildScript)
            } else {
                UserDefaults.standard.set(preBuildScript, forKey: Keys.preBuildScript)
            }
        }
    }

    private init() {
        self.repositoryPath = UserDefaults.standard.string(forKey: Keys.repositoryPath) ?? ""
        self.workspaceName = UserDefaults.standard.string(forKey: Keys.workspaceName) ?? ""
        self.xcodeSchemeName = UserDefaults.standard.string(forKey: Keys.xcodeSchemeName) ?? ""
        self.branchName = UserDefaults.standard.string(forKey: Keys.branchName)
        self.ignoredAutomaticBranchPrefixes = Self.normalizedIgnoredAutomaticBranchPrefixes(
            UserDefaults.standard.string(forKey: Keys.ignoredAutomaticBranchPrefixes) ?? ""
        )
        self.parallelTestingEnabled = UserDefaults.standard.object(forKey: Keys.parallelTestingEnabled) as? Bool ?? true
        let storedParallelBuildJobCount = UserDefaults.standard.object(forKey: Keys.parallelBuildJobCount) as? Int ?? 6
        self.parallelBuildJobCount = Self.sanitizedParallelBuildJobCount(storedParallelBuildJobCount)
        self.preBuildScript = UserDefaults.standard.string(forKey: Keys.preBuildScript) ?? ""
    }
    
    func setRepositoryPath(_ path: String) {
        repositoryPath = path
    }

    func setWorkspaceName(_ name: String) {
        workspaceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setXcodeSchemeName(_ name: String) {
        xcodeSchemeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func setBranchName(_ branch: String?) {
        branchName = branch
    }

    func setIgnoredAutomaticBranchPrefixes(_ prefixes: String) {
        ignoredAutomaticBranchPrefixes = Self.normalizedIgnoredAutomaticBranchPrefixes(prefixes)
    }

    func addIgnoredAutomaticBranchPrefix(_ prefix: String) {
        let updatedPrefixes = Self.addingIgnoredAutomaticBranchPrefix(
            prefix,
            to: ignoredAutomaticBranchPrefixes
        )
        guard updatedPrefixes != ignoredAutomaticBranchPrefixes else { return }
        ignoredAutomaticBranchPrefixes = updatedPrefixes
    }

    func shouldIgnoreAutomaticRun(for branchName: String?) -> Bool {
        guard let branchName else { return false }
        return Self.shouldIgnoreAutomaticRun(
            for: branchName,
            ignoredPrefixesText: ignoredAutomaticBranchPrefixes
        )
    }

    func setParallelTestingEnabled(_ enabled: Bool) {
        parallelTestingEnabled = enabled
    }

    func setParallelBuildJobCount(_ jobCount: Int) {
        parallelBuildJobCount = Self.sanitizedParallelBuildJobCount(jobCount)
    }

    func setPreBuildScript(_ script: String) {
        preBuildScript = script
    }

    static func parsedIgnoredAutomaticBranchPrefixes(from value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedIgnoredAutomaticBranchPrefixes(_ value: String) -> String {
        var seen = Set<String>()
        let uniquePrefixes = parsedIgnoredAutomaticBranchPrefixes(from: value).filter { seen.insert($0).inserted }
        return uniquePrefixes.joined(separator: ", ")
    }

    static func shouldIgnoreAutomaticRun(for branchName: String, ignoredPrefixesText: String) -> Bool {
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return false }

        return parsedIgnoredAutomaticBranchPrefixes(from: ignoredPrefixesText).contains { prefix in
            trimmedBranch.hasPrefix(prefix)
        }
    }

    static func addingIgnoredAutomaticBranchPrefix(_ prefix: String, to existingPrefixesText: String) -> String {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            return normalizedIgnoredAutomaticBranchPrefixes(existingPrefixesText)
        }

        let prefixes = parsedIgnoredAutomaticBranchPrefixes(from: existingPrefixesText) + [prefix]
        return normalizedIgnoredAutomaticBranchPrefixes(prefixes.joined(separator: ","))
    }
    
    var isConfigured: Bool {
        !repositoryPath.isEmpty
    }
}
