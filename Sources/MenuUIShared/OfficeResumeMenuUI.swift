import SwiftUI
import AppKit
import OfficeResumeCore

struct OfficeResumeMenuScene: Scene {
    private let channel: DistributionChannel
    @StateObject private var model: OfficeResumeMenuViewModel

    init(channel: DistributionChannel) {
        self.channel = channel
        let viewModel = OfficeResumeMenuViewModel(channel: channel)
        viewModel.startupIfNeeded()
        _model = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        MenuBarExtra("Office Resume", systemImage: "arrow.clockwise.circle") {
            OfficeResumeMenuContentView(model: model)
        }
    }
}

private struct OfficeResumeMenuContentView: View {
    @ObservedObject var model: OfficeResumeMenuViewModel

    var body: some View {
        Group {
            if !model.connectionOK {
                Text("Connecting to helper...")
                    .foregroundStyle(.secondary)
            }

            if model.status.isPaused {
                Text("Tracking is paused")
                    .foregroundStyle(.secondary)
            }

            if model.connectionOK {
                if model.status.accessibilityTrusted {
                    Text("Accessibility: OK")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Accessibility: click to fix") {
                        model.openAccessibilitySettings()
                    }
                }
                Divider()
            } else {
                Button("Accessibility: click to fix") {
                    model.openAccessibilitySettings()
                }
                Divider()
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

                Button("Open Debug Log in Console") {
                    model.openDebugLogInConsole()
                }
            }

            Divider()
            Button("Quit") {
                model.quit()
            }
        }
        .onAppear {
            model.reloadStatus()
        }
    }
}

@MainActor
final class OfficeResumeMenuViewModel: ObservableObject {
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

    private let channel: DistributionChannel
    private let client = DaemonXPCClient()
    private var started = false
    private var statusRefreshTimer: Timer?
    private var startupRetryCount = 0
    private let maxStartupRetryCount = 8
    private var consecutiveStatusFailures = 0

    init(channel: DistributionChannel) {
        self.channel = channel
    }

    deinit {
        statusRefreshTimer?.invalidate()
    }

    var canRunRestore: Bool {
        connectionOK && !status.isPaused && status.entitlementActive
    }

    func startupIfNeeded() {
        guard !started else {
            return
        }
        RuntimeConfiguration.setDistributionChannel(channel)
        HelperLauncher.ensureHelperRunning()
        startStatusRefreshTimer()
        started = true
    }

    func reloadStatus() {
        client.fetchStatus { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(status):
                    self.status = status
                    self.connectionOK = true
                    self.startupRetryCount = 0
                    self.consecutiveStatusFailures = 0
                case .failure:
                    self.consecutiveStatusFailures += 1
                    if !self.connectionOK || self.consecutiveStatusFailures >= 3 {
                        self.connectionOK = false
                    }
                    self.retryStartupIfNeeded()
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        client.setPaused(paused) { [weak self] _ in
            Task { @MainActor in
                self?.reloadStatus()
            }
        }
    }

    func restoreNow() {
        client.restoreNow(app: nil) { [weak self] _ in
            Task { @MainActor in
                self?.reloadStatus()
            }
        }
    }

    func clearSnapshot() {
        client.clearSnapshot(app: nil) { [weak self] _ in
            Task { @MainActor in
                self?.reloadStatus()
            }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openDebugLogInConsole() {
        if !DebugLog.openLogInConsole() {
            DebugLog.warning("Failed to open debug log in Console")
        }
    }

    func quit() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
        HelperLauncher.terminateHelperIfRunning()
        NSApplication.shared.terminate(nil)
    }

    private func startStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reloadStatus()
        }
    }

    private func retryStartupIfNeeded() {
        guard started else {
            return
        }
        guard startupRetryCount < maxStartupRetryCount else {
            return
        }

        startupRetryCount += 1
        HelperLauncher.ensureHelperRunning()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.reloadStatus()
        }
    }
}
