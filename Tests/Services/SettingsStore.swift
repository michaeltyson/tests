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
        static let branchName = "branchName"
        static let parallelTestingEnabled = "parallelTestingEnabled"
        static let parallelBuildJobCount = "parallelBuildJobCount"
        static let preBuildScript = "preBuildScript"
        static let testInactivityTimeoutMinutes = "testInactivityTimeoutMinutes"
    }

    private static func sanitizedParallelBuildJobCount(_ value: Int) -> Int {
        max(1, value)
    }

    private static func sanitizedTestInactivityTimeoutMinutes(_ value: Int) -> Int {
        min(max(1, value), 180)
    }
    
    @Published var repositoryPath: String {
        didSet {
            UserDefaults.standard.set(repositoryPath, forKey: Keys.repositoryPath)
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

    @Published var testInactivityTimeoutMinutes: Int {
        didSet {
            UserDefaults.standard.set(testInactivityTimeoutMinutes, forKey: Keys.testInactivityTimeoutMinutes)
        }
    }
    
    private init() {
        self.repositoryPath = UserDefaults.standard.string(forKey: Keys.repositoryPath) ?? ""
        self.branchName = UserDefaults.standard.string(forKey: Keys.branchName)
        self.parallelTestingEnabled = UserDefaults.standard.object(forKey: Keys.parallelTestingEnabled) as? Bool ?? true
        let storedParallelBuildJobCount = UserDefaults.standard.object(forKey: Keys.parallelBuildJobCount) as? Int ?? 6
        self.parallelBuildJobCount = Self.sanitizedParallelBuildJobCount(storedParallelBuildJobCount)
        self.preBuildScript = UserDefaults.standard.string(forKey: Keys.preBuildScript) ?? ""
        let storedTestInactivityTimeoutMinutes = UserDefaults.standard.object(forKey: Keys.testInactivityTimeoutMinutes) as? Int ?? 10
        self.testInactivityTimeoutMinutes = Self.sanitizedTestInactivityTimeoutMinutes(storedTestInactivityTimeoutMinutes)
    }
    
    func setRepositoryPath(_ path: String) {
        repositoryPath = path
    }
    
    func setBranchName(_ branch: String?) {
        branchName = branch
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

    func setTestInactivityTimeoutMinutes(_ minutes: Int) {
        testInactivityTimeoutMinutes = Self.sanitizedTestInactivityTimeoutMinutes(minutes)
    }
    
    var isConfigured: Bool {
        !repositoryPath.isEmpty
    }
}
