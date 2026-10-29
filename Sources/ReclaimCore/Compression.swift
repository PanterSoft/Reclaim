import Compression
import CryptoKit
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
            guard st.size >= max(options.minimumFileSize, 4096), st.size <= maximumFileSize,
                  st.isSafeToRewrite, !st.isCompressed, st.modificationTime.date < cutoff,
                  !incompressibleExtensions.contains((path as NSString).pathExtension.lowercased())
            else { return }
            if supportsCompression[st.device] == nil {
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCompressionKey])
                supportsCompression[st.device] = values?.volumeSupportsCompression ?? false
            }
            guard supportsCompression[st.device] == true else { return }
            guard !ExtendedAttributes.exists(ExtendedAttributes.resourceFork, on: path) else { return }
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

    /// Files above this size are skipped: their compressed form is assembled in memory.
    public static let maximumFileSize: Int64 = 256 << 20
    /// macOS compresses files in independent 64 KiB chunks.
    static let chunkSize = 64 * 1024

    /// Compresses one file in place and returns the bytes saved.
    ///
    /// The file is stored the way macOS stores its own compressed files: the data is split
    /// into 64 KiB chunks, each compressed with LZFSE and kept in the file's resource fork,
    /// with a small header in the `com.apple.decmpfs` attribute and the `UF_COMPRESSED`
    /// flag set. The kernel then decompresses it transparently for every app.
    @discardableResult
    public static func compress(_ path: String, expected: FileStat) throws -> Int64 {
        guard expected.isSafeToRewrite, !expected.isCompressed else { throw ReclaimError.notEligible(path) }
        guard expected.size <= maximumFileSize else {
            throw ReclaimError.notWorthCompressing(path, reason: "it is larger than \(maximumFileSize.formattedBytes)")
        }
        // The compressed data lives in the resource fork, so a file that already has one is left alone.
        guard !ExtendedAttributes.exists(ExtendedAttributes.resourceFork, on: path) else {
            throw ReclaimError.notEligible(path)
        }
        try SafeReplace.ensureUnchanged(path, matches: expected)

        let encoded = try encode(path, size: expected.size)
        guard Double(encoded.resourceFork.count) <= Double(expected.size) * 0.9 else {
            let compressed = Int64(encoded.resourceFork.count).formattedBytes
            throw ReclaimError.notWorthCompressing(path, reason: "it would only shrink from \(expected.size.formattedBytes) to \(compressed)")
        }

        var saved: Int64 = 0
        try SafeReplace.replace(path, expected: expected, contentHash: encoded.contentHash, build: { temporary in
            let descriptor = open(temporary, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard descriptor >= 0 else { throw ReclaimError.posix(operation: "create", code: errno, path: path) }
            _ = close(descriptor)
            try SafeReplace.copyExtendedAttributes(from: path, to: temporary)
            try ExtendedAttributes.set(ExtendedAttributes.resourceFork, encoded.resourceFork, on: temporary)
            try ExtendedAttributes.set(ExtendedAttributes.compressionHeader, header(uncompressedSize: expected.size), on: temporary)
            guard chflags(temporary, FileFlags.compressed) == 0 else {
                throw ReclaimError.posix(operation: "chflags", code: errno, path: path)
            }
            try SafeReplace.copyAttributes(from: path, stat: expected, to: temporary, includingACL: true)
        }, accept: { replacement in
            guard replacement.isCompressed else { throw ReclaimError.verificationFailed(path) }
            saved = max(0, expected.allocatedSize - replacement.allocatedSize)
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
            try writeUncompressedCopy(of: path, to: temporary)
            try SafeReplace.copyExtendedAttributes(from: path, to: temporary)
            try SafeReplace.copyAttributes(from: path, stat: current, to: temporary, includingACL: true)
        }, accept: { replacement in
            guard !replacement.isCompressed else { throw ReclaimError.verificationFailed(path) }
            grown = replacement.allocatedSize - current.allocatedSize
        })
        return grown
    }

    /// Reads the file once, returning its compressed resource fork and the SHA-256 of its contents.
    ///
    /// Resource fork layout: a table of `chunks + 1` little-endian UInt32 offsets (from the start
    /// of the fork), followed by each chunk as a self-contained LZFSE stream.
    static func encode(_ path: String, size: Int64) throws -> (resourceFork: [UInt8], contentHash: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ReclaimError.posix(operation: "open", code: errno, path: path)
        }
        defer { try? handle.close() }

        let chunkCount = Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
        let tableSize = (chunkCount + 1) * 4
        var fork = [UInt8](repeating: 0, count: tableSize)
        var offsets: [UInt32] = [UInt32(tableSize)]
        var hasher = SHA256()
        var output = [UInt8](repeating: 0, count: chunkSize + 4096)
        var scratch = [UInt8](repeating: 0, count: compression_encode_scratch_buffer_size(COMPRESSION_LZFSE))
        var total: Int64 = 0

        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            let written = chunk.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                output.withUnsafeMutableBufferPointer { destination in
                    scratch.withUnsafeMutableBytes { scratchBuffer in
                        compression_encode_buffer(
                            destination.baseAddress!, destination.count,
                            source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                            scratchBuffer.baseAddress, COMPRESSION_LZFSE
                        )
                    }
                }
            }
            guard written > 0 else { throw ReclaimError.notWorthCompressing(path, reason: "the compressor failed") }
            fork.append(contentsOf: output[0..<written])
            offsets.append(UInt32(fork.count))
        }
        guard total == size, offsets.count == chunkCount + 1 else { throw ReclaimError.changedSinceScan(path) }

        for (index, offset) in offsets.enumerated() {
            withUnsafeBytes(of: offset.littleEndian) { bytes in
                fork.replaceSubrange(index * 4..<index * 4 + 4, with: bytes)
            }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (fork, hash)
    }

    /// The `com.apple.decmpfs` header: magic "cmpf", type 12 (LZFSE in the resource fork), size.
    static func header(uncompressedSize: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt32(0x636D_7066).littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(12).littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(uncompressedSize).littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }

    /// Copies the file's contents (which macOS decompresses as we read) into a new plain file.
    static func writeUncompressedCopy(of source: String, to destination: String) throws {
        guard FileManager.default.createFile(atPath: destination, contents: nil, attributes: [.posixPermissions: 0o600]),
              let input = FileHandle(forReadingAtPath: source),
              let output = FileHandle(forWritingAtPath: destination)
        else { throw ReclaimError.posix(operation: "copy", code: errno, path: source) }
        defer {
            try? input.close()
            try? output.close()
        }
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try input.read(upToCount: 4 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
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
                        nil, COMPRESSION_LZFSE
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
