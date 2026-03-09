//
//  TestResultStore.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation
import Combine

class TestResultStore: ObservableObject {
    @Published var testRuns: [TestRun] = []
    
    private let storageDirectory: URL
    private let fileManager = FileManager.default
    
    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDirectory = appSupport.appendingPathComponent("Tests", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        
        loadHistory()
    }
    
    func shouldPersist(_ testRun: TestRun) -> Bool {
        // Do not persist placeholder runs that never actually started producing output/results.
        if testRun.status == .running &&
            (testRun.outputLog?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            testRun.errorDescription == nil &&
            testRun.passingCount == nil &&
            testRun.failingCount == nil &&
            testRun.duration == nil {
            return false
        }
        return true
    }
    
    func save(_ testRun: TestRun) {
        guard shouldPersist(testRun) else { return }
        
        let fileName = "\(testRun.id.uuidString).json"
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(testRun)
            try data.write(to: fileURL)
            
            // Update in-memory list
            if let index = testRuns.firstIndex(where: { $0.id == testRun.id }) {
                testRuns[index] = testRun
            } else {
                testRuns.insert(testRun, at: 0)
            }
            
            // Keep only most recent 100 runs
            if testRuns.count > 100 {
                let toRemove = testRuns.suffix(from: 100)
                for run in toRemove {
                    let fileName = "\(run.id.uuidString).json"
                    let fileURL = storageDirectory.appendingPathComponent(fileName)
                    try? fileManager.removeItem(at: fileURL)
                }
                testRuns = Array(testRuns.prefix(100))
            }
        } catch {
            print("Failed to save test run: \(error)")
        }
    }
    
    func update(_ testRun: TestRun) {
        save(testRun)
    }
    
    func delete(_ testRun: TestRun) {
        let fileName = "\(testRun.id.uuidString).json"
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        
        // Remove from disk
        try? fileManager.removeItem(at: fileURL)
        
        // Remove from in-memory list
        testRuns.removeAll { $0.id == testRun.id }
    }
    
    func clearAll() {
        // Delete all JSON files
        for testRun in testRuns {
            let fileName = "\(testRun.id.uuidString).json"
            let fileURL = storageDirectory.appendingPathComponent(fileName)
            try? fileManager.removeItem(at: fileURL)
        }
        
        // Clear in-memory list
        testRuns = []
    }
    
    private func loadHistory() {
        guard let files = try? fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let loadedRunsWithFiles: [(run: TestRun, fileURL: URL)] = jsonFiles.compactMap { fileURL in
            guard let data = try? Data(contentsOf: fileURL),
                  let testRun = try? decoder.decode(TestRun.self, from: data) else {
                return nil
            }
            return (testRun, fileURL)
        }
        
        var sanitizedRuns: [TestRun] = []
        
        for (run, fileURL) in loadedRunsWithFiles {
            if !shouldPersist(run) {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            
            var sanitized = run
            // Any "running" entry found on disk is stale from a previous incomplete run.
            if sanitized.status == .running {
                sanitized.status = .error
                if sanitized.errorDescription == nil || sanitized.errorDescription?.isEmpty == true {
                    sanitized.errorDescription = "Run did not complete."
                }
                
                if let data = try? JSONEncoder.iso8601.encode(sanitized) {
                    try? data.write(to: fileURL)
                }
            }
            
            sanitizedRuns.append(sanitized)
        }
        
        testRuns = sanitizedRuns.sorted { $0.timestamp > $1.timestamp }
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
