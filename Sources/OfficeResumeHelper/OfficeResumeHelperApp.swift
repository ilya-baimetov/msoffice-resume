import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Office Resume Helper")
                    .font(.headline)
                Text("XPC listener + lifecycle monitor active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 320)
        }
    }
}
