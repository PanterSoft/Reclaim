import ReclaimCore
import SwiftUI

// MARK: - Shared components

struct UsageBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint).frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyPrompt: View {
    let symbol: String
    let message: String
    let action: String
    let perform: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy || model.locations.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct PathLabel: View {
    let path: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent).lineLimit(1)
            Text((path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                model.reveal(path)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Reclaim",
                    subtitle: "Free up space on your Mac without deleting a single file. Every file keeps its name, location, contents and metadata."
                )
                if let volume = model.volume { VolumeCard(volume: volume) }

                GroupBox("Locations to scan") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.locations, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder")
                                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                Spacer()
                                Button { model.removeLocation(url) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .disabled(model.isBusy)
                            }
                        }
                        Button("Add Folder…") { model.addLocations() }.disabled(model.isBusy)
                    }
                    .padding(6)
                }

                HStack(alignment: .top, spacing: 16) {
                    TechniqueCard(
                        symbol: "doc.on.doc",
                        title: "Share duplicate storage",
                        text: "Identical files are turned into APFS clones. Each stays a normal, independent file, but they share the same blocks on disk until one of them is edited."
                    ) { selection = .duplicates }
                    TechniqueCard(
                        symbol: "arrow.down.right.and.arrow.up.left",
                        title: "Transparent compression",
                        text: "Files that compress well are stored compressed by the file system, the way macOS stores its own system files. Apps read them exactly as before."
                    ) { selection = .compression }
                    TechniqueCard(
                        symbol: "chart.bar.xaxis",
                        title: "See what uses space",
                        text: "Measure folders, file kinds and the largest files so you can decide what to do yourself. Analysis never changes anything."
                    ) { selection = .analyze }
                }
            }
            .padding(28)
        }
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "internaldrive").font(.title2)
                    VStack(alignment: .leading) {
                        Text(volume.name).font(.headline)
                        Text(volume.format).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(volume.availableCapacity.formattedBytes) free of \(volume.totalCapacity.formattedBytes)")
                        .font(.headline)
                }
                UsageBar(fraction: Double(volume.used) / Double(max(volume.totalCapacity, 1)))
                HStack(spacing: 16) {
                    Text("Used: \(volume.used.formattedBytes)")
                    if volume.purgeable > 0 { Text("Purgeable (macOS frees on demand): \(volume.purgeable.formattedBytes)") }
                    Spacer()
                    if !volume.supportsCloning { Label("No APFS clone support", systemImage: "exclamationmark.triangle") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}

struct TechniqueCard: View {
    let symbol: String
    let title: String
    let text: String
    let open: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open", action: open)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

// MARK: - Storage analysis

struct AnalyzeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let report = model.report {
            List {
                Section {
                    HStack(spacing: 24) {
                        Stat(label: "On disk", value: report.allocatedBytes.formattedBytes)
                        Stat(label: "Files", value: report.fileCount.formatted())
                        Stat(label: "Saved by compression", value: report.compressionSavings.formattedBytes)
                        Stat(label: "Cloud-only files", value: report.cloudOnlyFiles.formatted())
                        Spacer()
                        Button("Rescan") { model.analyze() }.disabled(model.isBusy)
                    }
                    .padding(.vertical, 6)
                }
                Section("By kind") {
                    ForEach(report.categories) { usage in
                        SizeRow(title: usage.category.rawValue, bytes: usage.bytes, total: report.allocatedBytes)
                    }
                }
                Section("Largest folders") {
                    ForEach(report.folders.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                PathLabel(path: entry.path)
                                Text(entry.bytes.formattedBytes).monospacedDigit().frame(width: 90, alignment: .trailing)
                            }
                            UsageBar(fraction: Double(entry.bytes) / Double(max(report.allocatedBytes, 1)))
                        }
                    }
                }
                Section("Largest files") {
                    ForEach(report.largestFiles) { entry in
                        HStack {
                            PathLabel(path: entry.path)
                            Text(entry.bytes.formattedBytes).monospacedDigit().frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        } else {
            EmptyPrompt(
                symbol: "chart.bar.xaxis",
                message: "Measure what is using space in your chosen locations.\nThis only reads your files.",
                action: "Analyze Storage"
            ) { model.analyze() }
        }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SizeRow: View {
    let title: String
    let bytes: Int64
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(bytes.formattedBytes).monospacedDigit()
            }
            UsageBar(fraction: Double(bytes) / Double(max(total, 1)))
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming = false

    private var selectedBytes: Int64 {
        (model.duplicateGroups ?? []).filter { model.selectedGroups.contains($0.id) }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var body: some View {
        if let groups = model.duplicateGroups {
            VStack(spacing: 0) {
                if groups.isEmpty {
                    EmptyPrompt(symbol: "checkmark.circle", message: "No duplicates found that could share storage.", action: "Scan Again") {
                        model.findDuplicates()
                    }
                } else {
                    List {
                        ForEach(groups) { group in
                            DuplicateGroupRow(group: group)
                        }
                    }
                    ActionBar(
                        summary: "\(model.selectedGroups.count) of \(groups.count) groups selected · frees about \(selectedBytes.formattedBytes)",
                        rescan: { model.findDuplicates() },
                        selectAll: { model.selectedGroups = Set(groups.map(\.id)) },
                        selectNone: { model.selectedGroups = [] },
                        actionTitle: "Convert to Clones…",
                        actionEnabled: !model.selectedGroups.isEmpty,
                        perform: { confirming = true }
                    )
                }
            }
            .confirmationDialog("Convert the selected duplicates to APFS clones?", isPresented: $confirming) {
                Button("Convert to Clones") { model.cloneSelectedDuplicates() }
            } message: {
                Text("Every file stays where it is with the same contents, dates and tags. Each copy is verified before it replaces the original, and files that changed since the scan are skipped.")
            }
        } else {
            EmptyPrompt(
                symbol: "doc.on.doc",
                message: "Find identical files and let them share storage as APFS clones.\nScanning only reads your files.",
                action: "Find Duplicates"
            ) { model.findDuplicates() }
        }
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @EnvironmentObject var model: AppModel

    var body: some View {
        DisclosureGroup {
            ForEach(group.allFiles) { file in
                HStack(spacing: 8) {
                    Text(file == group.keeper ? "keep" : "clone")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(file == group.keeper ? Color.green : Color.accentColor)
                        .frame(width: 40, alignment: .leading)
                    PathLabel(path: file.path)
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { model.selectedGroups.contains(group.id) },
                    set: { on in
                        if on { model.selectedGroups.insert(group.id) } else { model.selectedGroups.remove(group.id) }
                    }
                ))
                .labelsHidden()
                Text((group.keeper.path as NSString).lastPathComponent).lineLimit(1)
                Text("\(group.allFiles.count) copies × \(group.size.formattedBytes)").foregroundStyle(.secondary)
                Spacer()
                Text(group.reclaimableBytes.formattedBytes).monospacedDigit()
            }
        }
    }
}

struct ActionBar: View {
    let summary: String
    let rescan: () -> Void
    let selectAll: () -> Void
    let selectNone: () -> Void
    let actionTitle: String
    let actionEnabled: Bool
    let perform: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Button("Rescan", action: rescan)
            Button("All", action: selectAll)
            Button("None", action: selectNone)
            Text(summary).foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: perform)
                .buttonStyle(.borderedProminent)
                .disabled(!actionEnabled)
        }
        .disabled(model.isBusy)
        .padding(12)
        .background(.bar)
    }
}

// MARK: - Compression

struct CompressionView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming = false

    private var selectedBytes: Int64 {
        (model.candidates ?? []).filter { model.selectedCandidates.contains($0.id) }.reduce(0) { $0 + $1.estimatedSavings }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let candidates = model.candidates {
                if candidates.isEmpty {
                    EmptyPrompt(symbol: "checkmark.circle", message: "No files found that would benefit from compression.", action: "Scan Again") {
                        model.findCompressible()
                    }
                } else {
                    List {
                        ForEach(candidates) { candidate in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { model.selectedCandidates.contains(candidate.id) },
                                    set: { on in
                                        if on { model.selectedCandidates.insert(candidate.id) } else { model.selectedCandidates.remove(candidate.id) }
                                    }
                                ))
                                .labelsHidden()
                                PathLabel(path: candidate.path)
                                Text("\(candidate.stat.allocatedSize.formattedBytes) → ~\(Int((candidate.estimatedRatio * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(candidate.estimatedSavings.formattedBytes)
                                    .monospacedDigit()
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                    }
                    ActionBar(
                        summary: "\(model.selectedCandidates.count) of \(candidates.count) files selected · saves about \(selectedBytes.formattedBytes)",
                        rescan: { model.findCompressible() },
                        selectAll: { model.selectedCandidates = Set(candidates.map(\.id)) },
                        selectNone: { model.selectedCandidates = [] },
                        actionTitle: "Compress…",
                        actionEnabled: !model.selectedCandidates.isEmpty,
                        perform: { confirming = true }
                    )
                }
            } else {
                EmptyPrompt(
                    symbol: "arrow.down.right.and.arrow.up.left",
                    message: "Find files that take less space when stored with transparent compression.\nScanning only reads your files.",
                    action: "Find Compressible Files"
                ) { model.findCompressible() }
            }
            HStack {
                Text("Changed your mind? Compression can be undone at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Decompress Files…") { model.decompressFiles() }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog("Compress the selected files?", isPresented: $confirming) {
            Button("Compress") { model.compressSelected() }
        } message: {
            Text("Files stay in place and every app reads them as before. Each compressed copy is verified before it replaces the original; files that would not shrink by at least 10% are left alone.")
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.log.isEmpty {
            Text("Nothing has happened yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.log) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: icon(entry.level)).foregroundStyle(color(entry.level))
                    Text(entry.message).textSelection(.enabled)
                    Spacer()
                    Text(entry.date, style: .time).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(_ level: LogEntry.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
