//
//  OnboardingView.swift
//  Tests
//

import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject private var settings = SettingsStore.shared
    let onFinish: (Bool) -> Void
    let onSkip: () -> Void

    @State private var repositoryPath: String = ""
    @State private var workspaceName: String = ""
    @State private var xcodeSchemeName: String = ""
    @State private var branchName: String = ""
    @State private var ignoredAutomaticBranchPrefixes: String = ""
    @State private var parallelTestingEnabled: Bool = true
    @State private var parallelBuildJobCount: Int = 6
    @State private var preBuildScript: String = ""
    @State private var workspaceOptions: [String] = []
    @State private var schemeOptions: [String] = []
    @State private var branchOptions: [String] = []
    @State private var postHookState: PostHookInstaller.State = .missingRepository
    @State private var postHookMessage: String = PostHookInstaller.State.missingRepository.message
    @State private var advancedExpanded = false

    private var canFinish: Bool {
        !repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 16) {
                    repositoryStep
                    xcodeStep
                    automationStep
                    advancedStep
                    firstRunStep
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            footer
        }
        .frame(width: 760, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadSettings()
            discoverProjectSettingsIfPossible()
            refreshBranchOptions()
            refreshPostHookState()
        }
        .onChange(of: repositoryPath) { _, _ in
            discoverProjectSettingsIfPossible(force: true)
            refreshBranchOptions(force: true)
            refreshPostHookState()
        }
        .onChange(of: workspaceName) { _, _ in
            refreshSchemeOptions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set Up Tests")
                .font(.system(size: 30, weight: .semibold))
            Text("Choose a repository, confirm the Xcode target, then decide how tests should start.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var repositoryStep: some View {
        onboardingCard(index: "1", title: "Choose Repository") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Repository path", text: $repositoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        selectRepositoryPath()
                    }
                }
                Text("Tests clones this repository into a disposable workspace before each run.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var xcodeStep: some View {
        onboardingCard(index: "2", title: "Confirm Xcode Project") {
            VStack(alignment: .leading, spacing: 12) {
                EditableComboBox(
                    placeholder: "Workspace name",
                    text: $workspaceName,
                    options: workspaceOptions
                )
                EditableComboBox(
                    placeholder: "Scheme name",
                    text: $xcodeSchemeName,
                    options: schemeOptions
                )
                EditableComboBox(
                    placeholder: "Default branch",
                    text: $branchName,
                    options: branchOptions
                )
                Text("These are autodetected from the repository and can be edited when the project has multiple plausible choices.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var automationStep: some View {
        onboardingCard(index: "3", title: "Enable Automation") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Install the bundled git post-commit hook to trigger tests automatically after commits on this repository.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Install Post-Hook Script") {
                        installPostHook()
                    }
                    .disabled(!postHookState.canInstall)

                    Text(postHookMessage)
                        .font(.system(size: 12))
                        .foregroundColor(postHookState.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var advancedStep: some View {
        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Pre-build shell script", text: $preBuildScript)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                TextField("Ignored automatic branch prefixes", text: $ignoredAutomaticBranchPrefixes)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Toggle("Enable parallel testing", isOn: $parallelTestingEnabled)
                    .toggleStyle(.switch)
                Stepper("Build jobs: \(parallelBuildJobCount)", value: $parallelBuildJobCount, in: 1...32)
            }
            .padding(.top, 10)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var firstRunStep: some View {
        onboardingCard(index: "4", title: "Run First Test") {
            Text("When setup looks right, start a manual run to confirm the disposable workspace, branch checkout, and Xcode scheme all work together.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Skip for Now") {
                onSkip()
            }
            Spacer()
            Button("Save Setup") {
                saveSettings()
                onFinish(false)
            }
            .disabled(!canFinish)
            Button("Run Tests Now") {
                saveSettings()
                onFinish(true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canFinish)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func onboardingCard<Content: View>(
        index: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(index)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func loadSettings() {
        repositoryPath = settings.repositoryPath
        workspaceName = settings.workspaceName
        xcodeSchemeName = settings.xcodeSchemeName
        branchName = settings.branchName ?? ""
        ignoredAutomaticBranchPrefixes = settings.ignoredAutomaticBranchPrefixes
        parallelTestingEnabled = settings.parallelTestingEnabled
        parallelBuildJobCount = settings.parallelBuildJobCount
        preBuildScript = settings.preBuildScript
    }

    private func selectRepositoryPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Select Repository Directory"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.path
    }

    private func discoverProjectSettingsIfPossible(force: Bool = false) {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            workspaceOptions = []
            schemeOptions = []
            return
        }

        let repositoryURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        workspaceOptions = WorkspaceFinder.findWorkspaceNames(in: repositoryURL)

        let inferredWorkspaceName = WorkspaceFinder.findWorkspace(
            in: repositoryURL,
            preferredName: workspaceName
        )?.lastPathComponent ?? ""
        if force || workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workspaceName = inferredWorkspaceName
        }

        let schemeWorkspaceName = workspaceName.isEmpty ? inferredWorkspaceName : workspaceName
        schemeOptions = WorkspaceFinder.findSchemeNames(in: repositoryURL, preferredWorkspaceName: schemeWorkspaceName)
        let inferredSchemeName = schemeOptions.first ?? ""
        if force || shouldReplaceInferredSchemeName(xcodeSchemeName, with: inferredSchemeName) {
            xcodeSchemeName = inferredSchemeName
        }
    }

    private func refreshSchemeOptions() {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            schemeOptions = []
            return
        }

        let repositoryURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        schemeOptions = WorkspaceFinder.findSchemeNames(
            in: repositoryURL,
            preferredWorkspaceName: workspaceName
        )
    }

    private func refreshBranchOptions(force: Bool = false) {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            branchOptions = []
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let repositoryURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
            let options = GitBranchFinder.findBranchNames(in: repositoryURL)
            let defaultBranchName = GitBranchFinder.findDefaultBranchName(
                in: repositoryURL,
                branchNames: options
            )

            DispatchQueue.main.async {
                guard repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPath else { return }
                branchOptions = options
                if force || branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    branchName = defaultBranchName ?? ""
                }
            }
        }
    }

    private func refreshPostHookState() {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            postHookState = .missingRepository
            postHookMessage = PostHookInstaller.State.missingRepository.message
            return
        }

        let state = PostHookInstaller.state(for: URL(fileURLWithPath: trimmedPath, isDirectory: true))
        postHookState = state
        postHookMessage = state.message
    }

    private func installPostHook() {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            refreshPostHookState()
            return
        }

        do {
            try PostHookInstaller.install(in: URL(fileURLWithPath: trimmedPath, isDirectory: true))
            postHookState = .installed
            postHookMessage = PostHookInstaller.State.installed.message
        } catch {
            postHookState = .installFailed(error.localizedDescription)
            postHookMessage = error.localizedDescription
        }
    }

    private func shouldReplaceInferredSchemeName(_ schemeName: String, with inferredSchemeName: String) -> Bool {
        let lowercasedSchemeName = schemeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowercasedInferredSchemeName = inferredSchemeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if WorkspaceFinder.isTestSchemeName(lowercasedInferredSchemeName),
           !WorkspaceFinder.isTestSchemeName(lowercasedSchemeName) {
            return true
        }

        return lowercasedSchemeName.isEmpty ||
        [
            "all",
            "aggregate",
            "build all",
            "everything"
        ].contains(lowercasedSchemeName)
    }

    private func saveSettings() {
        settings.setRepositoryPath(repositoryPath)
        settings.setWorkspaceName(workspaceName)
        settings.setXcodeSchemeName(xcodeSchemeName)
        settings.setBranchName(branchName.isEmpty ? nil : branchName)
        settings.setIgnoredAutomaticBranchPrefixes(ignoredAutomaticBranchPrefixes)
        settings.setParallelTestingEnabled(parallelTestingEnabled)
        settings.setParallelBuildJobCount(parallelBuildJobCount)
        settings.setPreBuildScript(preBuildScript)
    }
}
