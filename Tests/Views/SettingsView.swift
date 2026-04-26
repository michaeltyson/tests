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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                settingsCard(
                    title: "Repository",
                    description: "Choose the Git repository to clone into the disposable test workspace."
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

                        postHookInstaller
                    }
                }

                settingsCard(
                    title: "Xcode Project",
                    description: "Workspace and scheme are inferred from the repository. You can override them when needed."
                ) {
                    VStack(spacing: 12) {
                        EditableComboBox(
                            placeholder: "Workspace name, optional",
                            text: $workspaceName,
                            options: workspaceOptions
                        )
                        EditableComboBox(
                            placeholder: "Scheme name",
                            text: $xcodeSchemeName,
                            options: schemeOptions
                        )
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    settingsCard(
                        title: "Default Branch",
                        description: "Used for manual runs when you do not explicitly choose a branch."
                    ) {
                        EditableComboBox(
                            placeholder: "Branch name",
                            text: $branchName,
                            options: branchOptions
                        )
                    }

                    settingsCard(
                        title: "Test Parallelization",
                        description: "Let xcodebuild execute tests and targets in parallel when supported."
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Enable parallel testing", isOn: $parallelTestingEnabled)
                                .toggleStyle(.switch)
                            Stepper("Build jobs: \(parallelBuildJobCount)", value: $parallelBuildJobCount, in: 1...32)
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
                    title: "Automation",
                    description: "Comma-separated branch prefixes are ignored for incoming post-hook triggers. Manual runs are still allowed."
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
                Text("Workspace, branch, and build execution defaults.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var postHookInstaller: some View {
        VStack(alignment: .leading, spacing: 8) {
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

enum PostHookInstaller {
    enum State: Equatable {
        case unknown
        case missingRepository
        case missingGitRepository
        case missingBundledHook
        case notInstalled
        case installed
        case installFailed(String)

        var canInstall: Bool {
            self == .notInstalled
        }

        var isError: Bool {
            switch self {
            case .missingGitRepository, .missingBundledHook, .installFailed:
                return true
            case .unknown, .missingRepository, .notInstalled, .installed:
                return false
            }
        }

        var message: String {
            switch self {
            case .unknown:
                return "Checking post-commit hook status..."
            case .missingRepository:
                return "Select a repository to install automatic test triggers."
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled post-commit hook script was not found."
            case .notInstalled:
                return "Not installed."
            case .installed:
                return "Installed already."
            case let .installFailed(message):
                return message
            }
        }
    }

    enum InstallError: LocalizedError {
        case missingGitRepository
        case missingBundledHook
        case hookAlreadyExists
        case couldNotResolveHookPath(String)

        var errorDescription: String? {
            switch self {
            case .missingGitRepository:
                return "No Git repository found at this path."
            case .missingBundledHook:
                return "Bundled post-commit hook script was not found."
            case .hookAlreadyExists:
                return "Installed already."
            case let .couldNotResolveHookPath(message):
                return message
            }
        }
    }

    static func state(for repositoryURL: URL) -> State {
        guard let hookURL = postCommitHookURL(in: repositoryURL) else {
            return .missingGitRepository
        }

        guard bundledPostCommitHookURL() != nil else {
            return .missingBundledHook
        }

        return FileManager.default.fileExists(atPath: hookURL.path) ? .installed : .notInstalled
    }

    static func install(in repositoryURL: URL) throws {
        guard let sourceURL = bundledPostCommitHookURL() else {
            throw InstallError.missingBundledHook
        }

        guard let hookURL = postCommitHookURL(in: repositoryURL) else {
            throw InstallError.missingGitRepository
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: hookURL.path) else {
            throw InstallError.hookAlreadyExists
        }

        try fileManager.createDirectory(
            at: hookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: hookURL,
            withDestinationURL: sourceURL
        )
    }

    private static func bundledPostCommitHookURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "post-commit", withExtension: nil) {
            return bundleURL
        }

        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/post-commit")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    private static func postCommitHookURL(in repositoryURL: URL) -> URL? {
        let result = runGitCommand(
            ["rev-parse", "--git-path", "hooks/post-commit"],
            in: repositoryURL
        )
        guard result.success else { return nil }

        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return repositoryURL.appendingPathComponent(path)
    }

    private static func runGitCommand(_ arguments: [String], in repositoryURL: URL) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
