import AppKit
import Foundation
import SwiftUI
import OfficeResumeCore

extension Notification.Name {
    static let officeResumeDidOpenURL = Notification.Name("com.pragprod.msofficeresume.did-open-url")
}

final class OfficeResumeApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .officeResumeDidOpenURL, object: url)
        }
    }
}

@MainActor
final class OfficeResumeAppRuntime: ObservableObject {
    let menuModel: OfficeResumeMenuViewModel
    let accountModel: OfficeResumeAccountViewModel

    init(channel: DistributionChannel) {
        self.menuModel = OfficeResumeMenuViewModel(channel: channel)
        self.accountModel = OfficeResumeAccountViewModel(channel: channel)
        self.menuModel.startupIfNeeded()
        self.accountModel.startupIfNeeded()
    }
}

struct OfficeResumeMenuScene: Scene {
    @ObservedObject private var model: OfficeResumeMenuViewModel

    init(model: OfficeResumeMenuViewModel) {
        self.model = model
    }

    var body: some Scene {
        MenuBarExtra("Office Resume", systemImage: "arrow.clockwise.circle") {
            OfficeResumeMenuContentView(model: model)
        }
    }
}

struct OfficeResumeAccountScene: Scene {
    @ObservedObject private var model: OfficeResumeAccountViewModel

    init(model: OfficeResumeAccountViewModel) {
        self.model = model
    }

    var body: some Scene {
        Settings {
            OfficeResumeAccountView(model: model)
                .frame(width: 420)
        }
    }
}

private struct OfficeResumeMenuContentView: View {
    @ObservedObject var model: OfficeResumeMenuViewModel

    var body: some View {
        Group {
            if model.helperAvailable {
                Text("Helper: OK")
                    .foregroundStyle(.secondary)
            } else {
                Text("Helper: reconnecting...")
                    .foregroundStyle(.secondary)
            }

            if model.autostartHealthy {
                Text("Autostart: OK")
                    .foregroundStyle(.secondary)
            } else {
                Button("Autostart: click to fix") {
                    model.openLoginItemsSettings()
                }
            }

            if model.status.isPaused {
                Text("Tracking is paused")
                    .foregroundStyle(.secondary)
            }

            Button(model.status.isPaused ? "Resume Tracking" : "Pause Tracking") {
                model.setPaused(!model.status.isPaused)
            }
            .disabled(!model.helperAvailable)

            Button("Restore Now") {
                model.restoreNow()
            }
            .disabled(!model.canRunRestore)

            Menu("Advanced") {
                Button("Grant Folder Access…") {
                    model.grantFolderAccess()
                }

                Button("Clear Snapshot") {
                    model.clearSnapshot()
                }
                .disabled(!model.helperAvailable)

                Button("Open Debug Log in Console") {
                    model.openDebugLogInConsole()
                }
            }

            Button("Account…") {
                model.openAccountWindow()
            }

            Divider()

            Button("Quit") {
                model.quit()
            }
        }
        .onAppear {
            model.menuOpened()
        }
    }
}

