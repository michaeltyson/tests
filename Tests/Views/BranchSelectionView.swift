//
//  BranchSelectionView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit

struct BranchSelectionView: View {
    private struct RefSuggestion: Identifiable {
        enum Kind {
            case branch
            case commit
        }

        let kind: Kind
        let ref: String
        let title: String
        let subtitle: String?

        var id: String { "\(kind)-\(ref)" }
    }

    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var testResultStore: TestResultStore
    @State private var branchName: String = ""
    @State private var availableRefs: [RefSuggestion] = []
    @State private var filteredRefs: [RefSuggestion] = []
    @State private var isLoading = false
    @State private var selectedIndex: Int = -1
    @FocusState private var isTextFieldFocused: Bool
    
    let onSelect: (String?) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Branch")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Choose a branch or commit to test:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("Branch, commit SHA, or message", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onChange(of: branchName) { oldValue, newValue in
                        filterRefs(newValue)
                        selectedIndex = -1
                    }
                    .onKeyPress(.return) {
                        if selectedIndex >= 0 && selectedIndex < filteredRefs.count {
                            onSelect(filteredRefs[selectedIndex].ref)
                        } else if !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSelect(branchName.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            onSelect(nil)
                        }
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if selectedIndex > 0 {
                            selectedIndex -= 1
                        } else if !filteredRefs.isEmpty {
                            selectedIndex = filteredRefs.count - 1
                        }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if selectedIndex < filteredRefs.count - 1 {
                            selectedIndex += 1
                        } else if !filteredRefs.isEmpty {
                            selectedIndex = 0
                        }
                        return .handled
                    }
                    .onAppear {
                        isTextFieldFocused = true
                    }
                
                refsList
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    onSelect(nil)
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Run Tests") {
                    if selectedIndex >= 0 && selectedIndex < filteredRefs.count {
                        onSelect(filteredRefs[selectedIndex].ref)
                    } else if !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSelect(branchName.trimmingCharacters(in: .whitespacesAndNewlines))
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
        .onAppear {
            loadBranches()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RefreshBranchList"))) { _ in
            loadBranches()
        }
    }

    @ViewBuilder
    private var refsList: some View {
        Group {
            if !filteredRefs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredRefs.enumerated()), id: \.element.id) { index, suggestion in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(.system(.body))
                                    if let subtitle = suggestion.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(suggestion.ref)
                            }

                            if index < filteredRefs.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            } else if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading branches and commits...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                VStack(spacing: 6) {
                    Spacer()
                    Text(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No branches found." : "No matching branches or commits.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if settings.repositoryPath.isEmpty {
                        Text("Set a repository path in Settings to load branches.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
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
    
    private func loadBranches() {
        guard !settings.repositoryPath.isEmpty else { return }
        
        isLoading = true
        let repositoryPath = settings.repositoryPath
        let recentBranchOrder = recentBranchOrder()
        
        DispatchQueue.global(qos: .userInitiated).async {
            let branchOutput = self.runGitCommand(["branch", "-a"], repositoryPath: repositoryPath)
            let commitOutput = self.runGitCommand(
                ["log", "--all", "--pretty=format:%H%x09%h%x09%s", "-n", "250"],
                repositoryPath: repositoryPath
            )

            let branchSuggestions = self.parseBranchSuggestions(
                from: branchOutput ?? "",
                recentBranchOrder: recentBranchOrder
            )
            let commitSuggestions = self.parseCommitSuggestions(from: commitOutput ?? "")
            let allSuggestions = branchSuggestions + commitSuggestions

            DispatchQueue.main.async {
                self.availableRefs = allSuggestions
                self.filterRefs(self.branchName)
                self.isLoading = false
            }
        }
    }
    
    private func runGitCommand(_ arguments: [String], repositoryPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func parseBranchSuggestions(from output: String, recentBranchOrder: [String: Int]) -> [RefSuggestion] {
        let branches = GitHistoryService.normalizedBranchNames(fromBranchList: output).sorted {
            switch (recentBranchOrder[$0], recentBranchOrder[$1]) {
            case let (lhs?, rhs?):
                return lhs == rhs ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
        return branches.map { branch in
            RefSuggestion(kind: .branch, ref: branch, title: branch, subtitle: "Branch")
        }
    }

    private func recentBranchOrder() -> [String: Int] {
        var order: [String: Int] = [:]
        let recentRuns = testResultStore.testRuns.sorted { $0.timestamp > $1.timestamp }

        for run in recentRuns {
            guard let branch = normalizedBranchName(run.branchName), order[branch] == nil else {
                continue
            }
            order[branch] = order.count
        }

        return order
    }

    private func normalizedBranchName(_ branchName: String?) -> String? {
        guard var branchName else { return nil }
        branchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if branchName.hasPrefix("+") {
            branchName = String(branchName.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return branchName.isEmpty ? nil : branchName
    }

    private func parseCommitSuggestions(from output: String) -> [RefSuggestion] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { return nil }
            let fullSHA = fields[0].trimmingCharacters(in: .whitespaces)
            let shortSHA = fields[1].trimmingCharacters(in: .whitespaces)
            let subject = fields[2].trimmingCharacters(in: .whitespaces)
            guard !fullSHA.isEmpty, !shortSHA.isEmpty else { return nil }
            return RefSuggestion(
                kind: .commit,
                ref: fullSHA,
                title: "\(shortSHA) \(subject)",
                subtitle: "Commit \(fullSHA)"
            )
        }
    }

    private func filterRefs(_ searchText: String) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filteredRefs = availableRefs.filter { $0.kind == .branch }
            return
        }

        let lowercased = trimmed.lowercased()
        let branchMatches = availableRefs.filter {
            $0.kind == .branch && $0.ref.localizedCaseInsensitiveContains(trimmed)
        }
        let commitMatches = availableRefs.filter { suggestion in
            guard suggestion.kind == .commit else { return false }
            return suggestion.ref.lowercased().hasPrefix(lowercased)
                || suggestion.title.lowercased().contains(lowercased)
                || (suggestion.subtitle?.lowercased().contains(lowercased) ?? false)
        }

        filteredRefs = branchMatches + commitMatches
    }
}
