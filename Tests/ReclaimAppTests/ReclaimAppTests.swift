import AppKit
import SwiftUI
import XCTest
@testable import ReclaimApp
@testable import ReclaimCore

@MainActor
final class ReclaimAppTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        _ = NSApplication.shared // SwiftUI hosting needs an app object, which xctest does not create
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("reclaim-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        directory = FileWalker.canonical(temporary)
        suiteName = "reclaim-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set([directory.path], forKey: "locations")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private var logFile: URL { directory.appendingPathComponent("Logs/activity.log") }

    private func makeModel() -> AppModel {
        let model = AppModel(defaults: defaults, logFile: logFile, automatic: false)
        model.minimumDuplicateSizeMB = 0.5
        model.minimumCompressionSizeKB = 4
        model.canRunInBackground = { true }
        model.currentVersion = "1.0.0"
        return model
    }

    @discardableResult
    private func write(_ name: String, _ data: Data, age: TimeInterval = 0) throws -> URL {
        let url = directory.appendingPathComponent("Files/" + name)
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
        Data(String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: count / 45 + 1).utf8.prefix(count))
    }

    /// Waits for the model's current background job to finish.
    private func idle(_ model: AppModel, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isBusy {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(model.busyTitle ?? "")") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Settings

    func testSettingsPersistAcrossLaunches() {
        let model = makeModel()
        model.includeAppBundles = true
        model.checksForUpdates = false
        model.locations.append(URL(fileURLWithPath: "/tmp"))

        let relaunched = AppModel(defaults: defaults, logFile: logFile, automatic: false)
        XCTAssertTrue(relaunched.includeAppBundles)
        XCTAssertFalse(relaunched.checksForUpdates)
        XCTAssertEqual(relaunched.minimumDuplicateSizeMB, 0.5)
        XCTAssertEqual(relaunched.minimumCompressionSizeKB, 4)
        XCTAssertEqual(relaunched.locations.map(\.path), [directory.path, "/tmp"])
    }

    func testFreshInstallDefaults() throws {
        let fresh = try XCTUnwrap(UserDefaults(suiteName: suiteName + "-fresh"))
        defer { fresh.removePersistentDomain(forName: suiteName + "-fresh") }
        let model = AppModel(defaults: fresh, logFile: logFile, automatic: false)
        XCTAssertEqual(model.locations.map(\.path), [NSHomeDirectory()])
        XCTAssertFalse(model.runInBackground)
        XCTAssertTrue(model.checksForUpdates)
        XCTAssertEqual(model.minimumDuplicateSizeMB, 1)
        XCTAssertEqual(model.minimumCompressionSizeKB, 64)
        XCTAssertEqual(model.log, [])
        XCTAssertNotNil(model.volume)
    }

    func testRemovingALocationClearsResults() async throws {
        try write("a.txt", Data("x".utf8))
        let model = makeModel()
        model.analyze()
        try await idle(model)
        XCTAssertNotNil(model.report)
        model.removeLocation(directory)
        XCTAssertEqual(model.locations, [])
        XCTAssertNil(model.report)
    }

    // MARK: Actions

    func testAnalyzeRecordsReportAndLog() async throws {
        try write("a.bin", randomData(10_000))
        let model = makeModel()
        model.analyze()
        XCTAssertTrue(model.isBusy)
        model.analyze() // ignored while busy
        try await idle(model)
        XCTAssertEqual(model.report?.fileCount, 1)
        XCTAssertEqual(model.log.count, 1)
        XCTAssertEqual(model.log.first?.level, .info)

        // The log survives a relaunch.
        let relaunched = AppModel(defaults: defaults, logFile: logFile, automatic: false)
        XCTAssertEqual(relaunched.log.map(\.message), model.log.map(\.message))
    }

    func testFindAndCloneDuplicates() async throws {
        let contents = randomData(1 << 20)
        try write("a.bin", contents)
        try write("b.bin", contents)
        try write("c.bin", contents)
        let model = makeModel()

        model.findDuplicates()
        try await idle(model)
        let groups = try XCTUnwrap(model.duplicateGroups)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(model.selectedGroups, Set(groups.map(\.id)), "everything is selected after a scan")

        model.cloneSelectedDuplicates()
        try await idle(model)
        XCTAssertEqual(model.duplicateGroups, [])
        XCTAssertEqual(model.selectedGroups, [])
        XCTAssertEqual(model.log.first?.level, .success)
        XCTAssertTrue(model.log.first?.message.hasPrefix("Cloned 2 file(s)") == true, model.log.first?.message ?? "")
    }

    func testCloneWithNothingSelectedDoesNothing() async throws {
        let contents = randomData(1 << 20)
        try write("a.bin", contents)
        try write("b.bin", contents)
        let model = makeModel()
        model.findDuplicates()
        try await idle(model)
        model.selectedGroups = []
        model.cloneSelectedDuplicates()
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.duplicateGroups?.count, 1)
    }

    func testFindAndCompressOnlySelectedFiles() async throws {
        let first = try write("one.log", compressibleData(200_000), age: 3 * 86_400)
        let second = try write("two.log", compressibleData(100_000), age: 3 * 86_400)
        let model = makeModel()

        model.findCompressible()
        try await idle(model)
        XCTAssertEqual(model.candidates?.count, 2)
        model.selectedCandidates = [first.path]

        model.compressSelected()
        try await idle(model)
        XCTAssertEqual(model.candidates?.map(\.path), [second.path], "the unselected file stays listed")
        XCTAssertEqual(model.selectedCandidates, [])
        XCTAssertTrue(try XCTUnwrap(FileStat.of(first.path)).isCompressed)
        XCTAssertFalse(try XCTUnwrap(FileStat.of(second.path)).isCompressed)
        XCTAssertEqual(model.log.first?.level, .success)
    }

    func testFailuresAreLoggedAsErrors() async throws {
        let file = try write("one.log", compressibleData(200_000), age: 3 * 86_400)
        let model = makeModel()
        model.findCompressible()
        try await idle(model)
        try compressibleData(150_000).write(to: file) // changes after the scan

        model.compressSelected()
        try await idle(model)
        XCTAssertEqual(model.log.prefix(2).map(\.level), [.error, .warning])
        XCTAssertFalse(try XCTUnwrap(FileStat.of(file.path)).isCompressed)
    }

    func testCancelLogsAWarning() async throws {
        for index in 0..<200 { try write("\(index).bin", randomData(1000)) }
        let model = makeModel()
        model.analyze()
        model.cancel()
        try await idle(model)
        // A small folder may finish before the cancel lands; either outcome must leave the model idle.
        if model.report == nil {
            XCTAssertEqual(model.log.first?.level, .warning)
            XCTAssertTrue(model.log.first?.message.contains("cancelled") == true)
        }
        XCTAssertNil(model.progress)
    }

    // MARK: Background

    func testDailyCompressionRunsOnlyWhenDue() async throws {
        let file = try write("one.log", compressibleData(200_000), age: 3 * 86_400)
        defaults.set(true, forKey: AppModel.runInBackgroundKey) // set before launch, so no login item is registered
        let model = makeModel()

        model.canRunInBackground = { false } // on battery
        model.compressNewFilesIfDue()
        XCTAssertFalse(model.isBusy)

        model.canRunInBackground = { true }
        model.compressNewFilesIfDue()
        try await idle(model)
        XCTAssertTrue(try XCTUnwrap(FileStat.of(file.path)).isCompressed)
        let lastRun = try XCTUnwrap(model.lastBackgroundRun)
        XCTAssertEqual(model.lastBackgroundResult?.hasPrefix("Compressed 1 file(s)"), true)

        model.compressNewFilesIfDue() // ran less than a day ago
        XCTAssertFalse(model.isBusy)

        let relaunched = AppModel(defaults: defaults, logFile: logFile, automatic: false)
        XCTAssertEqual(relaunched.lastBackgroundRun, lastRun)
        XCTAssertEqual(relaunched.lastBackgroundResult, model.lastBackgroundResult)
    }

    func testDailyCompressionIsOffByDefault() {
        let model = makeModel()
        model.compressNewFilesIfDue()
        XCTAssertFalse(model.isBusy)
    }

    // MARK: Updates

    private func respond(status: Int, tag: String) -> @Sendable (URL) async throws -> (Data, URLResponse) {
        { url in
            let body = Data(#"{"tag_name":"\#(tag)","html_url":"https://example.com/release"}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testFindsANewerRelease() async {
        let model = makeModel()
        model.fetch = respond(status: 200, tag: "v1.2.0")
        await model.checkForUpdates()
        XCTAssertEqual(model.availableUpdate?.version, "1.2.0")
        XCTAssertEqual(model.availableUpdate?.page.absoluteString, "https://example.com/release")
        XCTAssertNotNil(defaults.object(forKey: "lastUpdateCheck"))

        model.fetch = respond(status: 200, tag: "v1.0.0")
        await model.checkForUpdates()
        XCTAssertNil(model.availableUpdate)
    }

    func testIgnoresBadUpdateResponses() async {
        let model = makeModel()
        model.fetch = respond(status: 404, tag: "v9.0.0")
        await model.checkForUpdates()
        XCTAssertNil(model.availableUpdate)

        model.fetch = { _ in throw URLError(.notConnectedToInternet) }
        await model.checkForUpdates()
        XCTAssertNil(model.availableUpdate)

        model.currentVersion = nil // `swift run`: nothing to compare against
        model.fetch = respond(status: 200, tag: "v9.0.0")
        await model.checkForUpdates()
        XCTAssertNil(model.availableUpdate)
    }

    func testUpdateCheckRunsAtMostDailyAndCanBeTurnedOff() async {
        let model = makeModel()
        model.fetch = respond(status: 200, tag: "v2.0.0")
        model.checksForUpdates = false
        await model.checkForUpdatesIfDue()
        XCTAssertNil(model.availableUpdate)

        model.checksForUpdates = true
        defaults.set(Date(), forKey: "lastUpdateCheck")
        await model.checkForUpdatesIfDue()
        XCTAssertNil(model.availableUpdate, "checked less than a day ago")

        defaults.set(Date().addingTimeInterval(-2 * 86_400), forKey: "lastUpdateCheck")
        await model.checkForUpdatesIfDue()
        XCTAssertEqual(model.availableUpdate?.version, "2.0.0")
    }

    // MARK: UI

    /// Lays out and draws `view` in a window. Set RECLAIM_SNAPSHOTS to a folder to also save PNGs.
    private func render<V: View>(_ name: String, _ view: V, model: AppModel, size: CGSize = CGSize(width: 920, height: 620)) throws {
        let host = NSHostingView(rootView: view.environmentObject(model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; the default would release it twice
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), name)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
        if let folder = ProcessInfo.processInfo.environment["RECLAIM_SNAPSHOTS"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        window.close()
    }

    private func renderEveryPage(_ model: AppModel, suffix: String) throws {
        try render("content-\(suffix)", ContentView(), model: model)
        try render("overview-\(suffix)", OverviewView(selection: .constant(.overview)), model: model)
        try render("storage-\(suffix)", AnalyzeView(), model: model)
        try render("duplicates-\(suffix)", DuplicatesView(), model: model)
        try render("compression-\(suffix)", CompressionView(), model: model)
        try render("activity-\(suffix)", ActivityView(), model: model)
        try render("settings-\(suffix)", SettingsView(), model: model, size: CGSize(width: 460, height: 560))
        try render("menu-\(suffix)", VStack { MenuBarMenu() }, model: model, size: CGSize(width: 300, height: 300))
        try render("status-\(suffix)", StatusBar(), model: model, size: CGSize(width: 600, height: 60))
    }

    func testEveryScreenRendersEmpty() throws {
        try renderEveryPage(makeModel(), suffix: "empty")
    }

    func testEveryScreenRendersWithResults() async throws {
        let contents = randomData(1 << 20)
        try write("a.bin", contents)
        try write("b.bin", contents)
        try write("one.log", compressibleData(200_000), age: 3 * 86_400)
        let model = makeModel()
        model.analyze()
        try await idle(model)
        model.findDuplicates()
        try await idle(model)
        model.findCompressible()
        try await idle(model)
        XCTAssertEqual(model.duplicateGroups?.count, 1)
        XCTAssertEqual(model.candidates?.count, 1)
        try renderEveryPage(model, suffix: "results")

        // Scans that found nothing show their own empty state.
        model.selectedGroups = Set(model.duplicateGroups!.map(\.id))
        model.cloneSelectedDuplicates()
        try await idle(model)
        model.compressSelected()
        try await idle(model)
        XCTAssertEqual(model.duplicateGroups, [])
        XCTAssertEqual(model.candidates, [])
        try renderEveryPage(model, suffix: "done")
    }

    func testScreensRenderWhileBusy() throws {
        for index in 0..<300 { try write("\(index).bin", randomData(1000)) }
        let model = makeModel()
        model.analyze()
        XCTAssertTrue(model.isBusy)
        try renderEveryPage(model, suffix: "busy")
        model.cancel()
    }

    func testSidebarSymbolsExist() {
        for item in SidebarItem.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil), item.rawValue)
        }
        XCTAssertEqual(Set(SidebarItem.allCases.map(\.id)).count, SidebarItem.allCases.count)
    }
}
