//
//  GitHistoryModels.swift
//  Tests
//

import Foundation

enum CommitTestStatus: Equatable {
    case notTested
    case running
    case success
    case failed
    case warnings
    case paused

    init(testRunStatus: TestRunStatus?) {
        switch testRunStatus {
        case .none:
            self = .notTested
        case .running:
            self = .running
        case .success:
            self = .success
        case .failed, .error:
            self = .failed
        case .warnings:
            self = .warnings
        case .paused:
            self = .paused
        }
    }
}

struct GitGraphLaneConnection: Hashable {
    let fromLane: Int
    let toLane: Int
}

struct GitCommitNode: Identifiable, Hashable {
    let sha: String
    let shortSHA: String
    let subject: String
    let authorDate: Date?
    let parentSHAs: [String]
    let branchNames: [String]
    let laneIndex: Int
    let laneCount: Int
    let topLanes: Set<Int>
    let bottomLanes: Set<Int>
    let topConnections: [GitGraphLaneConnection]
    let bottomConnections: [GitGraphLaneConnection]
    let testRun: TestRun?

    var id: String { sha }
    var testStatus: CommitTestStatus { CommitTestStatus(testRunStatus: testRun?.status) }
}

struct GitLogCommit: Equatable {
    let sha: String
    let shortSHA: String
    let authorDate: Date?
    let decorations: String
    let parentSHAs: [String]
    let subject: String
}
