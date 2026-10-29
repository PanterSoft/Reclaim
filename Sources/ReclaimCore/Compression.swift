import Compression
import Darwin
import Foundation

public struct CompressionCandidate: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let stat: FileStat
    /// Estimated compressed size / original size, from sampling the file.
    public let estimatedRatio: Double

    public var estimatedSavings: Int64 { Int64(Double(stat.allocatedSize) * (1 - estimatedRatio)) }
}

/// Transparent file compression (the same mechanism macOS uses for its own system files).
///
/// A compressed file keeps its name, contents and metadata; every app reads it exactly as
/// before and macOS decompresses it on the fly. Writing to the file simply stores it
/// uncompressed again. Nothing about the file changes except the space it takes on disk.
public enum TransparentCompression {
    /// Formats that are already compressed and will not shrink further.
    public static let incompressibleExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "mp3", "m4a", "aac", "ogg", "flac",
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "dmg", "pkg", "xip", "ipa", "jar", "docx", "xlsx", "pptx", "pages", "numbers", "key",
        "epub", "pdf", "sparseimage", "sparsebundle", "lz4", "zst", "br",
    ]

    /// Finds files worth compressing. Read-only.
    ///
    /// - Parameters:
    ///   - maximumRatio: only files estimated to shrink to at most this fraction are returned.
    ///   - minimumAge: skip files modified more recently than this (they are likely to change again).
    public static func findCandidates(
        in roots: [URL],
        options: ScanOptions,
        maximumRatio: Double = 0.8,
        minimumAge: TimeInterval = 24 * 60 * 60,
        progress: ProgressHandler? = nil
    ) throws -> [CompressionCandidate] {
        var candidates: [CompressionCandidate] = []
        var supportsCompression: [Int32: Bool] = [:]
        let cutoff = Date().addingTimeInterval(-minimumAge)
        var seen = 0
        var throttle = Throttle()

        try FileWalker.walk(roots, options: options) { path, st in
            seen += 1
            if throttle.ready() { progress?(ProgressUpdate(phase: "Sampling files", completed: seen, detail: path)) }
            guard st.size >= max(options.minimumFileSize, 4096), st.isSafeToRewrite, !st.isCompressed,
                  st.modificationTime.date < cutoff,
                  !incompressibleExtensions.contains((path as NSString).pathExtension.lowercased())
            else { return }
            if supportsCompression[st.device] == nil {
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCompressionKey])
                supportsCompression[st.device] = values?.volumeSupportsCompression ?? false
            }
            guard supportsCompression[st.device] == true else { return }
            let ratio = estimateRatio(path: path, size: st.size)
            if ratio <= maximumRatio {
                candidates.append(CompressionCandidate(path: path, stat: st, estimatedRatio: ratio))
            }
        }
        return candidates.sorted { $0.estimatedSavings > $1.estimatedSavings }
    }

    /// Compresses the candidates, keeping only results that save at least 10%.
    public static func compress(_ candidates: [CompressionCandidate], progress: ProgressHandler? = nil) -> OperationReport {
        var report = OperationReport()
        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled else { break }
            progress?(ProgressUpdate(phase: "Compressing", completed: index + 1, total: candidates.count, detail: candidate.path))
            do {
                report.bytesReclaimed += try compress(candidate.path, expected: candidate.stat)
                report.succeeded += 1
            } catch ReclaimError.notWorthCompressing {
                report.skipped += 1
            } catch {
                report.fail(candidate.path, error)
            }
        }
        return report
    }

    /// Compresses one file in place and returns the bytes saved.
    @discardableResult
    public static func compress(_ path: String, expected: FileStat) throws -> Int64 {
        guard expected.isSafeToRewrite, !expected.isCompressed else { throw ReclaimError.notEligible(path) }
        let hash = try ContentHash.sha256(ofFileAt: path)
        var saved: Int64 = 0
        try SafeReplace.replace(path, expected: expected, contentHash: hash, build: { temporary in
            try Ditto.copy(["--hfsCompression", path, temporary])
            try SafeReplace.copyMetadata(from: path, stat: expected, to: temporary, extendedAttributes: false)
        }, accept: { replacement in
            // ditto leaves a file uncompressed when compression would not help.
            guard replacement.isCompressed else {
                throw ReclaimError.notWorthCompressing(path, reason: "ditto did not compress it")
            }
            saved = expected.allocatedSize - replacement.allocatedSize
            guard Double(replacement.allocatedSize) <= Double(expected.allocatedSize) * 0.9 else {
                throw ReclaimError.notWorthCompressing(path, reason: "it would only shrink from \(expected.allocatedSize.formattedBytes) to \(replacement.allocatedSize.formattedBytes)")
            }
        })
        return saved
    }

    /// Undoes compression for a file. Returns the extra bytes it now uses.
    @discardableResult
    public static func decompress(_ path: String) throws -> Int64 {
        guard let current = FileStat.of(path), current.isSafeToRewrite else { throw ReclaimError.notEligible(path) }
        guard current.isCompressed else { return 0 }
        if let volume = VolumeInfo(for: URL(fileURLWithPath: path)),
           volume.availableForImportantUsage < current.size + (1 << 30) {
            throw ReclaimError.insufficientSpace(path)
        }
        let hash = try ContentHash.sha256(ofFileAt: path)
        var grown: Int64 = 0
        try SafeReplace.replace(path, expected: current, contentHash: hash, build: { temporary in
            try Ditto.copy(["--nopreserveHFSCompression", path, temporary])
            try SafeReplace.copyMetadata(from: path, stat: current, to: temporary, extendedAttributes: false)
        }, accept: { replacement in
            guard !replacement.isCompressed else { throw ReclaimError.verificationFailed(path) }
            grown = replacement.allocatedSize - current.allocatedSize
        })
        return grown
    }

    /// Compresses up to three 64 KiB samples (start, middle, end) to estimate the ratio.
    static func estimateRatio(path: String, size: Int64) -> Double {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 1 }
        defer { try? handle.close() }
        let block = 64 * 1024
        var offsets: [UInt64] = [0]
        if size > Int64(block * 3) { offsets += [UInt64(size / 2), UInt64(size - Int64(block))] }

        var output = [UInt8](repeating: 0, count: block)
        var original = 0
        var compressed = 0
        for offset in offsets {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: block), !data.isEmpty else { continue }
            let written = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress!, destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            original += data.count
            // 0 means the output did not fit: the sample is incompressible.
            compressed += written == 0 ? data.count : min(written, data.count)
        }
        return original == 0 ? 1 : Double(compressed) / Double(original)
    }
}
