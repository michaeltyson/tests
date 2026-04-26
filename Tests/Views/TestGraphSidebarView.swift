//
//  TestGraphSidebarView.swift
//  Tests
//

import SwiftUI
import AppKit

struct TestGraphSidebarView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var testResultStore: TestResultStore
    @ObservedObject var testRunner: TestRunner
    let branchFilterText: String
    @Binding var selectedCommit: GitCommitNode?
    @Binding var selectedTestRun: TestRun?

    @State private var commits: [GitCommitNode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadGeneration = UUID()

    private let historyService = GitHistoryService()

    private var branchFilterQuery: String {
        branchFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFilteringBranches: Bool {
        !branchFilterQuery.isEmpty
    }

    private var matchingCommits: [GitCommitNode] {
        guard isFilteringBranches else { return commits }

        return commits.filter { commit in
            commit.branchNames.contains { branchName in
                branchName.localizedCaseInsensitiveContains(branchFilterQuery)
            } || commit.testRun?.branchName?.localizedCaseInsensitiveContains(branchFilterQuery) == true
        }
    }

    private var displayedCommits: [GitCommitNode] {
        guard isFilteringBranches else { return commits }
        return Self.relayoutCommitsForVisibleRows(matchingCommits)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Project History")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: loadHistory) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh commit history")
                .disabled(isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            content
        }
        .onAppear(perform: loadHistory)
        .onChange(of: settings.repositoryPath) { _, _ in loadHistory() }
        .onChange(of: testResultStore.testRuns) { _, _ in loadHistory() }
        .onChange(of: testRunner.currentTestRun) { _, _ in loadHistory() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && commits.isEmpty {
            VStack {
                Spacer()
                ProgressView("Loading history...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, commits.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedCommits.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No branches match this filter.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(displayedCommits) { commit in
                            TestGraphCommitRow(
                                commit: commit,
                                isSelected: selectedCommit?.id == commit.id
                            )
                            .frame(width: geometry.size.width, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedCommit = commit
                                selectedTestRun = commit.testRun
                            }
                        }
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                }
                .background(.thinMaterial)
            }
        }
    }

    private static func relayoutCommitsForVisibleRows(_ commits: [GitCommitNode]) -> [GitCommitNode] {
        commits.enumerated().map { index, commit in
            return GitCommitNode(
                sha: commit.sha,
                shortSHA: commit.shortSHA,
                subject: commit.subject,
                authorDate: commit.authorDate,
                parentSHAs: commit.parentSHAs,
                branchNames: commit.branchNames,
                laneIndex: 0,
                laneCount: 1,
                topLanes: index == 0 ? [] : [0],
                bottomLanes: index == commits.indices.last ? [] : [0],
                topConnections: [],
                bottomConnections: [],
                testRun: commit.testRun
            )
        }
    }

    private func loadHistory() {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true

        let repositoryPath = settings.repositoryPath
        let fallbackBranchName = settings.branchName
        let testRuns = testResultStore.testRuns
        let currentTestRun = testRunner.currentTestRun

        DispatchQueue.global(qos: .userInitiated).async {
            let result = historyService.loadHistory(
                repositoryPath: repositoryPath,
                testRuns: testRuns,
                currentTestRun: currentTestRun,
                fallbackBranchName: fallbackBranchName
            )

            DispatchQueue.main.async {
                guard loadGeneration == generation else { return }
                commits = result.commits
                errorMessage = result.errorMessage
                isLoading = false

                if let selectedCommit,
                   let updatedCommit = result.commits.first(where: { $0.id == selectedCommit.id }) {
                    self.selectedCommit = updatedCommit
                    self.selectedTestRun = updatedCommit.testRun
                }
            }
        }
    }
}

private struct TestGraphCommitRow: View {
    let commit: GitCommitNode
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            CommitGraphGlyphView(
                status: commit.testStatus,
                laneIndex: commit.laneIndex,
                laneCount: commit.laneCount,
                topLanes: commit.topLanes,
                bottomLanes: commit.bottomLanes,
                topConnections: commit.topConnections,
                bottomConnections: commit.bottomConnections
            )
            .frame(width: graphWidth, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ForEach(commit.branchNames.prefix(2), id: \.self) { branchName in
                        Text(branchName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .cornerRadius(4)
                            .help(branchName)
                    }

                    Text(commit.subject)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if let date = commit.authorDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("•")
                    }

                    Text(commit.shortSHA)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
        .clipped()
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, graphWidth + 3)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.22)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private var graphWidth: CGFloat {
        let visibleLanes = commit.topLanes
            .union(commit.bottomLanes)
            .union([commit.laneIndex])
            .union(commit.topConnections.flatMap { [$0.fromLane, $0.toLane] })
            .union(commit.bottomConnections.flatMap { [$0.fromLane, $0.toLane] })
        let rightmostLane = visibleLanes.max() ?? commit.laneIndex
        return GitGraphLayout.xPosition(for: rightmostLane) + GitGraphLayout.trailingPadding
    }
}

