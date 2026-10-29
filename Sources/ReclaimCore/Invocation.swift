import Foundation

/// A parsed `reclaim` command line.
public struct Invocation: Sendable, Equatable {
    public struct UsageError: Error, Equatable {
        public let message: String
    }

    public var command = ""
    public var apply = false
    public var minimumSize: Int64?
    public var includeApps = false
    public var paths: [String] = []

    public init() {}

    public var roots: [URL] {
        paths.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : paths.map { URL(fileURLWithPath: $0) }
    }

    /// Nil when the usage text should be shown (no arguments, -h or --help).
    public static func parse(_ arguments: [String]) throws -> Invocation? {
        var invocation = Invocation()
        var iterator = arguments.makeIterator()
        guard let command = iterator.next(), command != "-h", command != "--help" else { return nil }
        invocation.command = command
        while let argument = iterator.next() {
            switch argument {
            case "--apply": invocation.apply = true
            case "--include-apps": invocation.includeApps = true
            case "--min-size":
                guard let value = iterator.next(), let size = parseSize(value) else {
                    throw UsageError(message: "--min-size needs a size like 1M")
                }
                invocation.minimumSize = size
            case "-h", "--help": return nil
            default:
                if argument.hasPrefix("-") { throw UsageError(message: "unknown option \(argument)") }
                invocation.paths.append(argument)
            }
        }
        return invocation
    }

    /// Bytes for "512", "512K", "10M" or "1.5G" (case-insensitive); nil if it is not a size.
    public static func parseSize(_ text: String) -> Int64? {
        let multipliers: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
        let upper = text.uppercased()
        let bytes: Int64?
        if let last = upper.last, let multiplier = multipliers[last] {
            // `exactly` turns "INFK" or "1e30G" into nil instead of a crash.
            bytes = Double(upper.dropLast()).flatMap { Int64(exactly: ($0 * Double(multiplier)).rounded(.down)) }
        } else {
            bytes = Int64(upper)
        }
        return bytes.flatMap { $0 >= 0 ? $0 : nil }
    }
}
