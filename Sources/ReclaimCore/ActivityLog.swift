import Foundation

/// One line of the app's Activity log, stored as `date<TAB>level<TAB>message`.
public struct LogEntry: Identifiable, Hashable, Sendable {
    public enum Level: String, Sendable { case info, success, warning, error }
    public let id = UUID()
    public var date: Date
    public let level: Level
    public let message: String

    public init(date: Date = Date(), level: Level, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }

    public init?(line: Substring) {
        let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
        guard fields.count == 3, let date = try? Date(fields[0], strategy: .iso8601),
              let level = Level(rawValue: fields[1]) else { return nil }
        self.init(date: date, level: level, message: fields[2])
    }

    public var line: String {
        "\(date.ISO8601Format())\t\(level.rawValue)\t\(message.replacingOccurrences(of: "\n", with: " "))\n"
    }

    /// The most recent `limit` entries of a log file's text, newest first.
    public static func parse(_ text: String, limit: Int = 500) -> [LogEntry] {
        text.split(separator: "\n").suffix(limit).reversed().compactMap(LogEntry.init(line:))
    }
}

extension OperationReport {
    /// E.g. "Compressed 3 file(s), freeing about 12 MB; 1 skipped (would not shrink enough)."
    public func summary(verb: String) -> String {
        var message = "\(verb) \(succeeded) file(s)"
        if bytesReclaimed > 0 { message += ", freeing about \(bytesReclaimed.formattedBytes)" }
        if skipped > 0 { message += "; \(skipped) skipped (would not shrink enough)" }
        return message + "."
    }
}

public enum UpdateCheck {
    /// The release version if tag `latest` (e.g. "v1.2.0") is newer than `current`, else nil.
    public static func newerVersion(latest tag: String, current: String) -> String? {
        let latest = String(tag.drop { $0 == "v" })
        return latest.compare(current, options: .numeric) == .orderedDescending ? latest : nil
    }
}
