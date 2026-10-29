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

    /// Copies the original's metadata onto the replacement. When `extendedAttributes` is true
    /// the replacement's own xattrs and ACL are discarded and the original's copied over
    /// (needed for clones, which inherit the metadata of the file they were cloned from).
    static func copyMetadata(from original: String, stat: FileStat, to replacement: String, extendedAttributes: Bool) throws {
        func check(_ result: Int32, _ operation: String) throws {
            if result != 0 { throw ReclaimError.posix(operation: operation, code: errno, path: original) }
        }

        if extendedAttributes {
            // Make sure we can write attributes even if the clone source was read-only.
            try check(chmod(replacement, 0o600), "chmod")
            if let empty = acl_init(0) {
                _ = acl_set_file(replacement, ACL_TYPE_EXTENDED, empty)
                acl_free(UnsafeMutableRawPointer(empty))
            }
            try removeExtendedAttributes(replacement)
            try check(copyfile(original, replacement, nil, copyfile_flags_t(1 << 2)), "copy extended attributes") // COPYFILE_XATTR
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

        if extendedAttributes {
            try check(copyfile(original, replacement, nil, copyfile_flags_t(1 << 0)), "copy ACL") // COPYFILE_ACL
        }
    }

    private static func removeExtendedAttributes(_ path: String) throws {
        let noFollow: Int32 = 0x0001 // XATTR_NOFOLLOW
        let length = listxattr(path, nil, 0, noFollow)
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        let read = listxattr(path, &names, length, noFollow)
        guard read > 0 else { return }
        for name in names.prefix(read).split(separator: 0) {
            let cName = Array(name) + [0]
            guard removexattr(path, cName, noFollow) == 0 else {
                throw ReclaimError.posix(operation: "removexattr", code: errno, path: path)
            }
        }
    }
}

/// Runs /usr/bin/ditto, Apple's copy tool that knows how to write transparently compressed files.
enum Ditto {
    static func copy(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ReclaimError.toolFailed("ditto failed: \(message)")
        }
    }
}