private enum GitGraphLayout {
    static let laneSpacing: CGFloat = 11
    static let nodeDiameter: CGFloat = 13
    static let lineWidth: CGFloat = 2
    static let leadingPadding: CGFloat = 8
    static let trailingPadding: CGFloat = 9

    static func xPosition(for lane: Int) -> CGFloat {
        CGFloat(lane) * laneSpacing + leadingPadding
    }
}

struct CommitGraphGlyphView: View {
    let status: CommitTestStatus
    let laneIndex: Int
    let laneCount: Int
    let topLanes: Set<Int>
    let bottomLanes: Set<Int>
    let topConnections: [GitGraphLaneConnection]
    let bottomConnections: [GitGraphLaneConnection]

    private let nodeDiameter = GitGraphLayout.nodeDiameter
    private let lineWidth = GitGraphLayout.lineWidth

    var body: some View {
        ZStack {
            Canvas { context, size in
                let centerY = size.height / 2
                let nodeRadius = nodeDiameter / 2
                let topNodeEdge = centerY - nodeRadius
                let bottomNodeEdge = centerY + nodeRadius
                let topConnectionSources = Set(topConnections.map(\.fromLane))
                let bottomConnectionTargets = Set(bottomConnections.map(\.toLane))

                for lane in topLanes.subtracting(topConnectionSources) {
                    let x = xPosition(for: lane)
                    let endY = lane == laneIndex ? topNodeEdge : centerY
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: endY))
                    context.stroke(path, with: .color(laneColor(lane)), style: strokeStyle)
                }

                for lane in bottomLanes.subtracting(bottomConnectionTargets) {
                    let x = xPosition(for: lane)
                    let startY = lane == laneIndex ? bottomNodeEdge : centerY
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: startY))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(laneColor(lane)), style: strokeStyle)
                }

                for connection in topConnections {
                    let fromX = xPosition(for: connection.fromLane)
                    let toX = xPosition(for: connection.toLane)
                    var path = Path()
                    path.move(to: CGPoint(x: fromX, y: 0))
                    path.addQuadCurve(
                        to: CGPoint(x: toX, y: topNodeEdge),
                        control: CGPoint(x: fromX, y: topNodeEdge)
                    )
                    context.stroke(path, with: .color(laneColor(connection.fromLane)), style: strokeStyle)
                }

                for connection in bottomConnections {
                    let fromX = xPosition(for: connection.fromLane)
                    let toX = xPosition(for: connection.toLane)
                    var path = Path()
                    path.move(to: CGPoint(x: fromX, y: bottomNodeEdge))
                    if connection.fromLane == connection.toLane {
                        path.addLine(to: CGPoint(x: toX, y: size.height))
                    } else {
                        path.addQuadCurve(
                            to: CGPoint(x: toX, y: size.height),
                            control: CGPoint(x: toX, y: bottomNodeEdge)
                        )
                    }
                    context.stroke(path, with: .color(laneColor(connection.toLane)), style: strokeStyle)
                }
            }

            statusNode
                .position(x: xPosition(for: laneIndex), y: 18)
        }
    }

    @ViewBuilder
    private var statusNode: some View {
        switch status {
        case .notTested:
            Circle()
                .fill(Color(NSColor.windowBackgroundColor))
                .overlay(Circle().stroke(Color.secondary, lineWidth: 2))
                .frame(width: nodeDiameter, height: nodeDiameter)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: nodeDiameter, height: nodeDiameter)
        case .success:
            filledNode(color: .green, systemImage: "checkmark")
        case .failed:
            filledNode(color: .red, systemImage: "xmark")
        case .warnings:
            filledNode(color: .yellow, systemImage: "exclamationmark")
        case .paused:
            filledNode(color: .orange, systemImage: "pause.fill")
        }
    }

    private func filledNode(color: Color, systemImage: String) -> some View {
        Circle()
            .fill(color)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
            )
            .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
            .frame(width: nodeDiameter, height: nodeDiameter)
    }

    private func xPosition(for lane: Int) -> CGFloat {
        GitGraphLayout.xPosition(for: lane)
    }

    private func laneColor(_ lane: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .mint, .pink, .cyan]
        return colors[lane % colors.count]
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round)
    }
}
