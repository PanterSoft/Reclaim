import Darwin
import XCTest
@testable import ReclaimCore

final class ReclaimCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("reclaim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // The temporary folder lives behind the /var → /private/var symlink.
        directory = FileWalker.canonical(temporary)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(_ name: String, _ data: Data, age: TimeInterval = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if age > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        return url
    }

    private func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        return Data(bytes)
    }

    private func compressibleData(_ count: Int) -> Data {
        let line = Data("The quick brown fox jumps over the lazy dog. 0123456789\n".utf8)
        var data = Data()
        while data.count < count { data.append(line) }
        return data.prefix(count)
    }

    private func xattr(_ url: URL, _ name: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
        return length < 0 ? nil : String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    private func setXattr(_ url: URL, _ name: String, _ value: String) {
        let bytes = Array(value.utf8)
        XCTAssertEqual(setxattr(url.path, name, bytes, bytes.count, 0, 0), 0)
    }

    // MARK: Duplicates

    func testClonesDuplicatesAndPreservesMetadata() throws {
        let contents = randomData(3 << 20)
        let keeper = try write("a.bin", contents)
        let duplicate = try write("sub/b.bin", contents)
        try write("c.bin", contents + Data([1])) // different size, not a duplicate
        setXattr(duplicate, "com.example.reclaim-test", "kept")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o640], ofItemAtPath: duplicate.path)
        let inodeBefore = try XCTUnwrap(FileStat.of(duplicate.path)).inode

        let groups = try DuplicateFinder.findDuplicates(in: [directory], options: ScanOptions(minimumFileSize: 1024))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.keeper.path, keeper.path)
        XCTAssertEqual(group.filesToReplace.map(\.path), [duplicate.path])
        XCTAssertGreaterThan(group.reclaimableBytes, 0)

        let report = CloneDeduplicator.deduplicate(groups)
        XCTAssertEqual(report.succeeded, 1)
        XCTAssertEqual(report.failures, [])

        let after = try XCTUnwrap(FileStat.of(duplicate.path))
        XCTAssertNotEqual(after.inode, inodeBefore, "the file should have been replaced by a clone")
        XCTAssertEqual(try Data(contentsOf: duplicate), contents)
        XCTAssertEqual(try Data(contentsOf: keeper), contents)
        XCTAssertEqual(xattr(duplicate, "com.example.reclaim-test"), "kept")
        XCTAssertNil(xattr(keeper, "com.example.reclaim-test"))
        XCTAssertEqual(after.permissions, 0o640)
        XCTAssertEqual(after.modificationTime.seconds, 1_000_000_000)

        // Clones share storage, so there is nothing left to gain.
        XCTAssertEqual(try DuplicateFinder.findDuplicates(in: [directory], options: ScanOptions(minimumFileSize: 1024)), [])

        // Editing one clone must not affect the other.
        try Data("changed".utf8).write(to: duplicate)
        XCTAssertEqual(try Data(contentsOf: keeper), contents)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: duplicate.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains(where: SafeReplace.isTemporaryFile), "temporary file left behind")
    }

    func testLeavesFilesThatChangedAfterScanning() throws {
        let contents = randomData(1 << 20)
        try write("a.bin", contents)
        let duplicate = try write("b.bin", contents)
        let groups = try DuplicateFinder.findDuplicates(in: [directory], options: ScanOptions(minimumFileSize: 1024))
        XCTAssertEqual(groups.count, 1)

        var modified = contents
        modified[0] ^= 0xFF
        try modified.write(to: duplicate)

        let report = CloneDeduplicator.deduplicate(groups)
        XCTAssertEqual(report.succeeded, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: duplicate), modified)
    }

    func testIgnoresHardLinksAndSmallFiles() throws {
        let contents = randomData(2 << 20)
        let original = try write("a.bin", contents)
        try FileManager.default.linkItem(at: original, to: directory.appendingPathComponent("hardlink.bin"))
        try write("small1.txt", Data("same".utf8))
        try write("small2.txt", Data("same".utf8))
        let groups = try DuplicateFinder.findDuplicates(in: [directory], options: ScanOptions(minimumFileSize: 1024))
        XCTAssertEqual(groups, [])
    }

    // MARK: Compression

    func testCompressionRoundTrip() throws {
        let contents = compressibleData(2 << 20)
        let file = try write("notes.log", contents, age: 3 * 86_400)
        try write("recent.log", contents) // too recently modified
        try write("random.bin", randomData(1 << 20), age: 3 * 86_400) // incompressible

        let candidates = try TransparentCompression.findCandidates(in: [directory], options: ScanOptions(minimumFileSize: 4096))
        XCTAssertEqual(candidates.map(\.path), [file.path])

        let before = try XCTUnwrap(FileStat.of(file.path))
        // Call the single-file API directly so a skip reports its reason.
        XCTAssertNoThrow(try TransparentCompression.compress(file.path, expected: before))
        let compressed = try XCTUnwrap(FileStat.of(file.path))
        XCTAssertTrue(compressed.isCompressed)
        XCTAssertLessThan(compressed.allocatedSize, before.allocatedSize)
        XCTAssertEqual(compressed.size, before.size)
        XCTAssertEqual(compressed.modificationTime, before.modificationTime)
        XCTAssertEqual(try Data(contentsOf: file), contents)

        try TransparentCompression.decompress(file.path)
        let restored = try XCTUnwrap(FileStat.of(file.path))
        XCTAssertFalse(restored.isCompressed)
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testDecompressFolderRestoresEveryFile() throws {
        let contents = compressibleData(256 << 10)
        let files = try ["a.log", "sub/b.log"].map { try write($0, contents, age: 3 * 86_400) }
        for file in files { try TransparentCompression.compress(file.path, expected: XCTUnwrap(FileStat.of(file.path))) }

        let report = try TransparentCompression.decompress([directory])
        XCTAssertEqual(report.succeeded, 2)
        XCTAssertEqual(report.failures, [])
        XCTAssertLessThan(report.bytesReclaimed, 0, "decompressing uses more space")
        for file in files {
            XCTAssertFalse(try XCTUnwrap(FileStat.of(file.path)).isCompressed)
            XCTAssertEqual(try Data(contentsOf: file), contents)
        }
        XCTAssertEqual(try TransparentCompression.decompress([directory]).succeeded, 0)
    }

    func testCompressionLeavesFilesThatChangedAfterScanning() throws {
        let file = try write("notes.log", compressibleData(1 << 20), age: 3 * 86_400)
        let candidates = try TransparentCompression.findCandidates(in: [directory], options: ScanOptions())
        XCTAssertEqual(candidates.count, 1)
        try compressibleData(1 << 20).dropFirst().write(to: file)

        let report = TransparentCompression.compress(candidates)
        XCTAssertEqual(report.succeeded, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(try XCTUnwrap(FileStat.of(file.path)).isCompressed)
    }

    // MARK: Walking

    func testWalkerSkipsExcludedFoldersPackagesAndTemporaryFiles() throws {
        try write("keep.txt", Data("x".utf8))
        try write("Excluded/skip.txt", Data("x".utf8))
        try write("My.photoslibrary/skip.jpg", Data("x".utf8))
        try write("Tool.app/Contents/skip", Data("x".utf8))
        try write(".reclaim-\(UUID().uuidString).tmp", Data("x".utf8))
        let options = ScanOptions(
            excludedPaths: [directory.appendingPathComponent("Excluded").path],
            excludedPackageExtensions: ["photoslibrary", "app"]
        )
        var seen: [String] = []
        try FileWalker.walk([directory], options: options) { path, _ in seen.append(path) }
        XCTAssertEqual(seen, [directory.appendingPathComponent("keep.txt").path])

        // A folder chosen explicitly wins over the exclusion that names it.
        seen = []
        try FileWalker.walk([directory.appendingPathComponent("Excluded")], options: options) { path, _ in seen.append(path) }
        XCTAssertEqual(seen.count, 1)
    }

    func testConservativeOptionsProtectLibraryAndApps() {
        let home = FileWalker.canonical(FileManager.default.homeDirectoryForCurrentUser).path
        let options = ScanOptions.conservative(minimumFileSize: 1)
        XCTAssertTrue(options.excludedPaths.contains(home + "/Library"))
        XCTAssertTrue(options.excludedPackageExtensions.contains("app"))
        XCTAssertTrue(options.excludedPackageExtensions.contains("photoslibrary"))
        XCTAssertFalse(ScanOptions.conservative(minimumFileSize: 1, includeApplicationBundles: true).excludedPackageExtensions.contains("app"))
    }

    func testTemporaryFileNames() {
        let temporary = SafeReplace.temporaryPath(besides: "/a/b/file.txt")
        XCTAssertTrue(temporary.hasPrefix("/a/b/"))
        XCTAssertTrue(SafeReplace.isTemporaryFile((temporary as NSString).lastPathComponent))
        XCTAssertFalse(SafeReplace.isTemporaryFile("file.txt"))
        XCTAssertFalse(SafeReplace.isTemporaryFile(".reclaim-notes.txt"))
    }

    // MARK: Analysis

    func testAnalyzerMeasuresFolders() throws {
        try write("Photos/one.jpg", randomData(200_000))
        try write("Photos/two.jpg", randomData(100_000))
        try write("Code/main.swift", compressibleData(10_000))

        let report = try StorageAnalyzer.analyze(roots: [directory])
        XCTAssertEqual(report.fileCount, 3)
        XCTAssertEqual(report.logicalBytes, 310_000)
        XCTAssertEqual(report.folders.first?.path, directory.appendingPathComponent("Photos").path)
        XCTAssertEqual(report.folders.first?.fileCount, 2)
        XCTAssertEqual(report.categories.first?.category, .images)
        XCTAssertEqual(report.largestFiles.first?.path, directory.appendingPathComponent("Photos/one.jpg").path)
    }

    func testOverlappingRootsAreScannedOnce() {
        let nested = directory.appendingPathComponent("inner")
        XCTAssertEqual(FileWalker.normalized([nested, directory, directory]).map(\.path), [directory.path])
    }

    func testClassifiesFiles() {
        XCTAssertEqual(FileCategory.classify("/x/Photo.JPG"), .images)
        XCTAssertEqual(FileCategory.classify("/x/clip.mov"), .videos)
        XCTAssertEqual(FileCategory.classify("/Applications/Foo.app/Contents/Info.plist"), .applications)
        XCTAssertEqual(FileCategory.classify("/x/node_modules/pkg/readme.md"), .developer)
        XCTAssertEqual(FileCategory.classify("/x/no-extension"), .other)
    }

    // MARK: Command line

    func testParsesCommandLine() throws {
        let invocation = try XCTUnwrap(Invocation.parse(["compress", "--apply", "--min-size", "512K", "--include-apps", "/a", "/b"]))
        XCTAssertEqual(invocation.command, "compress")
        XCTAssertTrue(invocation.apply)
        XCTAssertTrue(invocation.includeApps)
        XCTAssertEqual(invocation.minimumSize, 512 << 10)
        XCTAssertEqual(invocation.roots.map(\.path), ["/a", "/b"])

        let defaults = try XCTUnwrap(Invocation.parse(["analyze"]))
        XCTAssertFalse(defaults.apply)
        XCTAssertNil(defaults.minimumSize)
        XCTAssertEqual(defaults.roots, [FileManager.default.homeDirectoryForCurrentUser])

        XCTAssertNil(try Invocation.parse([]))
        XCTAssertNil(try Invocation.parse(["duplicates", "--help"]))
        XCTAssertNil(try Invocation.parse(["--help"]))
        XCTAssertThrowsError(try Invocation.parse(["analyze", "--bogus"]))
        XCTAssertThrowsError(try Invocation.parse(["compress", "--min-size"]))
        XCTAssertThrowsError(try Invocation.parse(["compress", "--min-size", "lots"]))
    }

    func testParsesSizes() {
        let cases: [String: Int64?] = [
            "0": 0, "4096": 4096, "512k": 512 << 10, "10M": 10 << 20, "1.5G": 3 << 29, "2g": 2 << 30,
            "": nil, "M": nil, "abc": nil, "-1": nil, "-1M": nil, "INFK": nil, "NANM": nil, "1e30G": nil,
        ]
        for (text, expected) in cases { XCTAssertEqual(Invocation.parseSize(text), expected, text) }
    }

    // MARK: App support

    func testLogEntryRoundTrip() throws {
        let entry = LogEntry(date: Date(timeIntervalSince1970: 1_700_000_000), level: .warning, message: "two\nlines\twith tab")
        XCTAssertTrue(entry.line.hasSuffix("\n"))
        XCTAssertEqual(entry.line.filter { $0 == "\n" }.count, 1, "a message must stay on one line")
        let parsed = try XCTUnwrap(LogEntry(line: Substring(entry.line.dropLast())))
        XCTAssertEqual(parsed.date, entry.date)
        XCTAssertEqual(parsed.level, .warning)
        XCTAssertEqual(parsed.message, "two lines\twith tab")
    }

    func testLogParsingSkipsBadLinesAndKeepsNewestFirst() {
        let lines = (0..<5).map { LogEntry(date: Date(timeIntervalSince1970: Double($0) * 60), level: .info, message: "m\($0)").line }
        let text = lines.joined() + "garbage\nnot-a-date\tinfo\tx\n2024-01-01T00:00:00Z\tloud\tx\n"
        XCTAssertEqual(LogEntry.parse(text).map(\.message), ["m4", "m3", "m2", "m1", "m0"])
        XCTAssertEqual(LogEntry.parse(lines.joined(), limit: 2).map(\.message), ["m4", "m3"])
        XCTAssertEqual(LogEntry.parse(""), [])
    }

    func testOperationSummary() {
        var report = OperationReport()
        XCTAssertEqual(report.summary(verb: "Cloned"), "Cloned 0 file(s).")
        report.succeeded = 3
        report.skipped = 1
        report.bytesReclaimed = 2048
        XCTAssertEqual(report.summary(verb: "Compressed"),
                       "Compressed 3 file(s), freeing about \(Int64(2048).formattedBytes); 1 skipped (would not shrink enough).")
        report.bytesReclaimed = -2048 // decompressing never claims to free space
        report.skipped = 0
        XCTAssertEqual(report.summary(verb: "Decompressed"), "Decompressed 3 file(s).")
    }

    func testUpdateVersionComparison() {
        XCTAssertEqual(UpdateCheck.newerVersion(latest: "v1.10.0", current: "1.9.2"), "1.10.0")
        XCTAssertEqual(UpdateCheck.newerVersion(latest: "0.2.0", current: "0.1.0"), "0.2.0")
        XCTAssertNil(UpdateCheck.newerVersion(latest: "v1.2.0", current: "1.2.0"))
        XCTAssertNil(UpdateCheck.newerVersion(latest: "v1.1.9", current: "1.2.0"))
    }

    func testProgressSummary() {
        XCTAssertEqual(ProgressUpdate(phase: "Compressing", completed: 3, total: 5).summary, "Compressing: 3 of 5")
        XCTAssertEqual(ProgressUpdate(phase: "Measuring", completed: 7).summary, "Measuring: 7")
    }
}
