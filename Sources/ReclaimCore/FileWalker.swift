import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Directories that are never entered (unless one of them is itself a scan root).
    public var excludedPaths: Set<String>
    /// Bundles with these extensions are never entered (e.g. Photos libraries).
    public var excludedPackageExtensions: Set<String>
    public var minimumFileSize: Int64

    public init(excludedPaths: Set<String> = [], excludedPackageExtensions: Set<String> = [], minimumFileSize: Int64 = 0) {
        self.excludedPaths = excludedPaths
        self.excludedPackageExtensions = excludedPackageExtensions
        self.minimumFileSize = minimumFileSize
    }

    /// Libraries managed by an app's own database. Rewriting files inside them is
    /// harmless to their contents, but we leave them to their apps.
    public static let managedLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "lrlibrary",
        // Virtual machines: a running VM keeps its disk open, and a swapped file would lose its writes.
        "pvm", "vmwarevm", "utm",
    ]

    /// Defaults used before modifying anything: skips ~/Library (app data, iCloud Drive,
    /// cloud storage providers), the Trash, system locations and app-managed libraries.
    public static func conservative(minimumFileSize: Int64, includeApplicationBundles: Bool = false) -> ScanOptions {
        let home = FileWalker.canonical(FileManager.default.homeDirectoryForCurrentUser).path
        var packages = managedLibraryExtensions
        if !includeApplicationBundles { packages.insert("app") }
        return ScanOptions(
            excludedPaths: [
                home + "/Library", home + "/.Trash",
                "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores", "/dev",
                "/Applications", "/opt", "/Volumes",
            ],
            excludedPackageExtensions: packages,
            minimumFileSize: minimumFileSize
        )
    }
}

public enum FileWalker {
    /// Calls `visit` for every regular file under `roots`, without following symlinks.
    public static func walk(_ roots: [URL], options: ScanOptions, visit: (String, FileStat) throws -> Void) throws {
        var visited = 0
        for root in normalized(roots) {
            try Task.checkCancellation()
            let rootPath = root.path
            guard let rootStat = FileStat.of(rootPath) else { continue }
            if rootStat.isRegularFile {
                try visit(rootPath, rootStat)
                continue
            }
            // The system and data volumes are joined by firmlinks (/Users lives on the data volume).
            let bootDevices = Set(["/", "/System/Volumes/Data"].compactMap { FileStat.of($0)?.device })
            let devices = bootDevices.contains(rootStat.device) ? bootDevices : [rootStat.device]
            // An explicitly chosen folder wins over the exclusions that contain it.
            let excluded = options.excludedPaths.filter { !(rootPath == $0 || rootPath.hasPrefix($0 + "/")) }
            // fts hands back each entry's lstat result, so no file is stat'ed twice.
            var rootCString = Array(rootPath.utf8CString)
            let handle: UnsafeMutablePointer<FTS>? = rootCString.withUnsafeMutableBufferPointer { buffer in
                var argv: [UnsafeMutablePointer<CChar>?] = [buffer.baseAddress, nil]
                return fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil)
            }
            guard let handle else { continue }
            defer { fts_close(handle) }

            while let entry = fts_read(handle)?.pointee {
                visited += 1
                if visited % 512 == 0 { try Task.checkCancellation() }
                guard entry.fts_level > 0, Int32(entry.fts_info) != FTS_DP, let statp = entry.fts_statp else { continue }
                let path = String(cString: entry.fts_path)
                let st = FileStat(statp.pointee)
                if st.isDirectory {
                    // Stay on the root's volume (network shares, device mounts can block), and don't
                    // list cloud-only folders: that makes iCloud/Drive/Nextcloud download the listing.
                    if !devices.contains(st.device) || st.isDataless || excluded.contains(path)
                        || options.excludedPackageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                        fts_set(handle, UnsafeMutablePointer(mutating: handle.pointee.fts_cur), FTS_SKIP)
                    }
                    continue
                }
                guard st.isRegularFile, !SafeReplace.isTemporaryFile((path as NSString).lastPathComponent) else { continue }
                try visit(path, st)
            }
        }
    }

    /// The real path of `url`, with every symlink resolved (e.g. /var/x → /private/var/x).
    /// Unlike `URL.resolvingSymlinksInPath()`, this never strips a leading /private, so it
    /// matches the paths the directory enumerator reports.
    public static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard let resolved = realpath(standardized.path, nil) else { return standardized }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Resolves symlinks and drops roots nested inside other roots so nothing is visited twice.
    static func normalized(_ roots: [URL]) -> [URL] {
        let resolved = roots.map(canonical)
        let paths = Set(resolved.map(\.path))
        var seen = Set<String>()
        return resolved.filter { url in
            let path = url.path
            let nested = paths.contains { other in other != path && path.hasPrefix(other == "/" ? "/" : other + "/") }
            return !nested && seen.insert(path).inserted
        }
    }
}
