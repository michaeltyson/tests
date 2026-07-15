import Foundation

enum TestsAPI {
    static let protocolVersion = 1
    static let requestNotificationName = "com.atastypixel.Tests.RunRequest"

    enum OutputMode: String, Codable {
        case failures
        case full
    }

    enum ResponseState: String, Codable {
        case accepted
        case completed
    }

    struct RunRequest: Codable {
        let version: Int
        let id: UUID
        let commitSHA: String
        let branchName: String?
        let repositoryPath: String
        let outputMode: OutputMode
        let createdAt: Date
    }

    struct RunResponse: Codable {
        let version: Int
        let requestID: UUID
        let state: ResponseState
        let status: String?
        let runID: UUID?
        let commitSHA: String
        let branchName: String?
        let duration: TimeInterval?
        let passingCount: Int?
        let failingCount: Int?
        let totalCount: Int?
        let errorDescription: String?
        let failureSummary: String?
        let outputLog: String?
    }

    static var directoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("API", isDirectory: true)
    }

    static var requestsDirectoryURL: URL {
        directoryURL.appendingPathComponent("Requests", isDirectory: true)
    }

    static var responsesDirectoryURL: URL {
        directoryURL.appendingPathComponent("Responses", isDirectory: true)
    }

    static func requestURL(for id: UUID) -> URL {
        requestsDirectoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    static func responseURL(for id: UUID) -> URL {
        responsesDirectoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    static func prepareDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: requestsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: responsesDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requestsDirectoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: responsesDirectoryURL.path)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
