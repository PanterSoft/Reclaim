import Darwin
import Foundation

/// BSD file flags and mode bits used by Reclaim (from <sys/stat.h>).
enum FileFlags {
    static let typeMask: UInt16 = 0o170000
    static let regularType: UInt16 = 0o100000
    static let directoryType: UInt16 = 0o040000

    static let noDump: UInt32 = 0x0000_0001
    static let userImmutable: UInt32 = 0x0000_0002
    static let userAppend: UInt32 = 0x0000_0004
    static let compressed: UInt32 = 0x0000_0020
    static let hidden: UInt32 = 0x0000_8000
    static let systemImmutable: UInt32 = 0x0002_0000
    static let systemAppend: UInt32 = 0x0004_0000
    static let restricted: UInt32 = 0x0008_0000
    static let dataless: UInt32 = 0x4000_0000

    /// Files carrying any of these flags are never rewritten.
    static let locked = userImmutable | userAppend | systemImmutable | systemAppend | restricted
    /// User-visible flags copied from the original file onto its replacement.
    static let preserved = noDump | hidden
}

/// A snapshot of the low-level metadata Reclaim needs to decide whether a file is
/// safe to touch, and to detect whether it changed while we were working on it.
public struct FileStat: Hashable, Sendable {
    public struct TimeSpec: Hashable, Sendable {
        public let seconds: Int
        public let nanoseconds: Int

        init(_ ts: timespec) {
            seconds = ts.tv_sec
            nanoseconds = ts.tv_nsec
        }

        var cValue: timespec { timespec(tv_sec: seconds, tv_nsec: nanoseconds) }
        public var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9) }
    }

    public let device: Int32
    public let inode: UInt64
    public let mode: UInt16
    public let uid: UInt32
    public let linkCount: UInt16
    public let flags: UInt32
    /// Logical size in bytes.
    public let size: Int64
    /// Bytes actually allocated on disk (smaller than `size` for compressed files).
    public let allocatedSize: Int64
    public let accessTime: TimeSpec
    public let modificationTime: TimeSpec
    public let creationTime: TimeSpec

    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
        mode = st.st_mode
        uid = st.st_uid
        linkCount = st.st_nlink
        flags = st.st_flags
        size = st.st_size
        allocatedSize = st.st_blocks * 512
        accessTime = TimeSpec(st.st_atimespec)
        modificationTime = TimeSpec(st.st_mtimespec)
        creationTime = TimeSpec(st.st_birthtimespec)
    }

    /// `lstat(2)` the path. Symbolic links are described, never followed.
    public static func of(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileStat(st)
    }

    public var isRegularFile: Bool { mode & FileFlags.typeMask == FileFlags.regularType }
    public var isDirectory: Bool { mode & FileFlags.typeMask == FileFlags.directoryType }
    /// Stored with APFS/HFS+ transparent compression.
    public var isCompressed: Bool { flags & FileFlags.compressed != 0 }
    /// An iCloud (or other File Provider) placeholder whose contents are not on disk.
    public var isDataless: Bool { flags & FileFlags.dataless != 0 }
    public var isLocked: Bool { flags & FileFlags.locked != 0 }
    public var permissions: mode_t { mode & 0o7777 }

    /// Whether Reclaim may replace this file with an equivalent copy. We only touch plain
    /// files that belong to the current user, have a single hard link, are fully
    /// downloaded and are not locked or protected by System Integrity Protection.
    public var isSafeToRewrite: Bool {
        isRegularFile && uid == getuid() && linkCount == 1 && !isDataless && !isLocked
    }

    /// Whether `current` still looks like the same, unmodified file.
    public func isUnchanged(comparedTo current: FileStat) -> Bool {
        device == current.device && inode == current.inode
            && size == current.size && modificationTime == current.modificationTime
    }
}

/// APFS clone bookkeeping for a file, from `getattrlist(2)`.
public struct CloneInfo: Hashable, Sendable {
    /// Files that are pure clones of each other share a clone ID.
    public let cloneID: UInt64
    /// Bytes used by this file that are not shared with any other file.
    public let privateSize: Int64

    private static let privateSizeAttribute: UInt32 = 0x0000_0008 // ATTR_CMNEXT_PRIVATESIZE
    private static let cloneIDAttribute: UInt32 = 0x0000_0100 // ATTR_CMNEXT_CLONEID
    private static let noFollow: UInt32 = 0x0000_0001 // FSOPT_NOFOLLOW
    private static let extendedCommon: UInt32 = 0x0000_0020 // FSOPT_ATTR_CMN_EXTENDED

    /// Returns nil when the volume does not report clone information (e.g. HFS+, exFAT).
    public static func of(_ path: String) -> CloneInfo? {
        var request = attrlist()
        request.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        request.forkattr = privateSizeAttribute | cloneIDAttribute
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(path, &request, raw.baseAddress, raw.count, noFollow | extendedCommon)
        }
        guard rc == 0 else { return nil }
        // Layout: u_int32_t length, off_t private size, u_int64_t clone id.
        return buffer.withUnsafeBytes { raw -> CloneInfo? in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= 20 else { return nil }
            let privateSize = raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            let cloneID = raw.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
            return cloneID == 0 ? nil : CloneInfo(cloneID: cloneID, privateSize: privateSize)
        }
    }
}
