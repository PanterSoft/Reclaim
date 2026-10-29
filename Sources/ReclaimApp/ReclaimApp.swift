import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also makes `swift run ReclaimApp` behave like a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ReclaimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Reclaim") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
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
