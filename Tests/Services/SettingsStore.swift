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
    
    @Published var repositoryPath: String {
        didSet {
            UserDefaults.standard.set(repositoryPath, forKey: "repositoryPath")
        }
    }
    
    @Published var branchName: String? {
        didSet {
            if let branch = branchName, !branch.isEmpty {
                UserDefaults.standard.set(branch, forKey: "branchName")
            } else {
                UserDefaults.standard.removeObject(forKey: "branchName")
            }
        }
    }
    
    private init() {
        self.repositoryPath = UserDefaults.standard.string(forKey: "repositoryPath") ?? ""
        self.branchName = UserDefaults.standard.string(forKey: "branchName")
    }
    
    func setRepositoryPath(_ path: String) {
        repositoryPath = path
    }
    
    func setBranchName(_ branch: String?) {
        branchName = branch
    }
    
    var isConfigured: Bool {
        !repositoryPath.isEmpty
    }
}

