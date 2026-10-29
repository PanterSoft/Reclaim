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
}
