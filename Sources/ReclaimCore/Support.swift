import CryptoKit
import Darwin
import Foundation

public enum ReclaimError: LocalizedError, Sendable {
    case posix(operation: String, code: Int32, path: String)
    case changedSinceScan(String)
    case verificationFailed(String)
    case notWorthCompressing(String)
    case notEligible(String)
    case cloningUnsupported(String)
    case insufficientSpace(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .posix(operation, code, path):
            return "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        case let .changedSinceScan(path):
            return "\(path) changed since it was scanned; left untouched."
        case let .verificationFailed(path):
            return "Verification failed for \(path); the original was left untouched."
        case let .notWorthCompressing(path):
            return "\(path) does not compress well enough; left untouched."
        case let .notEligible(path):
            return "\(path) is not a file Reclaim may modify."
        case let .cloningUnsupported(path):
            return "The volume containing \(path) does not support APFS clones."
        case let .insufficientSpace(path):
            return "Not enough free space to safely rewrite \(path)."
        case let .toolFailed(message):
            return message
        }
    }
}

public struct ProgressUpdate: Sendable {
    public let phase: String
    public let completed: Int
    /// Nil when the total is not yet known (e.g. while walking folders).
    public let total: Int?
    public let detail: String

    public init(phase: String, completed: Int, total: Int? = nil, detail: String = "") {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.detail = detail
    }

    public var summary: String {
        let count = total.map { "\(completed.formatted()) of \($0.formatted())" } ?? completed.formatted()
        return "\(phase): \(count)"
    }
}

public typealias ProgressHandler = @Sendable (ProgressUpdate) -> Void

/// Limits progress callbacks to a few per second.
struct Throttle {
    private var last = Date.distantPast

    mutating func ready(interval: TimeInterval = 0.1) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

/// The outcome of a batch operation (cloning or compressing).
public struct OperationReport: Sendable {
    public struct Failure: Sendable, Hashable, Identifiable {
        public let id = UUID()
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public var succeeded = 0
    public var skipped = 0
    public var bytesReclaimed: Int64 = 0
    public var failures: [Failure] = []

    public init() {}

    mutating func fail(_ path: String, _ error: Error) {
        failures.append(Failure(path: path, reason: error.localizedDescription))
    }
}

public enum ContentHash {
    /// SHA-256 of the file's contents (optionally only the first `maxBytes`), as hex.
    public static func sha256(ofFileAt path: String, maxBytes: Int64? = nil) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ReclaimError.posix(operation: "open", code: errno, path: path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = maxBytes ?? .max
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try autoreleasepool {
                try handle.read(upToCount: Int(min(remaining, 4 << 20)))
            } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Information about the volume a path lives on.
public struct VolumeInfo: Sendable, Hashable {
    public let name: String
    public let format: String
    public let totalCapacity: Int64
    /// Free space right now.
    public let availableCapacity: Int64
    /// Free space plus purgeable space macOS can reclaim on demand.
    public let availableForImportantUsage: Int64
    public let supportsCloning: Bool
    public let supportsCompression: Bool

    public var purgeable: Int64 { max(0, availableForImportantUsage - availableCapacity) }
    public var used: Int64 { max(0, totalCapacity - availableCapacity) }

    public init?(for url: URL) {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeSupportsFileCloningKey, .volumeSupportsCompressionKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        name = values.volumeName ?? "Volume"
        format = values.volumeLocalizedFormatDescription ?? ""
        totalCapacity = Int64(values.volumeTotalCapacity ?? 0)
        availableCapacity = Int64(values.volumeAvailableCapacity ?? 0)
        availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? availableCapacity
        supportsCloning = values.volumeSupportsFileCloning ?? false
        supportsCompression = values.volumeSupportsCompression ?? false
    }
}

extension Int64 {
    /// Human-readable size, e.g. "1.2 GB".
    public var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
