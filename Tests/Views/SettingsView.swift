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
    @State private var postHookState: PostHookInstaller.State = .unknown
    @State private var postHookMessage: String = ""
    @State private var advancedExpanded = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                numberedSettingsCard(
                    index: "1",
                    title: "Choose Repository"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            TextField("Repository path", text: $repositoryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                selectRepositoryPath()
                            }
                            .controlSize(.large)
                        }

                        Text("Tests clones this repository into a disposable workspace before each run.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        postHookInstaller
                    }
                }

                numberedSettingsCard(
                    index: "2",
                    title: "Confirm Xcode Project"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledComboBox(
                            title: "Workspace",
                            description: "The Xcode workspace or project file used for the test build.",
                            placeholder: "Workspace name",
                            text: $workspaceName,
                            options: workspaceOptions
                        )
                        labeledComboBox(
                            title: "Scheme",
                            description: "The scheme whose tests should run by default.",
                            placeholder: "Scheme name",
                            text: $xcodeSchemeName,
                            options: schemeOptions
                        )
                        labeledComboBox(
                            title: "Default Branch",
                            description: "The branch used for manual runs when no branch or commit is selected.",
                            placeholder: "Default branch",
                            text: $branchName,
                            options: branchOptions
                        )
                        Text("These are autodetected from the repository and can be edited when the project has multiple plausible choices.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                numberedSettingsCard(
                    index: "3",
                    title: "Tune Automation"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Comma-separated branch prefixes are ignored for incoming automatic hook triggers. Manual runs are still allowed.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("codex/, spike/, wip/", text: $ignoredAutomaticBranchPrefixes)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            advancedExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                            Text("Advanced Build Options")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if advancedExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        advancedTextFieldRow(
                            title: "Pre-Build Script",
                            description: "Optional shell command to run in the prepared workspace before the build starts. A non-zero exit code cancels the run.",
                            placeholder: "Shell command",
                            text: $preBuildScript
                        )

                        Divider()

                        advancedControlRow(
                            title: "Parallel Testing",
                            description: "Allow xcodebuild to execute tests and targets in parallel when supported."
                        ) {
                            Toggle("", isOn: $parallelTestingEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        Divider()

                        advancedControlRow(
                            title: "Build Jobs",
                            description: "Maximum number of concurrent build jobs passed to xcodebuild.",
                            isEnabled: parallelTestingEnabled
                        ) {
                            Stepper(
                                value: $parallelBuildJobCount,
                                in: 1...32
                            ) {
                                Text("\(parallelBuildJobCount)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit()
                                    .frame(minWidth: 22, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 14)
                    }
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
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            repositoryPath = settings.repositoryPath
            workspaceName = settings.workspaceName
            xcodeSchemeName = settings.xcodeSchemeName
            branchName = settings.branchName ?? ""
            ignoredAutomaticBranchPrefixes = settings.ignoredAutomaticBranchPrefixes
            parallelTestingEnabled = settings.parallelTestingEnabled
            parallelBuildJobCount = settings.parallelBuildJobCount
            preBuildScript = settings.preBuildScript
            inferProjectSettingsIfPossible()
            refreshBranchOptions()
            refreshPostHookState()
        }
        .onChange(of: repositoryPath) { _, _ in
            inferProjectSettingsIfPossible()
            refreshBranchOptions()
            refreshPostHookState()
        }
        .onChange(of: workspaceName) { _, _ in
            refreshSchemeOptions()
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
                inferProjectSettingsIfPossible(force: true)
                refreshBranchOptions(force: true)
                refreshPostHookState()
            }
        }
    }

    private func inferProjectSettingsIfPossible(force: Bool = false) {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

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
            postHookMessage = "Select a repository to install automatic test triggers."
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

    private func wrapExistingPostHook() {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            refreshPostHookState()
            return
        }

        do {
            try PostHookInstaller.wrapExistingHook(in: URL(fileURLWithPath: trimmedPath, isDirectory: true))
            postHookState = .installed
            postHookMessage = PostHookInstaller.State.installed.message
        } catch {
            postHookState = .installFailed(error.localizedDescription)
            postHookMessage = error.localizedDescription
        }
    }

    private func uninstallPostHook() {
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            refreshPostHookState()
            return
        }

        do {
            try PostHookInstaller.uninstall(in: URL(fileURLWithPath: trimmedPath, isDirectory: true))
            refreshPostHookState()
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Test Runner Settings")
                    .font(.system(size: 28, weight: .semibold))
                Text("Choose a repository, confirm the discovered Xcode project, then tune how tests start.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var postHookInstaller: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install the bundled git hooks to trigger tests automatically after commits and merges on this repository.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if postHookState.canUninstall {
                    Button("Uninstall") {
                        uninstallPostHook()
                    }
                    .buttonStyle(SettingsSubtleActionButtonStyle())
                } else if postHookState.canWrap {
                    Button("Wrap Existing Hooks") {
                        wrapExistingPostHook()
                    }
                    .buttonStyle(SettingsSubtleActionButtonStyle())
                } else {
                    Button("Install Auto-Trigger Hooks") {
                        installPostHook()
                    }
                    .buttonStyle(SettingsSubtleActionButtonStyle())
                    .disabled(!postHookState.canInstall)
                }

                Text(postHookMessage)
                    .font(.system(size: 12))
                    .foregroundColor(postHookState.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledComboBox(
        title: String,
        description: String,
        placeholder: String,
        text: Binding<String>,
        options: [String]
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingsRowLabel(title: title, description: description)
                .frame(width: 190, alignment: .leading)
            EditableComboBox(
                placeholder: placeholder,
                text: text,
                options: options
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func advancedTextFieldRow(
        title: String,
        description: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsRowLabel(title: title, description: description)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func advancedControlRow<Control: View>(
        title: String,
        description: String,
        isEnabled: Bool = true,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            settingsRowLabel(title: title, description: description)
                .opacity(isEnabled ? 1 : 0.45)
            Spacer(minLength: 16)
            control()
                .controlSize(.regular)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }

    private func settingsRowLabel(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numberedSettingsCard<Content: View>(
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
}

private struct SettingsSubtleActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSubtleActionButton(configuration: configuration)
    }

    private struct SettingsSubtleActionButton: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(configuration.isPressed ? 0.78 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                }
        }

        private var foregroundColor: Color {
            if !isEnabled {
                return .secondary.opacity(0.65)
            }
            return isHovered ? .accentColor : .primary
        }

        private var backgroundColor: Color {
            if !isEnabled {
                return Color.secondary.opacity(0.05)
            }
            if configuration.isPressed {
                return Color.accentColor.opacity(0.24)
            }
            if isHovered {
                return Color.accentColor.opacity(0.14)
            }
            return Color.accentColor.opacity(0.08)
        }

        private var borderColor: Color {
            if !isEnabled {
                return Color.secondary.opacity(0.08)
            }
            return isHovered ? Color.accentColor.opacity(0.38) : Color.accentColor.opacity(0.22)
        }
    }
}

struct EditableComboBox: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let options: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> CompletingComboBox {
        let comboBox = CompletingComboBox()
        comboBox.delegate = context.coordinator
        comboBox.usesDataSource = false
        comboBox.completes = true
        comboBox.isEditable = true
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 12
        comboBox.placeholderString = placeholder
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.comboBoxAction(_:))
        comboBox.translatesAutoresizingMaskIntoConstraints = false
        comboBox.heightAnchor.constraint(equalToConstant: 24).isActive = true
        context.coordinator.comboBox = comboBox
        return comboBox
    }

    func updateNSView(_ comboBox: CompletingComboBox, context: Context) {
        context.coordinator.text = $text
        comboBox.completionOptions = options

        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }

        let currentItems = (0..<comboBox.numberOfItems).compactMap { comboBox.itemObjectValue(at: $0) as? String }
        if currentItems != options {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: options)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        weak var comboBox: CompletingComboBox?

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func comboBoxAction(_ sender: NSComboBox) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text.wrappedValue = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text.wrappedValue = comboBox.stringValue
        }
    }
}

final class CompletingComboBox: NSComboBox {
    var completionOptions: [String] = []

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\t",
           completeCurrentText() {
            return
        }

        super.keyDown(with: event)
    }

    private func completeCurrentText() -> Bool {
        let currentText = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else { return false }

        guard let completion = completionOptions.first(where: {
            $0.localizedCaseInsensitiveContains(currentText)
        }) else {
            return false
        }

        stringValue = completion
        sendAction(action, to: target)
        currentEditor()?.selectedRange = NSRange(location: completion.count, length: 0)
        return true
    }
}
