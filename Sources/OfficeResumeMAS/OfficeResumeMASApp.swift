import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeMASApp: App {
    @StateObject private var model = MenuBarViewModel(channel: "MAS")

    var body: some Scene {
        MenuBarExtra("Office Resume", systemImage: "arrow.clockwise.circle") {
            ContentView(model: model)
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Office Resume")
                .font(.headline)
            Text("Channel: \(model.channel)")
                .font(.subheadline)

            HStack {
                Circle()
                    .fill(model.connectionOK ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.connectionOK ? "Helper Connected" : "Helper Unavailable")
                    .font(.caption)
            }

            Text("Entitlement: \(model.status.entitlementActive ? "Active" : "Inactive")")
                .font(.caption)

            Toggle("Pause tracking", isOn: Binding(
                get: { model.status.isPaused },
                set: { model.setPaused($0) }
            ))

            Picker("Polling", selection: Binding(
                get: { model.status.pollingInterval },
                set: { model.setPolling($0) }
            )) {
                ForEach(PollingInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Restore now") {
                    model.restoreNow()
                }
                Button("Clear snapshot") {
                    model.clearSnapshot()
                }
                Button("Refresh") {
                    model.refresh()
                }
            }

            if !model.status.unsupportedApps.isEmpty {
                Text("Unsupported: \(model.status.unsupportedApps.map(\.rawValue).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.snapshotSummary.isEmpty {
                Text("Latest Snapshots")
                    .font(.caption)
                    .bold()
                ForEach(model.snapshotSummary, id: \.self) { entry in
                    Text(entry)
                        .font(.caption2)
                }
            }

            Divider()
            Text("Recent Events")
                .font(.caption)
                .bold()

            if model.events.isEmpty {
                Text("No events yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.events.prefix(6).enumerated()), id: \.offset) { _, item in
                    Text("\(item.type.rawValue) • \(item.app.rawValue) • \(model.format(item.timestamp))")
                        .font(.caption2)
                }
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            HelperLauncher.ensureHelperRunning()
            model.refresh()
        }
    }
}

@MainActor
private final class MenuBarViewModel: ObservableObject {
    @Published var status = DaemonStatusDTO(
        isPaused: false,
        pollingInterval: .fifteenSeconds,
        helperRunning: false,
        entitlementActive: false,
        latestSnapshotCapturedAt: [:],
        unsupportedApps: OfficeBundleRegistry.unsupportedApps
    )
    @Published var events: [LifecycleEventDTO] = []
    @Published var connectionOK = false

    let channel: String
    private let client = DaemonXPCClient()

    init(channel: String) {
        self.channel = channel
    }

    var snapshotSummary: [String] {
        status.latestSnapshotCapturedAt
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            .map { app, date in
                "\(app.rawValue): \(Self.formatter.string(from: date))"
            }
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

        client.fetchRecentEvents(limit: 20) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(items):
                    self.events = items
                case .failure:
                    self.events = []
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

    func setPolling(_ interval: PollingInterval) {
        client.setPollingInterval(interval) { [weak self] _ in
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

    func format(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
