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
            // An explicitly chosen folder wins over the exclusions that contain it.
            let excluded = options.excludedPaths.filter { !(rootPath == $0 || rootPath.hasPrefix($0 + "/")) }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                visited += 1
                if visited % 512 == 0 { try Task.checkCancellation() }
                let path = url.path
                guard let st = FileStat.of(path) else { continue }
                if st.isDirectory {
                    if excluded.contains(path)
                        || options.excludedPackageExtensions.contains(url.pathExtension.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard st.isRegularFile, !SafeReplace.isTemporaryFile(url.lastPathComponent) else { continue }
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
