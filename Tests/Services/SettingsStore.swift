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
        static let parallelBuildTargetsEnabled = "parallelBuildTargetsEnabled"
        static let parallelBuildJobCount = "parallelBuildJobCount"
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

    @Published var parallelBuildTargetsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(parallelBuildTargetsEnabled, forKey: Keys.parallelBuildTargetsEnabled)
        }
    }

    @Published var parallelBuildJobCount: Int {
        didSet {
            parallelBuildJobCount = max(1, parallelBuildJobCount)
            UserDefaults.standard.set(parallelBuildJobCount, forKey: Keys.parallelBuildJobCount)
        }
    }
    
    private init() {
        self.repositoryPath = UserDefaults.standard.string(forKey: Keys.repositoryPath) ?? ""
        self.branchName = UserDefaults.standard.string(forKey: Keys.branchName)
        self.parallelTestingEnabled = UserDefaults.standard.object(forKey: Keys.parallelTestingEnabled) as? Bool ?? true
        self.parallelBuildTargetsEnabled = UserDefaults.standard.object(forKey: Keys.parallelBuildTargetsEnabled) as? Bool ?? true
        let storedParallelBuildJobCount = UserDefaults.standard.object(forKey: Keys.parallelBuildJobCount) as? Int ?? 6
        self.parallelBuildJobCount = max(1, storedParallelBuildJobCount)
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

    func setParallelBuildTargetsEnabled(_ enabled: Bool) {
        parallelBuildTargetsEnabled = enabled
    }

    func setParallelBuildJobCount(_ jobCount: Int) {
        parallelBuildJobCount = jobCount
    }
    
    var isConfigured: Bool {
        !repositoryPath.isEmpty
    }
}
