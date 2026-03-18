import Foundation

public enum DebugLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public enum DebugLog {
    private static let queue = DispatchQueue(label: "com.pragprod.msofficeresume.debug-log")
    public static let retentionInterval: TimeInterval = 24 * 60 * 60
    private static let pruneInterval: TimeInterval = 15 * 60
    private static var lastPrunedAtByPath: [String: Date] = [:]

    public static func log(
        _ message: String,
        level: DebugLogLevel = .info,
        metadata: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line
    ) {
        queue.async {
            do {
                let now = Date()
                let url = try logFileURL()
                try pruneExpiredEntriesIfNeeded(at: url, now: now)
                let timestamp = isoFormatter.string(from: now)
                let source = "\(file):\(line)"

                let metadataSegment: String
                if metadata.isEmpty {
                    metadataSegment = ""
                } else {
                    let flattened = metadata
                        .sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                    metadataSegment = " \(flattened)"
                }

                let lineText = "\(timestamp) [\(level.rawValue)] \(source) \(message)\(metadataSegment)\n"
                let data = Data(lineText.utf8)

                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                NSLog("OfficeResume debug logging failed: \(error.localizedDescription)")
            }
        }
    }

    public static func debug(_ message: String, metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        log(message, level: .debug, metadata: metadata, file: file, line: line)
    }

    public static func info(_ message: String, metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        log(message, level: .info, metadata: metadata, file: file, line: line)
    }

    public static func warning(_ message: String, metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        log(message, level: .warning, metadata: metadata, file: file, line: line)
    }

    public static func error(_ message: String, metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        log(message, level: .error, metadata: metadata, file: file, line: line)
    }

    public static func logFilePath() -> String {
        (try? logFileURL().path) ?? ""
    }

    public static func trimLogHistory(
        now: Date = Date(),
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) throws {
        try queue.sync {
            let url = try logFileURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
            try pruneExpiredEntriesIfNeeded(at: url, now: now, fileManager: fileManager, force: true)
        }
    }

    @discardableResult
    public static func openLogInConsole() -> Bool {
        do {
            let url = try logFileURL()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Console", url.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func logFileURL(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) throws -> URL {
        let root: URL
        if let baseDirectoryOverride {
            root = baseDirectoryOverride
        } else {
            root = try RuntimeConfiguration.sharedRoot(fileManager: fileManager)
        }
        let directory = root.appendingPathComponent("logs", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug-v1.log")
    }

    private static func pruneExpiredEntriesIfNeeded(
        at url: URL,
        now: Date,
        fileManager: FileManager = .default,
        force: Bool = false
    ) throws {
        if !force,
           let lastPrunedAt = lastPrunedAtByPath[url.path],
           now.timeIntervalSince(lastPrunedAt) < pruneInterval {
            return
        }

        lastPrunedAtByPath[url.path] = now

        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return
        }

        let cutoff = now.addingTimeInterval(-retentionInterval)
        let filteredLines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { shouldKeepLine(String($0), cutoff: cutoff) }

        let filteredData = filteredLines.isEmpty
            ? Data()
            : Data((filteredLines.joined(separator: "\n") + "\n").utf8)

        guard filteredData != data else {
            return
        }

        try filteredData.write(to: url, options: .atomic)
    }

    private static func shouldKeepLine(_ line: String, cutoff: Date) -> Bool {
        guard let timestamp = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
              let date = isoFormatter.date(from: String(timestamp))
        else {
            return false
        }

        return date >= cutoff
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
