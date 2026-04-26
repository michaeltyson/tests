//
//  TestHistoryView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit

private enum TestHistorySidebarTab: String, CaseIterable {
    case runs = "Runs"
    case graph = "Graph"
}

struct TestHistoryView: View {
    @ObservedObject var testResultStore: TestResultStore
    @ObservedObject var testRunner: TestRunner
    @State private var selectedTestRun: TestRun?
    @State private var selectedCommit: GitCommitNode?
    @AppStorage("TestHistorySelectedSidebarTab") private var selectedSidebarTabRawValue = TestHistorySidebarTab.runs.rawValue
    @State private var runningPlaceholderTestRun: TestRun?
    @State private var runTestsInModifierActive = false
    @State private var localModifierMonitor: Any?
    @State private var globalModifierMonitor: Any?
    @State private var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "TestHistorySidebarWidth")
        return saved > 0 ? saved : 280
    }()
    
    private var sidebarTestRuns: [TestRun] {
        var runs = testResultStore.testRuns
        
        if testRunner.isRunning, let currentTestRun = testRunner.currentTestRun {
            runs.removeAll { $0.id == currentTestRun.id }
            runs.insert(currentTestRun, at: 0)
        } else if testRunner.isRunning, let placeholder = runningPlaceholderTestRun {
            runs.insert(placeholder, at: 0)
        }
        
        return runs
    }

    private var selectedSidebarTab: TestHistorySidebarTab {
        TestHistorySidebarTab(rawValue: selectedSidebarTabRawValue) ?? .runs
    }

    private var selectedSidebarTabBinding: Binding<TestHistorySidebarTab> {
        Binding(
            get: { selectedSidebarTab },
            set: { selectedSidebarTabRawValue = $0.rawValue }
        )
    }
    
    var body: some View {
        HSplitView {
            // List view with translucent background
            sidebar
            .frame(minWidth: 250, maxWidth: 600)
            .background(.thinMaterial)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SidebarWidthPreferenceKey.self, value: geometry.size.width)
            })
            .onPreferenceChange(SidebarWidthPreferenceKey.self) { newWidth in
                // Only update if the change is significant and within bounds
                if abs(newWidth - sidebarWidth) > 1.0 && newWidth >= 250 && newWidth <= 600 {
                    sidebarWidth = newWidth
                    UserDefaults.standard.set(newWidth, forKey: "TestHistorySidebarWidth")
                }
            }
            
            // Detail view
            VStack(spacing: 0) {
                // Integrated title bar with action buttons
                HStack(alignment: .center, spacing: 20) {
                    if testRunner.isRunning {
                        // Status indicator
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                testRunner.isBuilding
                                    ? (testRunner.queuedRunCount > 0 ? "Building... (\(testRunner.queuedRunCount) queued)" : "Building...")
                                    : (testRunner.queuedRunCount > 0 ? "Running tests... (\(testRunner.queuedRunCount) queued)" : "Running tests...")
                            )
                                .font(.system(size: 15, weight: .medium))
                        }
                        
                        // Test counts badge
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 11))
                                Text("\(testRunner.passingCount)")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            
                            if testRunner.failingCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.system(size: 11))
                                    Text("\(testRunner.failingCount)")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            
                            if testRunner.totalCount > 0 {
                                Text("of \(testRunner.totalCount)")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                        .cornerRadius(6)
                        
                        // Progress bar - expands to fill space
                        if testRunner.totalCount > 0 {
                            let progress = Double(testRunner.passingCount + testRunner.failingCount) / Double(testRunner.totalCount)
                            
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                        
                        Button(action: {
                            NotificationCenter.default.post(name: NSNotification.Name("CancelTests"), object: nil)
                        }) {
                            Text("Cancel")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Text("Test Reports")
                            .font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Button(action: runTestsFromReports) {
                            Text(runTestsInModifierActive ? "Run Tests In..." : "Run Tests")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .frame(height: 50)
                .padding(.horizontal, 20)
                .padding(.top, -30) // Negative padding to pull content up into title bar
                .background(.regularMaterial)
                
                Divider()
                
                // Content - show live output only if selected test is the current running test
                if testRunner.isRunning,
                   let currentTestRun = testRunner.currentTestRun,
                   selectedTestRun?.id == currentTestRun.id {
                    // Show live output for the currently running test (only if it's selected)
                    VStack(alignment: .leading, spacing: 0) {
                        TerminalOutputView(text: testRunner.output, followsTail: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .modifier(OutputPaneModifier())
                    }
                } else if let selectedTestRun = selectedTestRun {
                    // Show selected test detail (can be any test run, even while another is running)
                    let latestTestRun = testResultStore.testRuns.first(where: { $0.id == selectedTestRun.id }) ?? selectedTestRun
                    TestDetailView(testRun: latestTestRun)
                        .id("\(latestTestRun.id)-\(latestTestRun.outputLog?.count ?? 0)")
                } else if let selectedCommit = selectedCommit {
                    UntestedCommitDetailView(
                        commit: selectedCommit,
                        isRunning: testRunner.isRunning,
                        onRunTests: {
                            runTests(for: selectedCommit)
                        }
                    )
                } else {
                    VStack {
                        Text(selectedSidebarTab == .graph ? "Select a commit to view details" : "Select a test run to view details")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .ignoresSafeArea(.all, edges: .top)
        .background(SplitViewDividerController(sidebarWidth: $sidebarWidth))
        .onAppear {
            // Backup approach: set divider position when view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let window = NSApp.windows.first(where: { $0.title == "Test Reports" }),
                   let contentView = window.contentView {
                    if let splitView = findNSSplitView(in: contentView) {
                        let savedWidth = UserDefaults.standard.double(forKey: "TestHistorySidebarWidth")
                        let width = savedWidth > 0 ? savedWidth : 280
                        let currentPosition = splitView.arrangedSubviews.first?.frame.width ?? 0
                        if abs(currentPosition - width) > 1.0 {
                            splitView.setPosition(width, ofDividerAt: 0)
                        }
                    }
                }
            }

            updateRunTestsModifierState()
            startModifierKeyMonitoring()
        }
        .onChange(of: testRunner.currentTestRun) { _, newTestRun in
            // Auto-select the running test only if nothing is currently selected
            if let newTestRun = newTestRun, selectedTestRun == nil {
                runningPlaceholderTestRun = nil
                selectedTestRun = newTestRun
            } else if newTestRun == nil {
                if testRunner.isRunning {
                    if runningPlaceholderTestRun == nil {
                        runningPlaceholderTestRun = TestRun(status: .running)
                    }
                    if selectedTestRun == nil, let placeholder = runningPlaceholderTestRun {
                        selectedTestRun = placeholder
                    }
                    return
                }
                
                // Test run cleared (e.g., cancelled) - deselect if it was the selected one
                if selectedTestRun?.id == testRunner.currentTestRun?.id {
                    selectedTestRun = nil
                }
            }
        }
        .onChange(of: testRunner.isRunning) { _, isRunning in
            if isRunning && testRunner.currentTestRun == nil {
                runningPlaceholderTestRun = TestRun(status: .running)
                if selectedTestRun == nil, let placeholder = runningPlaceholderTestRun {
                    selectedTestRun = placeholder
                }
            }
            
            // When test stops running (including cancellation), clear selection if it was the current run
            if !isRunning {
                runningPlaceholderTestRun = nil
                if testRunner.currentTestRun == nil {
                    // Test was cancelled - clear selection if it was the cancelled test
                    selectedTestRun = nil
                }
            }
        }
        .onAppear {
            // Auto-select running test when view appears
            if let currentTestRun = testRunner.currentTestRun {
                selectedTestRun = currentTestRun
            }
        }
        .onDisappear {
            stopModifierKeyMonitoring()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: selectedSidebarTabBinding) {
                ForEach(TestHistorySidebarTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            switch selectedSidebarTab {
            case .runs:
                runsSidebar
            case .graph:
                TestGraphSidebarView(
                    testResultStore: testResultStore,
                    testRunner: testRunner,
                    selectedCommit: $selectedCommit,
                    selectedTestRun: $selectedTestRun
                )
            }
        }
    }

    private var runsSidebar: some View {
        VStack(spacing: 0) {
            List(sidebarTestRuns, selection: $selectedTestRun) { testRun in
                TestRunRow(
                    testRun: testRun,
                    isCurrentRun: testRunner.currentTestRun?.id == testRun.id,
                    onDelete: {
                        deleteTestRun(testRun)
                    }
                )
                .tag(testRun)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.thinMaterial)
            .onChange(of: selectedTestRun) { _, newValue in
                if newValue != nil {
                    selectedCommit = nil
                }
            }

            Divider()

            HStack {
                Button(action: clearHistory) {
                    Text("Clear All")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding()
            .background(.thinMaterial)
        }
    }
    
    private func deleteTestRun(_ testRun: TestRun) {
        if testRunner.isRunning,
           testRunner.currentTestRun?.id == testRun.id || runningPlaceholderTestRun?.id == testRun.id {
            NotificationCenter.default.post(name: NSNotification.Name("CancelTests"), object: nil)
            return
        }
        
        testResultStore.delete(testRun)
        if selectedTestRun?.id == testRun.id {
            selectedTestRun = nil
        }
    }
    
    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Test Reports"
        alert.informativeText = "Are you sure you want to delete all test runs? This action cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear All")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertSecondButtonReturn {
            testResultStore.clearAll()
            selectedTestRun = nil
            selectedCommit = nil
        }
    }
    
    private func findNSSplitView(in view: NSView?) -> NSSplitView? {
        guard let view = view else { return nil }
        if let splitView = view as? NSSplitView {
            return splitView
        }
        for subview in view.subviews {
            if let splitView = findNSSplitView(in: subview) {
                return splitView
            }
        }
        return nil
    }

    private func runTestsFromReports() {
        if shouldShowBranchSelection(for: NSApp.currentEvent?.modifierFlags ?? []) {
            NotificationCenter.default.post(name: NSNotification.Name("ShowBranchSelection"), object: nil)
        } else {
            NotificationCenter.default.post(name: NSNotification.Name("RunTests"), object: nil)
        }
    }

    private func runTests(for commit: GitCommitNode) {
        testRunner.runTests(branchName: commit.sha, isManualRun: true)
    }

    private func updateRunTestsModifierState(with modifierFlags: NSEvent.ModifierFlags? = nil) {
        let flags = modifierFlags ?? NSApp.currentEvent?.modifierFlags ?? []
        let nextValue = shouldShowBranchSelection(for: flags)
        if runTestsInModifierActive != nextValue {
            runTestsInModifierActive = nextValue
        }
    }

    private func shouldShowBranchSelection(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.option) || modifierFlags.contains(.command)
    }

    private func startModifierKeyMonitoring() {
        guard localModifierMonitor == nil, globalModifierMonitor == nil else { return }

        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            updateRunTestsModifierState(with: event.modifierFlags)
            return event
        }

        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            updateRunTestsModifierState(with: event.modifierFlags)
        }
    }

    private func stopModifierKeyMonitoring() {
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
            self.localModifierMonitor = nil
        }

        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
            self.globalModifierMonitor = nil
        }

        runTestsInModifierActive = false
    }
}

