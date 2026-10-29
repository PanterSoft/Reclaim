import Foundation

public enum FileCategory: String, CaseIterable, Sendable {
    case images = "Images"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives & Disk Images"
    case developer = "Developer"
    case applications = "Applications"
    case other = "Other"

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        let groups: [(FileCategory, [String])] = [
            (.images, ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "webp", "svg", "ai"]),
            (.videos, ["mov", "mp4", "m4v", "avi", "mkv", "wmv", "webm", "mts", "m2ts", "braw", "r3d", "prores"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "ogg", "caf", "m4b"]),
            (.documents, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "csv", "epub", "odt"]),
            (.archives, ["zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "iso", "pkg", "sparseimage", "sparsebundle", "xip", "ipa"]),
            (.developer, ["swift", "c", "h", "m", "cpp", "js", "ts", "py", "rb", "go", "rs", "java", "class", "jar", "o", "a", "dylib", "so", "json", "xml", "yml", "yaml", "log", "sqlite", "db"]),
        ]
        for (category, extensions) in groups {
            for ext in extensions { map[ext] = category }
        }
        return map
    }()

    public static func classify(_ path: String) -> FileCategory {
        if path.contains(".app/") { return .applications }
        if path.contains("/node_modules/") || path.contains("/.git/") || path.contains("/DerivedData/") { return .developer }
        return byExtension[(path as NSString).pathExtension.lowercased()] ?? .other
    }
}

public struct StorageReport: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public let bytes: Int64
        public let fileCount: Int
    }

    public struct CategoryUsage: Sendable, Hashable, Identifiable {
        public var id: String { category.rawValue }
        public let category: FileCategory
        public let bytes: Int64
        public let fileCount: Int
    }

    public let roots: [String]
    public let fileCount: Int
    /// Bytes actually used on disk.
    public let allocatedBytes: Int64
    /// Sum of logical file sizes.
    public let logicalBytes: Int64
    /// Space already saved by transparent compression.
    public let compressionSavings: Int64
    /// Files stored only in iCloud / a cloud provider (they use no local space).
    public let cloudOnlyFiles: Int
    public let categories: [CategoryUsage]
    /// The immediate children of each root, largest first.
    public let folders: [Entry]
    public let largestFiles: [Entry]
    public let generatedAt: Date
}

public enum StorageAnalyzer {
    /// Measures everything under `roots`. Read-only.
    public static func analyze(roots: [URL], largestFileCount: Int = 100, progress: ProgressHandler? = nil) throws -> StorageReport {
        var fileCount = 0
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var compressionSavings: Int64 = 0
        var cloudOnly = 0
        var categories: [FileCategory: (bytes: Int64, count: Int)] = [:]
        var folders: [String: (bytes: Int64, count: Int)] = [:]
        var largest: [StorageReport.Entry] = []
        var throttle = Throttle()

        let normalizedRoots = FileWalker.normalized(roots)
        for root in normalizedRoots {
            let rootPath = root.path
            let base = rootPath == "/" ? "/" : rootPath + "/"
            try FileWalker.walk([root], options: ScanOptions()) { path, st in
                fileCount += 1
                allocated += st.allocatedSize
                logical += st.size
                if st.isDataless { cloudOnly += 1 }
                if st.isCompressed { compressionSavings += max(0, st.size - st.allocatedSize) }

                let category = FileCategory.classify(path)
                categories[category, default: (bytes: 0, count: 0)].bytes += st.allocatedSize
                categories[category, default: (bytes: 0, count: 0)].count += 1

                let relative = path.hasPrefix(base) ? path.dropFirst(base.count) : Substring(path)
                let child = base + (relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "")
                folders[child, default: (bytes: 0, count: 0)].bytes += st.allocatedSize
                folders[child, default: (bytes: 0, count: 0)].count += 1

                largest.append(.init(path: path, bytes: st.allocatedSize, fileCount: 1))
                if largest.count > largestFileCount * 4 {
                    largest.sort { $0.bytes > $1.bytes }
                    largest.removeLast(largest.count - largestFileCount)
                }

                if throttle.ready() {
                    progress?(ProgressUpdate(phase: "Measuring files", completed: fileCount, detail: path))
                }
            }
        }

        return StorageReport(
            roots: normalizedRoots.map(\.path),
            fileCount: fileCount,
            allocatedBytes: allocated,
            logicalBytes: logical,
            compressionSavings: compressionSavings,
            cloudOnlyFiles: cloudOnly,
            categories: categories
                .map { StorageReport.CategoryUsage(category: $0.key, bytes: $0.value.bytes, fileCount: $0.value.count) }
                .sorted { $0.bytes > $1.bytes },
            folders: folders
                .map { StorageReport.Entry(path: $0.key, bytes: $0.value.bytes, fileCount: $0.value.count) }
                .sorted { $0.bytes > $1.bytes },
            largestFiles: Array(largest.sorted { $0.bytes > $1.bytes }.prefix(largestFileCount)),
            generatedAt: Date()
        )
    }
}
