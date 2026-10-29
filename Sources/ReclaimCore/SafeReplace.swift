import Darwin
import Foundation

/// The one way Reclaim changes a file on disk:
///
/// 1. Build an equivalent copy in a hidden temporary file next to the original.
/// 2. Give it the original's permissions, flags, dates, extended attributes and ACL.
/// 3. Verify its contents hash to exactly what the original contained.
/// 4. Check the original has not changed since it was scanned.
/// 5. Atomically `rename(2)` the copy over the original.
///
/// If any step fails the temporary file is removed and the original is never touched.
enum SafeReplace {
    private static let prefix = ".reclaim-"
    private static let suffix = ".tmp"

    static func temporaryPath(besides path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent(prefix + UUID().uuidString + suffix)
    }

    static func isTemporaryFile(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix(suffix)
    }

    static func ensureUnchanged(_ path: String, matches expected: FileStat) throws {
        guard let current = FileStat.of(path), expected.isUnchanged(comparedTo: current) else {
            throw ReclaimError.changedSinceScan(path)
        }
    }

    /// Runs `build` to create a replacement at a temporary path, then verifies and commits it.
    static func replace(
        _ path: String,
        expected: FileStat,
        contentHash: String,
        build: (_ temporaryPath: String) throws -> Void,
        accept: (_ replacement: FileStat) throws -> Void = { _ in }
    ) throws {
        try ensureUnchanged(path, matches: expected)
        let temporary = temporaryPath(besides: path)
        var committed = false
        defer { if !committed { unlink(temporary) } }

        try build(temporary)
        guard let replacement = FileStat.of(temporary), replacement.isRegularFile,
              replacement.size == expected.size else {
            throw ReclaimError.verificationFailed(path)
        }
        try accept(replacement)
        guard try ContentHash.sha256(ofFileAt: temporary) == contentHash else {
            throw ReclaimError.verificationFailed(path)
        }
        try ensureUnchanged(path, matches: expected)
        guard rename(temporary, path) == 0 else {
            throw ReclaimError.posix(operation: "rename", code: errno, path: path)
        }
        committed = true
    }

    /// Replaces the replacement's extended attributes and ACL with an empty set, then copies
    /// the original's visible extended attributes (Finder tags, comments, quarantine, …) onto it.
    /// The attributes macOS uses to store compressed data are hidden and never copied.
    static func copyExtendedAttributes(from original: String, to replacement: String) throws {
        // Make sure we can write attributes even if the replacement is read-only.
        guard chmod(replacement, 0o600) == 0 else {
            throw ReclaimError.posix(operation: "chmod", code: errno, path: original)
        }
        if let empty = acl_init(0) {
            _ = acl_set_file(replacement, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        for name in try ExtendedAttributes.names(replacement) {
            try ExtendedAttributes.remove(name, from: replacement)
        }
        for name in try ExtendedAttributes.names(original) {
            try ExtendedAttributes.set(name, ExtendedAttributes.value(name, of: original), on: replacement)
        }
    }

    /// Gives the replacement the original's flags, permissions, dates and ACL.
    static func copyAttributes(from original: String, stat: FileStat, to replacement: String, includingACL: Bool) throws {
        func check(_ result: Int32, _ operation: String) throws {
            if result != 0 { throw ReclaimError.posix(operation: operation, code: errno, path: original) }
        }

        if let current = FileStat.of(replacement) {
            let flags = (current.flags & ~FileFlags.preserved) | (stat.flags & FileFlags.preserved)
            if flags != current.flags { try check(chflags(replacement, flags), "chflags") }
        }
        try check(chmod(replacement, stat.permissions), "chmod")

        var request = attrlist()
        request.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        request.commonattr = 0x0000_0200 // ATTR_CMN_CRTIME
        var created = stat.creationTime.cValue
        try check(setattrlist(replacement, &request, &created, MemoryLayout<timespec>.size, 0x1), "set creation date")
        var times = [stat.accessTime.cValue, stat.modificationTime.cValue]
        try check(utimensat(AT_FDCWD, replacement, &times, AT_SYMLINK_NOFOLLOW), "set modification date")

        if includingACL {
            try check(copyfile(original, replacement, nil, copyfile_flags_t(1 << 0)), "copy ACL") // COPYFILE_ACL
        }
    }
}

/// Thin wrappers around the BSD extended attribute calls. Symlinks are never followed.
enum ExtendedAttributes {
    static let resourceFork = "com.apple.ResourceFork"
    static let compressionHeader = "com.apple.decmpfs"
    private static let noFollow: Int32 = 0x0001 // XATTR_NOFOLLOW

    /// Names of the visible attributes. macOS hides the compression attributes of a
    /// compressed file from this list.
    static func names(_ path: String) throws -> [String] {
        let length = listxattr(path, nil, 0, noFollow)
        guard length >= 0 else { throw ReclaimError.posix(operation: "listxattr", code: errno, path: path) }
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        let read = listxattr(path, &buffer, length, noFollow)
        guard read >= 0 else { throw ReclaimError.posix(operation: "listxattr", code: errno, path: path) }
        return buffer.prefix(read).split(separator: 0).map { String(cString: Array($0) + [0]) }
    }

    static func exists(_ name: String, on path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, noFollow) >= 0
    }

    static func value(_ name: String, of path: String) throws -> [UInt8] {
        let length = getxattr(path, name, nil, 0, 0, noFollow)
        guard length >= 0 else { throw ReclaimError.posix(operation: "getxattr \(name)", code: errno, path: path) }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, noFollow)
        guard read >= 0 else { throw ReclaimError.posix(operation: "getxattr \(name)", code: errno, path: path) }
        return Array(buffer.prefix(read))
    }

    static func set(_ name: String, _ value: [UInt8], on path: String) throws {
        guard setxattr(path, name, value, value.count, 0, noFollow) == 0 else {
            throw ReclaimError.posix(operation: "setxattr \(name)", code: errno, path: path)
        }
    }

    static func remove(_ name: String, from path: String) throws {
        guard removexattr(path, name, noFollow) == 0 else {
            throw ReclaimError.posix(operation: "removexattr \(name)", code: errno, path: path)
        }
    }
}
