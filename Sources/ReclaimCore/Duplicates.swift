import Darwin
import Foundation

public struct DuplicateFile: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let stat: FileStat
    public let clone: CloneInfo?

    /// Files that are already clones of each other form one "family".
    var familyKey: String { clone.map { "clone-\($0.cloneID)" } ?? "inode-\(stat.inode)" }
}

/// Files with identical contents on the same volume.
public struct DuplicateGroup: Hashable, Sendable, Identifiable {
    public struct Family: Hashable, Sendable {
        public let files: [DuplicateFile]
        /// Space freed once every file in this family shares the keeper's storage.
        public let reclaimableBytes: Int64
    }

    public let id: String
    public let contentHash: String
    public let size: Int64
    /// The file whose storage the others will share. It is never modified.
    public let keeper: DuplicateFile
    /// Clone families that will be rewritten as clones of `keeper`.
    public let families: [Family]

    public var filesToReplace: [DuplicateFile] { families.flatMap(\.files) }
    public var allFiles: [DuplicateFile] { [keeper] + filesToReplace }
    public var reclaimableBytes: Int64 { families.reduce(0) { $0 + $1.reclaimableBytes } }

    /// Returns nil when there is nothing to gain (e.g. all files already share storage).
    init?(contentHash: String, files: [DuplicateFile]) {
        let grouped = Dictionary(grouping: files, by: \.familyKey).values.map { $0.sorted { $0.path < $1.path } }
        guard grouped.count > 1, let first = files.first else { return nil }
        // Keep the largest existing family so the fewest files need rewriting.
        let ordered = grouped.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs[0].path < rhs[0].path
        }
        var families: [Family] = []
        for members in ordered.dropFirst() {
            let bytes: Int64
            if members.count == 1, let clone = members[0].clone {
                // Blocks already shared with some other file would not be freed.
                bytes = min(clone.privateSize, members[0].stat.allocatedSize)
            } else {
                bytes = members.map(\.stat.allocatedSize).max() ?? 0
            }
            if bytes > 0 { families.append(Family(files: members, reclaimableBytes: bytes)) }
        }
        guard !families.isEmpty else { return nil }
        self.id = "\(first.stat.device)-\(contentHash)"
        self.contentHash = contentHash
        self.size = first.stat.size
        self.keeper = ordered[0][0]
        self.families = families
    }
}

public enum DuplicateFinder {
    /// Finds files with identical contents. Read-only.
    ///
    /// Files are grouped by volume and size, then by a hash of their first 64 KiB, and
    /// finally by a SHA-256 of their full contents.
    public static func findDuplicates(in roots: [URL], options: ScanOptions, progress: ProgressHandler? = nil) throws -> [DuplicateGroup] {
        struct SizeKey: Hashable { let device: Int32; let size: Int64 }
        var bySize: [SizeKey: [(path: String, stat: FileStat)]] = [:]
        var cloningSupport: [Int32: Bool] = [:]
        var seen = 0
        var throttle = Throttle()

        try FileWalker.walk(roots, options: options) { path, st in
            seen += 1
            if throttle.ready() { progress?(ProgressUpdate(phase: "Looking for files", completed: seen, detail: path)) }
            guard st.size >= max(options.minimumFileSize, 1), st.isSafeToRewrite else { return }
            if cloningSupport[st.device] == nil {
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsFileCloningKey])
                cloningSupport[st.device] = values?.volumeSupportsFileCloning ?? false
            }
            guard cloningSupport[st.device] == true else { return }
            bySize[SizeKey(device: st.device, size: st.size), default: []].append((path, st))
        }

        let buckets = bySize.values.filter { $0.count > 1 }
        let total = buckets.reduce(0) { $0 + $1.count }
        var compared = 0
        var groups: [DuplicateGroup] = []
        let prefixLength: Int64 = 64 * 1024

        for bucket in buckets {
            var byPrefix: [String: [(path: String, stat: FileStat)]] = [:]
            for entry in bucket {
                try Task.checkCancellation()
                compared += 1
                if throttle.ready() {
                    progress?(ProgressUpdate(phase: "Comparing contents", completed: compared, total: total, detail: entry.path))
                }
                guard let hash = try? ContentHash.sha256(ofFileAt: entry.path, maxBytes: prefixLength) else { continue }
                byPrefix[hash, default: []].append(entry)
            }

            for (prefixHash, candidates) in byPrefix where candidates.count > 1 {
                let files = candidates.map { DuplicateFile(path: $0.path, stat: $0.stat, clone: CloneInfo.of($0.path)) }
                // Already one clone family: nothing to gain, skip the expensive full hash.
                if Set(files.map(\.familyKey)).count < 2 { continue }

                var byContent: [String: [DuplicateFile]] = [:]
                for file in files {
                    try Task.checkCancellation()
                    if throttle.ready() {
                        progress?(ProgressUpdate(phase: "Comparing contents", completed: compared, total: total, detail: file.path))
                    }
                    let hash: String?
                    if file.stat.size <= prefixLength {
                        hash = prefixHash
                    } else {
                        hash = try? ContentHash.sha256(ofFileAt: file.path)
                    }
                    guard let hash else { continue }
                    byContent[hash, default: []].append(file)
                }
                for (hash, same) in byContent where same.count > 1 {
                    if let group = DuplicateGroup(contentHash: hash, files: same) { groups.append(group) }
                }
            }
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
}

public enum CloneDeduplicator {
    /// Replaces every file in `filesToReplace` with an APFS clone of the group's keeper.
    ///
    /// A clone is a full, independent file: same contents, same name, same metadata. It
    /// simply shares its storage blocks with the keeper until either file is edited, at
    /// which point APFS transparently copies just the changed blocks.
    public static func deduplicate(_ groups: [DuplicateGroup], progress: ProgressHandler? = nil) -> OperationReport {
        var report = OperationReport()
        let total = groups.reduce(0) { $0 + $1.filesToReplace.count }
        var done = 0

        for group in groups {
            guard !Task.isCancelled else { break }
            guard let keeperNow = FileStat.of(group.keeper.path), group.keeper.stat.isUnchanged(comparedTo: keeperNow) else {
                for file in group.filesToReplace { report.fail(file.path, ReclaimError.changedSinceScan(group.keeper.path)) }
                done += group.filesToReplace.count
                continue
            }
            for family in group.families {
                var familyOK = true
                for file in family.files {
                    guard !Task.isCancelled else { return report }
                    done += 1
                    progress?(ProgressUpdate(phase: "Cloning duplicates", completed: done, total: total, detail: file.path))
                    do {
                        try replaceWithClone(file, of: group.keeper.path, contentHash: group.contentHash)
                        report.succeeded += 1
                    } catch {
                        familyOK = false
                        report.fail(file.path, error)
                    }
                }
                if familyOK { report.bytesReclaimed += family.reclaimableBytes }
            }
        }
        return report
    }

    static func replaceWithClone(_ file: DuplicateFile, of keeper: String, contentHash: String) throws {
        try SafeReplace.replace(file.path, expected: file.stat, contentHash: contentHash) { temporary in
            guard clonefile(keeper, temporary, 0x0001 /* CLONE_NOFOLLOW */) == 0 else {
                let code = errno
                if code == ENOTSUP || code == EXDEV { throw ReclaimError.cloningUnsupported(file.path) }
                throw ReclaimError.posix(operation: "clonefile", code: code, path: file.path)
            }
            try SafeReplace.copyMetadata(from: file.path, stat: file.stat, to: temporary, extendedAttributes: true)
        }
    }
}
