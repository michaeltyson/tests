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
    @State private var parallelTestingEnabled: Bool = true
    @State private var parallelBuildJobCount: Int = 6
    @State private var preBuildScript: String = ""
    @State private var testInactivityTimeoutMinutes: Int = 10
    @State private var showAdvancedBuildSettings: Bool = false
    
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

            settingsCard(
                title: "Default Branch",
                description: "Used for manual runs when you do not explicitly choose a branch."
            ) {
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 16) {
                settingsCard(
                    title: "Test Parallelization",
                    description: "Let xcodebuild execute tests in parallel when supported."
                ) {
                    Toggle("Enable parallel testing", isOn: $parallelTestingEnabled)
                        .toggleStyle(.switch)
                }

                settingsCard(
                    title: "Build Parallelization",
                    description: "Uses the active scheme or project defaults for target parallelization during build-for-testing."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Uses scheme and project defaults", systemImage: "link")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)

                        if showAdvancedBuildSettings {
                            HStack {
                                Text("Build jobs")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Stepper(value: $parallelBuildJobCount, in: 1...32) {
                                    Text("\(parallelBuildJobCount)")
                                        .monospacedDigit()
                                        .frame(minWidth: 28, alignment: .trailing)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
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
                title: "Stuck Test Watchdog",
                description: "Fails a run if the test phase stops making progress for too long."
            ) {
                HStack {
                    Text("Timeout")
                        .foregroundColor(.secondary)
                    Spacer()
                    Stepper(value: $testInactivityTimeoutMinutes, in: 1...180) {
                        Text("\(testInactivityTimeoutMinutes) min")
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }
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
            parallelTestingEnabled = settings.parallelTestingEnabled
            parallelBuildJobCount = settings.parallelBuildJobCount
            preBuildScript = settings.preBuildScript
            testInactivityTimeoutMinutes = settings.testInactivityTimeoutMinutes
            showAdvancedBuildSettings = NSApp.currentEvent?.modifierFlags.contains(.option) == true
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
        settings.setParallelTestingEnabled(parallelTestingEnabled)
        settings.setParallelBuildJobCount(parallelBuildJobCount)
        settings.setPreBuildScript(preBuildScript)
        settings.setTestInactivityTimeoutMinutes(testInactivityTimeoutMinutes)
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

            Text(showAdvancedBuildSettings ? "Advanced" : "Standard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(showAdvancedBuildSettings ? .accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
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
