import SwiftUI
import AppKit
import OfficeResumeCore

@main
struct OfficeResumeDirectApp: App {
    @StateObject private var model = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra("Office Resume", systemImage: "arrow.clockwise.circle") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ContentView: View {
    @ObservedObject var model: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.connectionOK {
                Text("Helper unavailable. Relaunch Office Resume.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.status.isPaused {
                Text("Tracking is paused")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !model.status.accessibilityTrusted {
                Text("Accessibility permission is required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings") {
                    model.openAccessibilitySettings()
                }
            }

            Button(model.status.isPaused ? "Resume Tracking" : "Pause Tracking") {
                model.setPaused(!model.status.isPaused)
            }
            .disabled(!model.connectionOK)

            Button("Restore Now") {
                model.restoreNow()
            }
            .disabled(!model.canRunRestore)

            Menu("Advanced") {
                Button("Clear Snapshot") {
                    model.clearSnapshot()
                }
                .disabled(!model.connectionOK)

                Button("Open Debug Log") {
                    model.openDebugLog()
                }
            }

            if model.status.unsupportedApps.contains(.onenote) {
                Text("OneNote is not supported in v1.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button("Quit") {
                model.quit()
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            RuntimeConfiguration.setDistributionChannel(.direct)
            HelperLauncher.ensureHelperRunning()
            model.refresh()
        }
    }
}

@MainActor
private final class MenuBarViewModel: ObservableObject {
    @Published var status = DaemonStatusDTO(
        isPaused: false,
        helperRunning: false,
        entitlementActive: false,
        entitlementPlan: .none,
        entitlementValidUntil: nil,
        entitlementTrialEndsAt: nil,
        accessibilityTrusted: false,
        latestSnapshotCapturedAt: [:],
        unsupportedApps: OfficeBundleRegistry.unsupportedApps
    )
    @Published var connectionOK = false

    private let client = DaemonXPCClient()

    var canRunRestore: Bool {
        connectionOK && !status.isPaused && status.entitlementActive
    }

    func refresh() {
        client.fetchStatus { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(status):
                    self.status = status
                    self.connectionOK = true
                case .failure:
                    self.connectionOK = false
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        client.setPaused(paused) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func restoreNow() {
        client.restoreNow(app: nil) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func clearSnapshot() {
        client.clearSnapshot(app: nil) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openDebugLog() {
        if !DebugLog.revealLogFileInFinder() {
            DebugLog.warning("Failed to reveal debug log")
        }
    }

    func quit() {
        HelperLauncher.terminateHelperIfRunning()
        NSApplication.shared.terminate(nil)
    }
}
