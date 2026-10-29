import AppKit
import Foundation
import IOKit.ps
import ReclaimCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    // Saved so the background run uses the same settings after a restart.
    @Published var locations: [URL] {
        didSet { defaults.set(locations.map(\.path), forKey: "locations") }
    }
    @Published var includeAppBundles: Bool {
        didSet { defaults.set(includeAppBundles, forKey: "includeAppBundles") }
    }
    @Published var minimumDuplicateSizeMB: Double {
        didSet { defaults.set(minimumDuplicateSizeMB, forKey: "minimumDuplicateSizeMB") }
    }
    @Published var minimumCompressionSizeKB: Double {
        didSet { defaults.set(minimumCompressionSizeKB, forKey: "minimumCompressionSizeKB") }
    }
    /// Keep running in the menu bar, start at login and compress new files once a day.
    @Published var runInBackground: Bool {
        didSet {
            guard runInBackground != oldValue else { return }
            defaults.set(runInBackground, forKey: Self.runInBackgroundKey)
            updateLoginAgent()
        }
    }
    @Published private(set) var lastBackgroundRun: Date?
    @Published private(set) var lastBackgroundResult: String?
    @Published var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: "checksForUpdates") }
    }
    /// A newer release on GitHub, if there is one.
    @Published private(set) var availableUpdate: (version: String, page: URL)?

    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var report: StorageReport?
    @Published private(set) var duplicateGroups: [DuplicateGroup]?
    @Published var selectedGroups: Set<DuplicateGroup.ID> = []
    @Published private(set) var candidates: [CompressionCandidate]?
    @Published var selectedCandidates: Set<CompressionCandidate.ID> = []

    @Published private(set) var busyTitle: String?
    @Published private(set) var progress: ProgressUpdate?
    @Published private(set) var log: [LogEntry]

    /// The Activity log, kept across launches so background runs can be reviewed later.
    // ponytail: grows without bound (a line per action, a few KB a month); trim it if that ever matters.
    nonisolated static let defaultLogFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Reclaim/activity.log")

    // Seams for tests; the defaults are what the app uses.
    let defaults: UserDefaults
    let logFile: URL
    /// The daily run only starts on power and outside Low Power Mode.
    var canRunInBackground: () -> Bool = {
        IOPSCopyExternalPowerAdapterDetails() != nil && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    var fetch: @Sendable (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) }
    /// `swift run` has no Info.plist and so no version to compare.
    var currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    private var cancelCurrent: (() -> Void)?
    private var scheduler: Timer?

    nonisolated static let runInBackgroundKey = "runInBackground"
    /// Starts `Reclaim --background` at login; the plist ships in Contents/Library/LaunchAgents.
    private static let loginAgent = SMAppService.agent(plistName: "io.github.reclaim.Reclaim.background.plist")

    var isBusy: Bool { busyTitle != nil }

    /// `automatic` starts the hourly background/update checks; tests turn it off.
    init(defaults: UserDefaults = .standard, logFile: URL = AppModel.defaultLogFile, automatic: Bool = true) {
        self.defaults = defaults
        self.logFile = logFile
        locations = (defaults.stringArray(forKey: "locations") ?? [NSHomeDirectory()]).map { URL(fileURLWithPath: $0) }
        includeAppBundles = defaults.bool(forKey: "includeAppBundles")
        minimumDuplicateSizeMB = defaults.object(forKey: "minimumDuplicateSizeMB") as? Double ?? 1.0
        minimumCompressionSizeKB = defaults.object(forKey: "minimumCompressionSizeKB") as? Double ?? 64.0
        runInBackground = defaults.bool(forKey: Self.runInBackgroundKey)
        lastBackgroundRun = defaults.object(forKey: "lastBackgroundRun") as? Date
        lastBackgroundResult = defaults.string(forKey: "lastBackgroundResult")
        checksForUpdates = defaults.object(forKey: "checksForUpdates") as? Bool ?? true
        log = (try? String(contentsOf: logFile, encoding: .utf8)).map { LogEntry.parse($0) } ?? []
        refreshVolume()
        guard automatic else { return }
        // ponytail: hourly check for a daily run; FSEvents if new files should be picked up sooner.
        scheduler = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.compressNewFilesIfDue()
                await self?.checkForUpdatesIfDue()
            }
        }
        compressNewFilesIfDue()
        Task { await checkForUpdatesIfDue() }
        // Removing the menu bar icon (⌘-drag) writes the setting directly; follow it.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let stored = self.defaults.bool(forKey: Self.runInBackgroundKey)
                if stored != self.runInBackground { self.runInBackground = stored }
            }
        }
    }

    // MARK: Locations

    func addLocations() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !locations.contains(url) { locations.append(url) }
        invalidateResults()
    }

    func removeLocation(_ url: URL) {
        locations.removeAll { $0 == url }
        invalidateResults()
    }

    func invalidateResults() {
        report = nil
        duplicateGroups = nil
        candidates = nil
    }

    func refreshVolume() {
        volume = VolumeInfo(for: locations.first ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    private func scanOptions(minimumFileSize: Int64) -> ScanOptions {
        .conservative(minimumFileSize: minimumFileSize, includeApplicationBundles: includeAppBundles)
    }

    // MARK: Actions

    func analyze() {
        let roots = locations
        perform("Analyzing storage", work: { progress in
            try StorageAnalyzer.analyze(roots: roots, progress: progress)
        }, completion: { report in
            self.report = report
            self.record(.info, "Analyzed \(report.fileCount.formatted()) files using \(report.allocatedBytes.formattedBytes).")
        })
    }

    func findDuplicates() {
        let roots = locations
        let options = scanOptions(minimumFileSize: Int64(minimumDuplicateSizeMB * 1_048_576))
        perform("Finding duplicates", work: { progress in
            try DuplicateFinder.findDuplicates(in: roots, options: options, progress: progress)
        }, completion: { groups in
            self.duplicateGroups = groups
            self.selectedGroups = Set(groups.map(\.id))
            let total = groups.reduce(0) { $0 + $1.reclaimableBytes }
            self.record(.info, "Found \(groups.count) duplicate group(s); up to \(total.formattedBytes) can be shared.")
        })
    }

    func cloneSelectedDuplicates() {
        guard let groups = duplicateGroups?.filter({ selectedGroups.contains($0.id) }), !groups.isEmpty else { return }
        perform("Converting duplicates to clones", work: { progress in
            CloneDeduplicator.deduplicate(groups, progress: progress)
        }, completion: { report in
            let done = Set(groups.map(\.id))
            self.duplicateGroups?.removeAll { done.contains($0.id) }
            self.selectedGroups.subtract(done)
            self.recordOperation(report, verb: "Cloned")
        })
    }

    func findCompressible() {
        let roots = locations
        let options = scanOptions(minimumFileSize: Int64(minimumCompressionSizeKB * 1024))
        perform("Finding compressible files", work: { progress in
            try TransparentCompression.findCandidates(in: roots, options: options, progress: progress)
        }, completion: { candidates in
            self.candidates = candidates
            self.selectedCandidates = Set(candidates.map(\.id))
            let total = candidates.reduce(0) { $0 + $1.estimatedSavings }
            self.record(.info, "Found \(candidates.count) compressible file(s); about \(total.formattedBytes) can be saved.")
        })
    }

    func compressSelected() {
        guard let chosen = candidates?.filter({ selectedCandidates.contains($0.id) }), !chosen.isEmpty else { return }
        perform("Compressing files", work: { progress in
            TransparentCompression.compress(chosen, progress: progress)
        }, completion: { report in
            let done = Set(chosen.map(\.id))
            self.candidates?.removeAll { done.contains($0.id) }
            self.selectedCandidates.subtract(done)
            self.recordOperation(report, verb: "Compressed")
        })
    }

    // MARK: Background

    /// Runs the daily compression, but only on power and outside Low Power Mode; the hourly
    /// check retries until both hold. The work runs at background priority, which macOS also
    /// throttles for disk access.
    func compressNewFilesIfDue() {
        guard runInBackground, (lastBackgroundRun ?? .distantPast) < Date().addingTimeInterval(-24 * 60 * 60),
              canRunInBackground()
        else { return }
        compressNewFiles()
    }

    /// Finds and compresses everything worth compressing, without a review step. Files changed in
    /// the last day are skipped by `findCandidates`, so repeat runs only pick up settled new files.
    func compressNewFiles() {
        let roots = locations
        let options = scanOptions(minimumFileSize: Int64(minimumCompressionSizeKB * 1024))
        perform("Compressing new files", priority: .background, work: { progress in
            let found = try TransparentCompression.findCandidates(in: roots, options: options, progress: progress)
            return TransparentCompression.compress(found, progress: progress)
        }, completion: { report in
            self.lastBackgroundRun = Date()
            self.defaults.set(self.lastBackgroundRun, forKey: "lastBackgroundRun")
            self.candidates = nil
            self.lastBackgroundResult = self.recordOperation(report, verb: "Compressed")
            self.defaults.set(self.lastBackgroundResult, forKey: "lastBackgroundResult")
        })
    }

    private func updateLoginAgent() {
        do {
            if runInBackground {
                try Self.loginAgent.register()
                if Self.loginAgent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                compressNewFilesIfDue()
            } else {
                try Self.loginAgent.unregister()
            }
        } catch {
            record(.error, "Could not update the login item: \(error.localizedDescription)")
        }
    }

    // MARK: Updates

    private static let latestRelease = URL(string: "https://api.github.com/repos/PanterSoft/Reclaim/releases/latest")!

    func checkForUpdatesIfDue() async {
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard checksForUpdates, last < Date().addingTimeInterval(-24 * 60 * 60) else { return }
        await checkForUpdates()
    }

    /// Asks GitHub for the latest release and compares it with this build's version.
    /// `userInitiated` reports the outcome (including "up to date" and errors) in an alert.
    func checkForUpdates(userInitiated: Bool = false) async {
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        guard let current = currentVersion else { return }
        do {
            let (data, response) = try await fetch(Self.latestRelease)
            defaults.set(Date(), forKey: "lastUpdateCheck")
            let release = (response as? HTTPURLResponse)?.statusCode == 200 ? try JSONDecoder().decode(Release.self, from: data) : nil
            if let release, let latest = UpdateCheck.newerVersion(latest: release.tag_name, current: current) {
                availableUpdate = (latest, release.html_url)
                if userInitiated { offerUpdate() }
            } else {
                availableUpdate = nil
                if userInitiated { alert("Reclaim is up to date", "You have version \(current), the latest release.") }
            }
        } catch {
            if userInitiated { alert("Could not check for updates", error.localizedDescription) }
        }
    }

    func offerUpdate() {
        guard let update = availableUpdate else { return }
        let alert = NSAlert()
        alert.messageText = "Reclaim \(update.version) is available"
        alert.informativeText = "Download it from GitHub, then replace Reclaim in Applications (or run `make install` from the repository)."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.page) }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true) // a menu bar-only app would show it behind other windows
        alert.runModal()
    }

    func decompressFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Decompress"
        panel.message = "Choose files or folders to store uncompressed again."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        perform("Decompressing files", work: { _ in
            try TransparentCompression.decompress(urls)
        }, completion: { report in
            self.recordOperation(report, verb: "Decompressed")
        })
    }

    func cancel() { cancelCurrent?() }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Plumbing

    private func perform<T: Sendable>(
        _ title: String,
        priority: TaskPriority = .userInitiated,
        work: @escaping @Sendable (@escaping ProgressHandler) throws -> T,
        completion: @escaping @MainActor (T) -> Void
    ) {
        guard !isBusy else { return }
        busyTitle = title
        progress = nil
        let handler: ProgressHandler = { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }
        let worker = Task.detached(priority: priority) { try work(handler) }
        cancelCurrent = { worker.cancel() }
        Task {
            let result = await worker.result
            busyTitle = nil
            progress = nil
            cancelCurrent = nil
            switch result {
            case .success(let value):
                completion(value)
            case .failure(let error) where error is CancellationError:
                record(.warning, "\(title) was cancelled.")
            case .failure(let error):
                record(.error, "\(title) failed: \(error.localizedDescription)")
            }
            refreshVolume()
        }
    }

    private func record(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        log.insert(entry, at: 0)
        let line = entry.line
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logFile)
        }
    }

    @discardableResult
    private func recordOperation(_ report: OperationReport, verb: String) -> String {
        let message = report.summary(verb: verb)
        record(report.failures.isEmpty ? .success : .warning, message)
        for failure in report.failures { record(.error, failure.reason) }
        return message
    }
}
