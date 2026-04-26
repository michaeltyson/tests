//
//  WorkspaceFinder.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation

class WorkspaceFinder {
    /// Find the first .xcworkspace file in the given directory (searches root level only)
    static func findWorkspace(in directory: URL, preferredName: String = "") -> URL? {
        let workspaces = findWorkspaces(in: directory)
        let trimmedPreferredName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedPreferredName.isEmpty {
            let preferredWorkspaceName = trimmedPreferredName.hasSuffix(".xcworkspace")
                ? trimmedPreferredName
                : "\(trimmedPreferredName).xcworkspace"
            if let preferredWorkspace = workspaces.first(where: { $0.lastPathComponent == preferredWorkspaceName }) {
                return preferredWorkspace
            }
        }

        return workspaces.first
    }

    static func findWorkspaces(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func findWorkspaceNames(in directory: URL) -> [String] {
        findWorkspaces(in: directory).map(\.lastPathComponent)
    }

    static func findSchemeName(in directory: URL, preferredWorkspaceName: String = "") -> String? {
        let schemeURLs = findSchemeURLs(in: directory)
        guard !schemeURLs.isEmpty else { return nil }

        let preferredBaseName = preferredWorkspaceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".xcworkspace", with: "")

        return rankedSchemeURLs(schemeURLs, preferredBaseName: preferredBaseName).first.map(schemeName(from:))
    }

    static func findSchemeNames(in directory: URL, preferredWorkspaceName: String = "") -> [String] {
        let schemeURLs = findSchemeURLs(in: directory)
        guard !schemeURLs.isEmpty else { return [] }

        let preferredBaseName = preferredWorkspaceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".xcworkspace", with: "")

        var seen = Set<String>()
        return rankedSchemeURLs(schemeURLs, preferredBaseName: preferredBaseName)
            .map(schemeName(from:))
            .filter { seen.insert($0).inserted }
    }

    private static func findSchemeURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sharedSchemes: [URL] = []
        var userSchemes: [URL] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "xcscheme" {
            if fileURL.path.contains("/xcshareddata/xcschemes/") {
                sharedSchemes.append(fileURL)
            } else if fileURL.path.contains("/xcuserdata/") {
                userSchemes.append(fileURL)
            }
        }

        let sorter: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return sharedSchemes.sorted(by: sorter) + userSchemes.sorted(by: sorter)
    }

    private static func rankedSchemeURLs(_ schemeURLs: [URL], preferredBaseName: String) -> [URL] {
        schemeURLs.sorted { left, right in
            let leftScore = schemeScore(left, preferredBaseName: preferredBaseName)
            let rightScore = schemeScore(right, preferredBaseName: preferredBaseName)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
    }

    private static func schemeScore(_ schemeURL: URL, preferredBaseName: String) -> Int {
        let name = schemeName(from: schemeURL)
        let lowercasedName = name.lowercased()
        let lowercasedPreferredBaseName = preferredBaseName.lowercased()
        let testableReferenceCount = self.testableReferenceCount(in: schemeURL)
        var score = 0

        score += min(testableReferenceCount, 10) * 80
        if testableReferenceCount == 0 {
            score -= 80
        }

        if isTestSchemeName(lowercasedName), testableReferenceCount > 0 {
            score += 900
        }

        if schemeURL.path.contains("/xcshareddata/xcschemes/") {
            score += 20
        }

        if !lowercasedPreferredBaseName.isEmpty {
            if lowercasedName == lowercasedPreferredBaseName {
                score += 300
            } else if lowercasedName.hasPrefix("\(lowercasedPreferredBaseName) ") ||
                        lowercasedName.hasPrefix("\(lowercasedPreferredBaseName)-") ||
                        lowercasedName.hasPrefix("\(lowercasedPreferredBaseName)(") {
                score += 240
            } else if lowercasedName.contains(lowercasedPreferredBaseName) {
                score += 160
            }
        }

        if isMacSchemeName(lowercasedName) {
            score += 70
        }

        if isNonMacPlatformSchemeName(lowercasedName) {
            score -= 60
        }

        if isMetaSchemeName(lowercasedName) {
            score -= 200
        }

        score -= max(0, schemeURL.pathComponents.count - 5)
        return score
    }

    private static func testableReferenceCount(in schemeURL: URL) -> Int {
        guard let contents = try? String(contentsOf: schemeURL, encoding: .utf8) else {
            return 0
        }
        return contents.components(separatedBy: "<TestableReference").count - 1
    }

    private static func isMetaSchemeName(_ lowercasedName: String) -> Bool {
        let metaNames = [
            "all",
            "aggregate",
            "build all",
            "everything"
        ]
        return metaNames.contains(lowercasedName)
    }

    private static func isMacSchemeName(_ lowercasedName: String) -> Bool {
        lowercasedName.contains("macos") ||
        lowercasedName.contains("mac os") ||
        lowercasedName.contains("os x") ||
        lowercasedName.contains("(mac)")
    }

    private static func isNonMacPlatformSchemeName(_ lowercasedName: String) -> Bool {
        lowercasedName.contains("ios") ||
        lowercasedName.contains("tvos") ||
        lowercasedName.contains("watchos")
    }

    static func isTestSchemeName(_ lowercasedName: String) -> Bool {
        lowercasedName == "tests" ||
        lowercasedName.hasSuffix(" tests") ||
        lowercasedName.contains(" tests ") ||
        lowercasedName.contains(" tests-") ||
        lowercasedName.contains(" tests(") ||
        lowercasedName.hasSuffix("tests") ||
        lowercasedName.contains("tests ")
    }

    private static func schemeName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
