//
//  SettingsView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var repositoryPath: String = ""
    @State private var branchName: String = ""
    @State private var ignoredAutomaticBranchPrefixes: String = ""
    @State private var parallelTestingEnabled: Bool = true
    @State private var preBuildScript: String = ""
    
    var body: some View {
        VStack(spacing: 18) {
            header

            settingsCard(
                title: "Repository",
                description: "Choose the Loopy Pro repository. The workspace is discovered automatically."
            ) {
                HStack(alignment: .center, spacing: 12) {
                    TextField("Repository path", text: $repositoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        selectRepositoryPath()
                    }
                    .controlSize(.large)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                settingsCard(
                    title: "Default Branch",
                    description: "Used for manual runs when you do not explicitly choose a branch."
                ) {
                    TextField("Branch name", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                }

                settingsCard(
                    title: "Test Parallelization",
                    description: "Let xcodebuild execute tests in parallel when supported."
                ) {
                    Toggle("Enable parallel testing", isOn: $parallelTestingEnabled)
                        .toggleStyle(.switch)
                }
            }

            settingsCard(
                title: "Pre-Build Script",
                description: "Optional shell script to run in the prepared workspace before the build starts. A non-zero exit code cancels the run."
            ) {
                TextField("Shell script", text: $preBuildScript)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            settingsCard(
                title: "Ignore Automatic Branches",
                description: "Comma-separated branch prefixes that should ignore incoming post-hook triggers. Manual runs are still allowed."
            ) {
                TextField("codex/, spike/, wip/", text: $ignoredAutomaticBranchPrefixes)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    NSApp.sendAction(#selector(NSWindow.close), to: nil, from: nil)
                }
                .controlSize(.large)

                Button("Save") {
                    saveSettings()
                    NSApp.sendAction(#selector(NSWindow.close), to: nil, from: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            repositoryPath = settings.repositoryPath
            branchName = settings.branchName ?? ""
            ignoredAutomaticBranchPrefixes = settings.ignoredAutomaticBranchPrefixes
            parallelTestingEnabled = settings.parallelTestingEnabled
            preBuildScript = settings.preBuildScript
        }
    }
    
    private func selectRepositoryPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Select Repository Directory"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                repositoryPath = url.path
            }
        }
    }
    
    private func saveSettings() {
        settings.setRepositoryPath(repositoryPath)
        settings.setBranchName(branchName.isEmpty ? nil : branchName)
        settings.setIgnoredAutomaticBranchPrefixes(ignoredAutomaticBranchPrefixes)
        settings.setParallelTestingEnabled(parallelTestingEnabled)
        settings.setPreBuildScript(preBuildScript)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Test Runner Settings")
                    .font(.system(size: 28, weight: .semibold))
                Text("Workspace, branch, and build execution defaults.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