private struct OfficeResumeAccountView: View {
    @ObservedObject var model: OfficeResumeAccountViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Office Resume Account")
                .font(.title3.weight(.semibold))

            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Group {
                if model.channel == .direct {
                    directContent
                } else {
                    masContent
                }
            }

#if DEBUG
            Divider()
            Toggle("Enable Local Debug Pass", isOn: $model.debugEntitlementBypassEnabled)
                .onChange(of: model.debugEntitlementBypassEnabled) { _, newValue in
                    model.setDebugEntitlementBypassEnabled(newValue)
                }
            Text("Debug-only. This is a local testing shortcut and does not exist in Release builds.")
                .font(.caption)
                .foregroundStyle(.secondary)
#endif
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            model.refresh()
        }
    }

    private var directContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            entitlementSummary

            if model.accountState.canSignIn {
                TextField("Email", text: $model.emailInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isWorking)

                Text("Direct trial and free-pass access begin after verified email sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Pricing: $5/month or $50/year")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Send Sign-In Link") {
                    model.sendSignInLink()
                }
                .disabled(model.isWorking || model.emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                if let email = model.accountState.email {
                    Text("Signed in as \(email)")
                        .font(.body)
                }

                HStack {
                    Button("Refresh Status") {
                        model.refresh()
                    }
                    .disabled(model.isWorking)

                    if let billingAction = model.accountState.billingAction {
                        Button(billingAction.title) {
                            model.openBillingAction()
                        }
                        .disabled(model.isWorking)
                    }

                    Button("Sign Out") {
                        model.signOut()
                    }
                    .disabled(model.isWorking || !model.accountState.canSignOut)
                }
            }
        }
    }

    private var masContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            entitlementSummary

            Text("Pricing: $5/month or $50/year")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Refresh Status") {
                    model.refresh()
                }
                .disabled(model.isWorking)

                if let billingAction = model.accountState.billingAction {
                    Button(billingAction.title) {
                        model.openBillingAction()
                    }
                    .disabled(model.isWorking)
                }
            }
        }
    }

    private var entitlementSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan: \(model.planDescription)")
            if let validUntil = model.formattedValidUntil {
                Text("Valid until: \(validUntil)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let trialEndsAt = model.formattedTrialEndsAt {
                Text("Trial ends: \(trialEndsAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        latestSnapshotCapturedAt: [:],
        unsupportedApps: OfficeBundleRegistry.unsupportedApps
    )
    @Published var helperAvailable = false
    @Published var autostartHealthy = true

    private let channel: DistributionChannel
    private let client = DaemonXPCClient()
    private let folderAccessStore = FolderAccessStore()
    private var started = false
    private var startupRetryCount = 0
    private let maxStartupRetryCount = 8
    private var reconnectWorkItem: DispatchWorkItem?
    private var isReloadingStatus = false
    private var statusDirectorySource: DispatchSourceFileSystemObject?
    private var statusDirectoryFD: CInt = -1

    init(channel: DistributionChannel) {
        self.channel = channel
    }

    deinit {
        statusDirectorySource?.cancel()
        reconnectWorkItem?.cancel()
    }

    var canRunRestore: Bool {
        helperAvailable && !status.isPaused && status.entitlementActive
    }

    func startupIfNeeded() {
        guard !started else {
            return
        }

        RuntimeConfiguration.setDistributionChannel(channel)
        HelperLauncher.ensureHelperRunning()
        refreshAutostartHealth()
        loadSharedStatusFallback()
        startStatusDirectoryWatcher()
        requestStatusRefresh(reason: "startup")
        started = true
    }

    func menuOpened() {
        if !helperAvailable {
            HelperLauncher.ensureHelperRunning()
        }
        refreshAutostartHealth()
        requestStatusRefresh(reason: "menu-open")
    }

    func reloadStatus() {
        if !helperAvailable {
            HelperLauncher.ensureHelperRunning()
        }
        refreshAutostartHealth()
        requestStatusRefresh(reason: "manual")
    }

    func setPaused(_ paused: Bool) {
        client.setPaused(paused) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure = result {
                    DaemonSharedIPC.postSetPaused(paused)
                }
                self.requestStatusRefresh(reason: "pause")
            }
        }
    }

    func restoreNow() {
        client.restoreNow(app: nil) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure = result {
                    DaemonSharedIPC.postRestoreNow(app: nil)
                }
                self.requestStatusRefresh(reason: "restore-now")
            }
        }
    }

    func clearSnapshot() {
        client.clearSnapshot(app: nil) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure = result {
                    DaemonSharedIPC.postClearSnapshot(app: nil)
                }
                self.requestStatusRefresh(reason: "clear-snapshot")
            }
        }
    }

    func grantFolderAccess() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Grant Folder Access"
        panel.message = "Select one or more folders that Office Resume may reopen documents from, such as Documents, OneDrive, or iCloud Drive."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK else {
            return
        }

        let selectedURLs = panel.urls
        guard !selectedURLs.isEmpty else {
            return
        }

        Task { @MainActor in
            do {
                let granted = try await folderAccessStore.grantDirectories(selectedURLs)
                DebugLog.info(
                    "Folder access grants updated",
                    metadata: ["count": "\(granted.count)"]
                )
                presentAlert(
                    title: "Folder Access Saved",
                    message: "Office Resume will reuse these folder grants during restore. Files under the selected roots should stop prompting on every reopen."
                )
            } catch {
                DebugLog.error(
                    "Failed to save folder access grants",
                    metadata: ["error": error.localizedDescription]
                )
                presentAlert(
                    title: "Folder Access Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    func openLoginItemsSettings() {
        let urls: [String] = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.users?LoginItems",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openDebugLogInConsole() {
        if !DebugLog.openLogInConsole() {
            DebugLog.warning("Failed to open debug log in Console")
        }
    }

    func openAccountWindow() {
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func quit() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        statusDirectorySource?.cancel()
        statusDirectorySource = nil
        HelperLauncher.requestHelperQuit()
        HelperLauncher.terminateHelperIfRunningAsync()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func requestStatusRefresh(reason: String) {
        guard !isReloadingStatus else {
            return
        }

        isReloadingStatus = true
        client.fetchStatus { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isReloadingStatus = false

                switch result {
                case let .success(status):
                    self.applyStatus(status, helperAvailable: true)
                    self.startupRetryCount = 0
                    self.reconnectWorkItem?.cancel()
                    self.reconnectWorkItem = nil
                case .failure:
                    self.loadSharedStatusFallback()
                    if !self.helperAvailable {
                        self.scheduleReconnectIfNeeded(reason: reason)
                    }
                }
            }
        }
    }

    private func applyStatus(_ status: DaemonStatusDTO, helperAvailable: Bool) {
        self.status = status
        self.helperAvailable = helperAvailable
    }

    private func loadSharedStatusFallback() {
        if let fallbackStatus = DaemonSharedIPC.loadStatus() {
            let running = fallbackStatus.helperRunning || isHelperProcessRunning()
            applyStatus(fallbackStatus, helperAvailable: running)
            if running {
                startupRetryCount = 0
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
            }
            return
        }

        helperAvailable = isHelperProcessRunning()
    }

    private func scheduleReconnectIfNeeded(reason: String) {
        guard started else {
            return
        }
        guard reconnectWorkItem == nil else {
            return
        }
        guard startupRetryCount < maxStartupRetryCount else {
            return
        }

        startupRetryCount += 1
        let delay = min(pow(2.0, Double(startupRetryCount - 1)) * 0.35, 4.0)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            DebugLog.debug("Retrying helper startup", metadata: ["reason": reason, "attempt": "\(self.startupRetryCount)"])
            self.requestStatusRefresh(reason: "reconnect")
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startStatusDirectoryWatcher() {
        guard statusDirectorySource == nil else {
            return
        }
        guard let directoryURL = try? ipcDirectoryURL() else {
            return
        }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            return
        }

        statusDirectoryFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.handleSharedStatusUpdate()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        statusDirectorySource = source
    }

    private func handleSharedStatusUpdate() {
        if let fallbackStatus = DaemonSharedIPC.loadStatus() {
            let running = fallbackStatus.helperRunning || isHelperProcessRunning()
            applyStatus(fallbackStatus, helperAvailable: running)
        } else {
            requestStatusRefresh(reason: "shared-status-update")
        }
    }

    private func ipcDirectoryURL() throws -> URL {
        try RuntimeConfiguration.appGroupOrFallbackRoot().appendingPathComponent("ipc", isDirectory: true)
    }

    private func isHelperProcessRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: HelperLauncher.helperBundleIdentifier).isEmpty
    }

    private func refreshAutostartHealth() {
        autostartHealthy = HelperLauncher.autostartHealth().isHealthy
    }

    private func presentAlert(title: String, message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
final class OfficeResumeAccountViewModel: ObservableObject {
    @Published var accountState = AccountState(
        email: nil,
        entitlement: EntitlementPolicy.inactiveState(),
        billingAction: nil,
        statusMessage: nil,
        canSignIn: true,
        canSignOut: false
    )
    @Published var emailInput = ""
    @Published var message: String?
    @Published var isWorking = false
#if DEBUG
    @Published var debugEntitlementBypassEnabled = RuntimeConfiguration.isDebugEntitlementBypassEnabled()
#endif

    let channel: DistributionChannel

    private let provider: AccountProvider
    private var started = false
    private var callbackObserver: NSObjectProtocol?

    init(channel: DistributionChannel) {
        self.channel = channel

        if let store = try? EntitlementFileStore() {
            self.provider = AccountProviderFactory.makeProvider(channel: channel, store: store)
        } else {
            self.provider = UnavailableAccountProvider(message: "Shared entitlement storage is unavailable.")
        }
    }

    deinit {
        if let callbackObserver {
            NotificationCenter.default.removeObserver(callbackObserver)
        }
    }

    var planDescription: String {
        switch accountState.entitlement.plan {
        case .trial:
            return accountState.entitlement.isActive ? "Trial" : "Inactive"
        case .monthly:
            return accountState.entitlement.isActive ? "Monthly" : "Inactive"
        case .yearly:
            return accountState.entitlement.isActive ? "Yearly" : "Inactive"
        case .none:
            return accountState.entitlement.isActive ? "Active" : "Inactive"
        }
    }

    var formattedValidUntil: String? {
        guard let date = accountState.entitlement.validUntil else {
            return nil
        }
        return Self.dateFormatter.string(from: date)
    }

    var formattedTrialEndsAt: String? {
        guard let date = accountState.entitlement.trialEndsAt else {
            return nil
        }
        return Self.dateFormatter.string(from: date)
    }

    func startupIfNeeded() {
        guard !started else {
            return
        }

        RuntimeConfiguration.setDistributionChannel(channel)
        callbackObserver = NotificationCenter.default.addObserver(
            forName: .officeResumeDidOpenURL,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let url = notification.object as? URL else {
                return
            }
            Task { @MainActor in
                self.handleIncomingURL(url)
            }
        }
        refresh()
        started = true
    }

    func refresh() {
        Task {
            await runAction {
                self.accountState = try await self.provider.refreshAccountState()
                self.message = self.accountState.statusMessage
                DaemonSharedIPC.postRefreshEntitlement()
            }
        }
    }

    func sendSignInLink() {
        let email = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            message = "Enter an email address first."
            return
        }

        Task {
            await runAction {
                try await self.provider.requestSignInLink(email: email)
                self.accountState = try await self.provider.refreshAccountState()
                if self.accountState.email == nil {
                    self.message = "Check your email for the sign-in link."
                } else {
                    self.message = "Signed in successfully."
                }
                DaemonSharedIPC.postRefreshEntitlement()
            }
        }
    }

    func openBillingAction() {
        Task {
            await runAction {
                guard let url = try await self.provider.billingActionURL() else {
                    self.message = "Billing action is not available."
                    return
                }
                _ = NSWorkspace.shared.open(url)
            }
        }
    }

    func signOut() {
        Task {
            await runAction {
                try await self.provider.signOut()
                self.accountState = await self.provider.currentAccountState()
                self.message = "Signed out."
                DaemonSharedIPC.postRefreshEntitlement()
            }
        }
    }

#if DEBUG
    func setDebugEntitlementBypassEnabled(_ enabled: Bool) {
        RuntimeConfiguration.setDebugEntitlementBypassEnabled(enabled)
        debugEntitlementBypassEnabled = enabled
        message = enabled ? "Local Debug Pass enabled." : "Local Debug Pass disabled."
        DaemonSharedIPC.postRefreshEntitlement()
        refresh()
    }
#endif

    private func handleIncomingURL(_ url: URL) {
        Task {
            await runAction {
                let handled = try await self.provider.handleIncomingURL(url)
                if handled {
                    self.accountState = try await self.provider.refreshAccountState()
                    self.emailInput = self.accountState.email ?? self.emailInput
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       components.queryItems?.contains(where: { $0.name == "action" && $0.value == "billingRefresh" }) == true {
                        self.message = "Billing status refreshed."
                    } else {
                        self.message = "Signed in successfully."
                    }
                    DaemonSharedIPC.postRefreshEntitlement()
                }
            }
        }
    }

    private func runAction(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await work()
        } catch {
            message = error.localizedDescription
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private actor UnavailableAccountProvider: AccountProvider {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func currentAccountState() async -> AccountState {
        AccountState(
            email: nil,
            entitlement: EntitlementPolicy.inactiveState(),
            billingAction: nil,
            statusMessage: message,
            canSignIn: false,
            canSignOut: false
        )
    }

    func refreshAccountState() async throws -> AccountState {
        await currentAccountState()
    }

    func requestSignInLink(email: String) async throws {
        _ = email
        throw EntitlementError.backendNotConfigured
    }

    func handleIncomingURL(_ url: URL) async throws -> Bool {
        _ = url
        return false
    }

    func billingActionURL() async throws -> URL? {
        throw EntitlementError.backendNotConfigured
    }

    func signOut() async throws {}
}
