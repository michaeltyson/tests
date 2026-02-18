//
//  BranchSelectionView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit

struct BranchSelectionView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var branchName: String = ""
    @State private var availableBranches: [String] = []
    @State private var filteredBranches: [String] = []
    @State private var isLoading = false
    @State private var selectedIndex: Int = -1
    @FocusState private var isTextFieldFocused: Bool
    
    let onSelect: (String?) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Branch")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Choose a branch to test:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onChange(of: branchName) { oldValue, newValue in
                        filterBranches(newValue)
                        selectedIndex = -1
                    }
                    .onKeyPress(.return) {
                        if selectedIndex >= 0 && selectedIndex < filteredBranches.count {
                            onSelect(filteredBranches[selectedIndex])
                        } else if !branchName.isEmpty {
                            onSelect(branchName)
                        } else {
                            onSelect(nil)
                        }
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if selectedIndex > 0 {
                            selectedIndex -= 1
                        } else if !filteredBranches.isEmpty {
                            selectedIndex = filteredBranches.count - 1
                        }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if selectedIndex < filteredBranches.count - 1 {
                            selectedIndex += 1
                        } else if !filteredBranches.isEmpty {
                            selectedIndex = 0
                        }
                        return .handled
                    }
                    .onAppear {
                        isTextFieldFocused = true
                        loadBranches()
                    }
                
                // Dropdown list
                if isTextFieldFocused && !filteredBranches.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredBranches.enumerated()), id: \.element) { index, branch in
                                HStack {
                                    Text(branch)
                                        .font(.system(.body))
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(branch)
                                }
                                
                                if index < filteredBranches.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                }
            }
            
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading branches...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    onSelect(nil)
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Run Tests") {
                    if selectedIndex >= 0 && selectedIndex < filteredBranches.count {
                        onSelect(filteredBranches[selectedIndex])
                    } else if !branchName.isEmpty {
                        onSelect(branchName)
                    } else {
                        onSelect(nil)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
    
    private func loadBranches() {
        guard !settings.repositoryPath.isEmpty else { return }
        
        isLoading = true
        let repositoryPath = settings.repositoryPath
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["branch", "-a"]
            process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)
            
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    var branches = output.components(separatedBy: .newlines)
                        .map { line in
                            // Remove leading * and whitespace
                            var branch = line.trimmingCharacters(in: .whitespaces)
                            if branch.hasPrefix("* ") {
                                branch = String(branch.dropFirst(2))
                            }
                            
                            // Remove leading "+ " if present (branches ahead of remote)
                            if branch.hasPrefix("+ ") {
                                branch = String(branch.dropFirst(2))
                            }
                            
                            // Remove "remotes/" or "remotes/origin/" prefix but preserve branch name structure
                            if branch.hasPrefix("remotes/origin/") {
                                branch = String(branch.dropFirst("remotes/origin/".count))
                            } else if branch.hasPrefix("remotes/") {
                                branch = String(branch.dropFirst("remotes/".count))
                            }
                            
                            return branch.trimmingCharacters(in: .whitespaces)
                        }
                        .filter { !$0.isEmpty }
                        .filter { !$0.hasPrefix("HEAD") }
                        .filter { !$0.contains("->") } // Filter out symbolic refs
                    
                    // Remove duplicates and sort
                    branches = Array(Set(branches)).sorted()
                    
                    DispatchQueue.main.async {
                        self.availableBranches = branches
                        self.filteredBranches = branches
                        self.isLoading = false
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func filterBranches(_ searchText: String) {
        if searchText.isEmpty {
            filteredBranches = availableBranches
        } else {
            filteredBranches = availableBranches.filter { branch in
                branch.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
}

