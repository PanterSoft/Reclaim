import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runInBackground: Bool { UserDefaults.standard.bool(forKey: AppModel.runInBackgroundKey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock icon only while a window is open: drop it once the last one closes in background mode.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.runInBackground == true, !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        // One instance only: the login agent also starts one right when it is registered.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        // Started by the login agent: menu bar only, no window, no Dock icon.
        if CommandLine.arguments.contains("--background") {
            guard others.isEmpty else { return NSApp.terminate(nil) }
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() } }
            return
        }
        // A copy opened by hand replaces a background one (it takes over the menu bar icon).
        others.forEach { $0.terminate() }
        // Also makes `swift run ReclaimApp` behave like a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        requestFullDiskAccessIfNeeded()
    }

    /// macOS has no API to request Full Disk Access, so explain it and open the right pane.
    private func requestFullDiskAccessIfNeeded() {
        let skipKey = "skipFullDiskAccessPrompt"
        // Only the installed bundle, not `swift run` (that binary gets the terminal's access).
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: skipKey) else { return }
        // ponytail: the TCC database is only readable with Full Disk Access; the common probe for it.
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileHandle(forReadingAtPath: probe) == nil else { return }

        let alert = NSAlert()
        alert.messageText = "Allow Full Disk Access"
        alert.informativeText = "Reclaim needs Full Disk Access to scan all your files without asking for each folder. In System Settings, turn on Reclaim under Full Disk Access, then reopen Reclaim."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipKey) }
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !runInBackground }

    /// Opening Reclaim from Finder or the Dock while it runs in the background shows the window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }
}

@main
struct ReclaimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    // Binding isInserted to the @StateObject stops the main window from opening at launch.
    @AppStorage(AppModel.runInBackgroundKey) private var showsMenuBarExtra = false

    var body: some Scene {
        WindowGroup("Reclaim", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.checkForUpdates(userInitiated: true) } }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra("Reclaim", systemImage: "arrow.down.right.and.arrow.up.left", isInserted: $showsMenuBarExtra) {
            MenuBarMenu().environmentObject(model)
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let volume = model.volume {
            Text("\(volume.availableCapacity.formattedBytes) free on \(volume.name)")
        }
        if let title = model.busyTitle {
            Text(model.progress?.summary ?? title + "…")
            Button("Cancel") { model.cancel() }
        } else {
            Button("Compress New Files Now") { model.compressNewFiles() }
        }
        if let update = model.availableUpdate {
            Button("Update Available: \(update.version)…") { model.offerUpdate() }
            Divider()
        }
        Text("Last run: " + (model.lastBackgroundRun?.formatted(.relative(presentation: .named)) ?? "never"))
        if let result = model.lastBackgroundResult { Text(result) }
        Button("Show Activity Log") { NSWorkspace.shared.open(AppModel.logFile) }
        Button("Check for Updates…") { Task { await model.checkForUpdates(userInitiated: true) } }
        Divider()
        Button("Open Reclaim") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Stop Running in Background") { model.runInBackground = false }
        Button("Quit Reclaim") { NSApp.terminate(nil) }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case analyze = "Storage"
    case duplicates = "Duplicates"
    case compression = "Compression"
    case activity = "Activity"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "internaldrive"
        case .analyze: return "chart.bar.xaxis"
        case .duplicates: return "doc.on.doc"
        case .compression: return "arrow.down.right.and.arrow.up.left"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(selection: $selection)
                case .analyze: AnalyzeView()
                case .duplicates: DuplicatesView()
                case .compression: CompressionView()
                case .activity: ActivityView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom) {
                if model.isBusy { StatusBar() }
            }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let progress = model.progress, let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(total))
                    .frame(width: 160)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.progress?.summary ?? (model.busyTitle ?? "") + "…")
                    .font(.callout.weight(.medium))
                Text(model.progress?.detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { model.cancel() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Duplicates") {
                Stepper(value: $model.minimumDuplicateSizeMB, in: 0.1...1024, step: 1) {
                    Text("Ignore files smaller than \(model.minimumDuplicateSizeMB, specifier: "%.1f") MB")
                }
            }
            Section("Compression") {
                Stepper(value: $model.minimumCompressionSizeKB, in: 4...102_400, step: 16) {
                    Text("Ignore files smaller than \(Int(model.minimumCompressionSizeKB)) KB")
                }
            }
            Section("Background") {
                Toggle("Run in the menu bar and compress new files daily", isOn: $model.runInBackground)
                Text("Reclaim starts at login and, once a day, compresses files in your locations that changed more than a day ago. Every file is verified before it is replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check GitHub for new versions daily", isOn: $model.checksForUpdates)
            }
            Section("Safety") {
                Toggle("Include application bundles (.app)", isOn: $model.includeAppBundles)
                Text("~/Library, the Trash, system folders and app-managed libraries such as Photos are always skipped unless you add them as a location explicitly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
