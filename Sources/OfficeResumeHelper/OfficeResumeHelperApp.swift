import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeHelperApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Office Resume Helper")
                    .font(.headline)
                Text("Background monitoring scaffold target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 320)
        }
    }
}
