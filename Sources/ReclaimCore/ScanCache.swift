import Foundation

/// Remembers the expensive per-file results of earlier scans (compression estimate, content
/// hashes) so a rescan only reads files that are new or changed. An entry is reused only while
/// the file's device, inode, size and modification time are unchanged.
// ponytail: entries for deleted files linger and the whole file is rewritten on save; prune/sqlite if it grows large.
public final class ScanCache: @unchecked Sendable {
    struct Entry: Codable {
        var device: Int32, inode: UInt64, size: Int64, mtimeSeconds: Int, mtimeNanoseconds: Int
        var ratio: Double?
        var prefixHash: String?
        var fullHash: String?

        func matches(_ st: FileStat) -> Bool {
            device == st.device && inode == st.inode && size == st.size
                && mtimeSeconds == st.modificationTime.seconds && mtimeNanoseconds == st.modificationTime.nanoseconds
        }
    }

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Reclaim/scan-cache.json")

    private let url: URL?
    private var entries: [String: Entry]
    private var dirty = false
    private let lock = NSLock()

    /// Loads the cache at `url`; a missing or unreadable file gives an empty cache. A nil `url` never touches disk.
    public init(url: URL? = ScanCache.defaultURL) {
        self.url = url
        entries = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func entry(_ path: String, _ st: FileStat) -> Entry? {
        lock.withLock { entries[path].flatMap { $0.matches(st) ? $0 : nil } }
    }

    func update(_ path: String, _ st: FileStat, _ change: (inout Entry) -> Void) {
        lock.withLock {
            var entry = entries[path].flatMap { $0.matches(st) ? $0 : nil }
                ?? Entry(device: st.device, inode: st.inode, size: st.size,
                         mtimeSeconds: st.modificationTime.seconds, mtimeNanoseconds: st.modificationTime.nanoseconds)
            change(&entry)
            entries[path] = entry
            dirty = true
        }
    }

    public func save() {
        guard let url, let data = lock.withLock({ () -> Data? in
            defer { dirty = false }
            return dirty ? try? JSONEncoder().encode(entries) : nil
        }) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Cached `ContentHash.sha256`, whole file or first `prefix` bytes.
    func hash(_ path: String, _ st: FileStat, prefix: Int64? = nil) throws -> String {
        if let hit = entry(path, st), let h = prefix == nil ? hit.fullHash : hit.prefixHash { return h }
        let h = try ContentHash.sha256(ofFileAt: path, maxBytes: prefix)
        update(path, st) { if prefix == nil { $0.fullHash = h } else { $0.prefixHash = h } }
        return h
    }
}
