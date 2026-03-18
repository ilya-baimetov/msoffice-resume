import AppKit
import ApplicationServices
import Foundation
import OfficeResumeCore

final class AccessibilityObserverManager {
    typealias EventHandler = (OfficeApp, String, pid_t) -> Void

    private struct Entry {
        let app: OfficeApp
        let pid: pid_t
        let observer: AXObserver
        let applicationElement: AXUIElement
    }

    private let eventHandler: EventHandler
    private var entries: [pid_t: Entry] = [:]
    private let notifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXFocusedUIElementChangedNotification as CFString,
        kAXTitleChangedNotification as CFString,
    ]

    init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else {
            return
        }

        let manager = Unmanaged<AccessibilityObserverManager>.fromOpaque(refcon).takeUnretainedValue()
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(element, &pid)
        guard pidError == .success else {
            return
        }

        manager.handleNotification(named: notification as String, pid: pid)
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestTrustPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func syncObservedApplications() {
        let runningSupportedApps = NSWorkspace.shared.runningApplications.compactMap { runningApp -> (OfficeApp, NSRunningApplication)? in
            guard
                let app = OfficeBundleRegistry.app(for: runningApp.bundleIdentifier),
                app != .onenote,
                OfficeBundleRegistry.documentRestoreApps.contains(app) || OfficeBundleRegistry.lifecycleOnlyApps.contains(app)
            else {
                return nil
            }
            return (app, runningApp)
        }

        let expectedPIDs = Set(runningSupportedApps.map { $0.1.processIdentifier })
        for pid in Array(entries.keys) where !expectedPIDs.contains(pid) {
            detach(pid: pid)
        }

        for (app, runningApp) in runningSupportedApps {
            guard entries[runningApp.processIdentifier] == nil else {
                continue
            }
            attach(app: app, runningApplication: runningApp)
        }
    }

    func detachAll() {
        for pid in Array(entries.keys) {
            detach(pid: pid)
        }
    }

    private func attach(app: OfficeApp, runningApplication: NSRunningApplication) {
        let pid = runningApplication.processIdentifier
        var observer: AXObserver?
        let createResult = AXObserverCreate(pid, Self.observerCallback, &observer)
        guard createResult == .success, let observer else {
            DebugLog.warning(
                "Failed to create AX observer",
                metadata: [
                    "app": app.rawValue,
                    "pid": "\(pid)",
                    "error": "\(createResult.rawValue)",
                ]
            )
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for notification in notifications {
            let error = AXObserverAddNotification(observer, applicationElement, notification, refcon)
            switch error {
            case .success, .notificationAlreadyRegistered, .notificationUnsupported:
                continue
            default:
                DebugLog.debug(
                    "AX notification registration skipped",
                    metadata: [
                        "app": app.rawValue,
                        "pid": "\(pid)",
                        "notification": notification as String,
                        "error": "\(error.rawValue)",
                    ]
                )
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entries[pid] = Entry(app: app, pid: pid, observer: observer, applicationElement: applicationElement)

        DebugLog.debug(
            "AX observer attached",
            metadata: [
                "app": app.rawValue,
                "pid": "\(pid)",
            ]
        )
    }

    private func detach(pid: pid_t) {
        guard let entry = entries.removeValue(forKey: pid) else {
            return
        }

        for notification in notifications {
            _ = AXObserverRemoveNotification(entry.observer, entry.applicationElement, notification)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)

        DebugLog.debug(
            "AX observer detached",
            metadata: [
                "app": entry.app.rawValue,
                "pid": "\(pid)",
            ]
        )
    }

    private func handleNotification(named notification: String, pid: pid_t) {
        guard let entry = entries[pid] else {
            return
        }
        eventHandler(entry.app, notification, pid)
    }
}