private struct UntestedCommitDetailView: View {
    let commit: GitCommitNode
    let isRunning: Bool
    let onRunTests: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text("No tests recorded")
                        .font(.system(size: 18, weight: .semibold))

                    Spacer()
                }

                Text(commit.subject)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(3)

                HStack(spacing: 12) {
                    Text("Commit: \(commit.sha)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    if let authorDate = commit.authorDate {
                        Text(authorDate.formatted(date: .complete, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !commit.branchNames.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(commit.branchNames, id: \.self) { branchName in
                            Text(branchName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(spacing: 8) {
                Spacer()
                Text("This commit has not been matched with a saved test run.")
                    .foregroundColor(.secondary)
                Text("Run tests for this commit or branch to populate its result in the project graph.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: onRunTests) {
                    Text(isRunning ? "Queue Tests" : "Run Tests")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TestRunRow: View {
    let testRun: TestRun
    let isCurrentRun: Bool
    let onDelete: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(testRun.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    
                    if let branchName = testRun.branchName {
                        Text(branchName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                // Test counts
                if let passingCount = testRun.passingCount, let failingCount = testRun.failingCount {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption2)
                            Text("\(passingCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if failingCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption2)
                                Text("\(failingCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let totalCount = testRun.totalCount {
                            Text("of \(totalCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let duration = testRun.duration {
                    Text("Duration: \(formatDuration(duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let errorDescription = testRun.errorDescription {
                    Text(errorDescription)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete test run")
            }
        }
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private var statusIcon: some View {
        Group {
            if testRun.status == .running && isCurrentRun {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
            }
        }
    }
    
    private var iconName: String {
        switch testRun.status {
        case .success:
            return "checkmark.circle.fill"
        case .failed, .error:
            return "xmark.circle.fill"
        case .warnings:
            return "exclamationmark.triangle.fill"
        case .running:
            return "flask.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch testRun.status {
        case .success:
            return .green
        case .failed, .error:
            return .red
        case .warnings:
            return .yellow
        case .running:
            return .blue
        case .paused:
            return .orange
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

// Preference key to track sidebar width changes
struct SidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Helper view to programmatically set split view divider position
struct SplitViewDividerController: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Use multiple attempts with delays to find the split view
        // The view hierarchy might not be ready immediately
        context.coordinator.setupObserver(nsView: nsView, sidebarWidth: $sidebarWidth)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var observer: NSObjectProtocol?
        var hasSetInitialPosition = false
        
        func setupObserver(nsView: NSView, sidebarWidth: Binding<CGFloat>) {
            // Try multiple times with increasing delays
            let attempts = [0.0, 0.1, 0.3, 0.5]
            for delay in attempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // Search from superview (the background view is a child of the split view's container)
                    let splitView = self.findSplitView(in: nsView.superview)
                    
                    if let splitView = splitView {
                        // Set autosave name for automatic persistence
                        if splitView.autosaveName == nil || splitView.autosaveName!.isEmpty {
                            splitView.autosaveName = "TestHistorySidebar"
                        }
                        
                        // Set initial position only once
                        if !self.hasSetInitialPosition {
                            let currentPosition = splitView.arrangedSubviews.first?.frame.width ?? 0
                            if abs(currentPosition - sidebarWidth.wrappedValue) > 1.0 {
                                splitView.setPosition(sidebarWidth.wrappedValue, ofDividerAt: 0)
                            }
                            self.hasSetInitialPosition = true
                        }
                        
                        // Observe frame changes to track divider movement
                        if self.observer == nil {
                            self.observer = NotificationCenter.default.addObserver(
                                forName: NSView.frameDidChangeNotification,
                                object: splitView,
                                queue: .main
                            ) { [weak splitView] _ in
                                guard let splitView = splitView else { return }
                                if splitView.arrangedSubviews.count > 0 {
                                    let newWidth = splitView.arrangedSubviews[0].frame.width
                                    if abs(newWidth - sidebarWidth.wrappedValue) > 1.0 && newWidth >= 250 && newWidth <= 600 {
                                        sidebarWidth.wrappedValue = newWidth
                                        UserDefaults.standard.set(newWidth, forKey: "TestHistorySidebarWidth")
                                    }
                                }
                            }
                        }
                        return // Found it, stop trying
                    }
                }
            }
        }
        
        deinit {
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        private func findSplitView(in view: NSView?, depth: Int = 0) -> NSSplitView? {
            // Prevent infinite recursion with depth limit
            guard depth < 20, let view = view else { return nil }
            
            // Check if this view is a split view
            if let splitView = view as? NSSplitView {
                return splitView
            }
            
            // Check all subviews recursively
            for subview in view.subviews {
                if let splitView = findSplitView(in: subview, depth: depth + 1) {
                    return splitView
                }
            }
            
            return nil
        }
    }
}
