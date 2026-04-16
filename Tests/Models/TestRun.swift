//
//  TestRun.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation

enum TestRunStatus: String, Codable {
    case running
    case success
    case failed
    case error
    case warnings
    case paused
}

struct TestRun: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    var status: TestRunStatus
    var duration: TimeInterval?
    var outputLog: String?
    var xcprettyOutput: String?
    var errorDescription: String?
    var xcprettyHTMLPath: String?
    var passingCount: Int?
    var failingCount: Int?
    var totalCount: Int?
    var branchName: String?
    var commitSHA: String?
    
    init(id: UUID = UUID(), timestamp: Date = Date(), status: TestRunStatus = .running) {
        self.id = id
        self.timestamp = timestamp
        self.status = status
    }
}
