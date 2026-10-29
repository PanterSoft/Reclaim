import AppKit
import Foundation
import ReclaimCore
import ServiceManagement

struct LogEntry: Identifiable, Hashable {
    enum Level { case info, success, warning, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    // Saved so the background run uses the same settings after a restart.
    @Published var locations: [URL] = (UserDefaults.standard.stringArray(forKey: "locations") ?? [NSHomeDirectory()]).map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(locations.map(\.path), forKey: "locations") }
    }
    @Published var includeAppBundles = UserDefaults.standard.bool(forKey: "includeAppBundles") {
        didSet { UserDefaults.standard.set(includeAppBundles, forKey: "includeAppBundles") }
    }
    @Published var minimumDuplicateSizeMB = UserDefaults.standard.object(forKey: "minimumDuplicateSizeMB") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(minimumDuplicateSizeMB, forKey: "minimumDuplicateSizeMB") }
    }
    @Published var minimumCompressionSizeKB = UserDefaults.standard.object(forKey: "minimumCompressionSizeKB") as? Double ?? 64.0 {
        didSet { UserDefaults.standard.set(minimumCompressionSizeKB, forKey: "minimumCompressionSizeKB") }
    }
    /// Keep running in the menu bar, start at login and compress new files once a day.
    @Published var runInBackground = UserDefaults.standard.bool(forKey: AppModel.runInBackgroundKey) {
        didSet {
            guard runInBackground != oldValue else { return }
            UserDefaults.standard.set(runInBackground, forKey: Self.runInBackgroundKey)
            updateLoginAgent()
        }
    }
    @Published private(set) var lastBackgroundRun = UserDefaults.standard.object(forKey: "lastBackgroundRun") as? Date

    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var report: StorageReport?
    @Published private(set) var duplicateGroups: [DuplicateGroup]?
    @Published var selectedGroups: Set<DuplicateGroup.ID> = []
    @Published private(set) var candidates: [CompressionCandidate]?
    @Published var selectedCandidates: Set<CompressionCandidate.ID> = []

    @Published private(set) var busyTitle: String?
    @Published private(set) var progress: ProgressUpdate?
    @Published private(set) var log: [LogEntry] = []

    private var cancelCurrent: (() -> Void)?
    private var scheduler: Timer?

    nonisolated static let runInBackgroundKey = "runInBackground"
    /// Starts `Reclaim --background` at login; the plist ships in Contents/Library/LaunchAgents.
    private static let loginAgent = SMAppService.agent(plistName: "io.github.reclaim.Reclaim.background.plist")

    var isBusy: Bool { busyTitle != nil }

    init() {
        refreshVolume()
        // ponytail: hourly check for a daily run; FSEvents if new files should be picked up sooner.
        scheduler = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.compressNewFilesIfDue() }
        }
        compressNewFilesIfDue()
        // Removing the menu bar icon (⌘-drag) writes the setting directly; follow it.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let stored = UserDefaults.standard.bool(forKey: Self.runInBackgroundKey)
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

    func compressNewFilesIfDue() {
        guard runInBackground, (lastBackgroundRun ?? .distantPast) < Date().addingTimeInterval(-24 * 60 * 60) else { return }
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
            UserDefaults.standard.set(self.lastBackgroundRun, forKey: "lastBackgroundRun")
            self.candidates = nil
            self.recordOperation(report, verb: "Compressed")
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

    func decompressFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Decompress"
        panel.message = "Choose files or folders to store uncompressed again."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        perform("Decompressing files", work: { _ -> OperationReport in
            var report = OperationReport()
            try FileWalker.walk(urls, options: ScanOptions()) { path, st in
                guard st.isCompressed else { return }
                do {
                    report.bytesReclaimed -= try TransparentCompression.decompress(path)
                    report.succeeded += 1
                } catch {
                    report.failures.append(.init(path: path, reason: error.localizedDescription))
                }
            }
            return report
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
        log.insert(LogEntry(level: level, message: message), at: 0)
    }

    private func recordOperation(_ report: OperationReport, verb: String) {
        var message = "\(verb) \(report.succeeded) file(s)"
        if report.bytesReclaimed > 0 { message += ", freeing about \(report.bytesReclaimed.formattedBytes)" }
        if report.skipped > 0 { message += "; \(report.skipped) skipped (would not shrink enough)" }
        record(report.failures.isEmpty ? .success : .warning, message + ".")
        for failure in report.failures { record(.error, failure.reason) }
    }
}
