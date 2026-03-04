import Foundation

public enum DebugLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public enum DebugLog {
    private static let queue = DispatchQueue(label: "com.pragprod.msofficeresume.debug-log")

    public static func log(
        _ message: String,
        level: DebugLogLevel = .info,
        metadata: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line
    ) {
        queue.async {
            do {
                let url = try logFileURL()
                let timestamp = isoFormatter.string(from: Date())
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

    private static func logFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = appSupport
            .appendingPathComponent("com.pragprod.msofficeresume", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug-v1.log")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
