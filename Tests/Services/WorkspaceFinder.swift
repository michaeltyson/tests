//
//  WorkspaceFinder.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation

class WorkspaceFinder {
    struct SchemeInfo: Equatable {
        let name: String
        let url: URL
        let testableNames: [String]

        var testableReferenceCount: Int {
            testableNames.count
        }
    }

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
        findSchemeInfos(in: directory, preferredWorkspaceName: preferredWorkspaceName).first?.name
    }

    static func findSchemeNames(in directory: URL, preferredWorkspaceName: String = "") -> [String] {
        findSchemeInfos(in: directory, preferredWorkspaceName: preferredWorkspaceName).map(\.name)
    }

    static func findSchemeInfo(
        named name: String,
        in directory: URL,
        preferredWorkspaceName: String = ""
    ) -> SchemeInfo? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        return findSchemeInfos(in: directory, preferredWorkspaceName: preferredWorkspaceName)
            .first { $0.name == trimmedName }
    }

    static func findSchemeInfos(in directory: URL, preferredWorkspaceName: String = "") -> [SchemeInfo] {
        let schemeURLs = findSchemeURLs(in: directory)
        guard !schemeURLs.isEmpty else { return [] }

        let preferredBaseName = preferredWorkspaceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".xcworkspace", with: "")

        var seen = Set<String>()
        let rankedSchemes = rankedSchemeInfos(
            schemeURLs.map(schemeInfo(from:)),
            preferredBaseName: preferredBaseName
        )

        return rankedSchemes.filter { seen.insert($0.name).inserted }
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

    private static func rankedSchemeInfos(_ schemes: [SchemeInfo], preferredBaseName: String) -> [SchemeInfo] {
        schemes.sorted { left, right in
            let leftScore = schemeScore(left, preferredBaseName: preferredBaseName)
            let rightScore = schemeScore(right, preferredBaseName: preferredBaseName)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return left.url.path.localizedStandardCompare(right.url.path) == .orderedAscending
        }
    }

    private static func schemeScore(_ scheme: SchemeInfo, preferredBaseName: String) -> Int {
        let name = scheme.name
        let lowercasedName = name.lowercased()
        let lowercasedPreferredBaseName = preferredBaseName.lowercased()
        let testableReferenceCount = scheme.testableReferenceCount
        var score = 0

        score += min(testableReferenceCount, 20) * 300
        if testableReferenceCount == 0 {
            score -= 80
        }

        if scheme.url.path.contains("/xcshareddata/xcschemes/") {
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

        score -= max(0, scheme.url.pathComponents.count - 5)
        return score
    }

    private static func schemeInfo(from schemeURL: URL) -> SchemeInfo {
        SchemeInfo(
            name: schemeName(from: schemeURL),
            url: schemeURL,
            testableNames: testableNames(in: schemeURL)
        )
    }

    static func testableNames(in schemeURL: URL) -> [String] {
        guard let contents = try? String(contentsOf: schemeURL, encoding: .utf8) else {
            return []
        }
        return testableNames(fromSchemeContents: contents)
    }

    static func testableNames(fromSchemeContents contents: String) -> [String] {
        let pattern = #"<TestableReference\b(?:[^>]*/>|[\s\S]*?</TestableReference>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let contentsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.matches(in: contents, range: contentsRange).map { match in
            let block = String(contents[Range(match.range, in: contents)!])
            return attributeValue(named: "BlueprintName", in: block)
                ?? attributeValue(named: "ReferencedContainer", in: block)?
                    .split(separator: "/")
                    .last
                    .map(String.init)
                ?? "Unknown Testable"
        }
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

    private static func attributeValue(named attributeName: String, in text: String) -> String? {
        let pattern = #"\#(attributeName)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}
