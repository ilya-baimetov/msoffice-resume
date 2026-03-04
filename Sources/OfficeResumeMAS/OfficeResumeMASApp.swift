import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeMASApp: App {
    var body: some Scene {
        MenuBarExtra("Office Resume", systemImage: "arrow.clockwise.circle") {
            ContentView(channel: "MAS")
        }
    }
}

private struct ContentView: View {
    let channel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Office Resume")
                .font(.headline)
            Text("Channel: \(channel)")
                .font(.subheadline)
            Text("Scaffold build. Core restore logic will be added in upcoming slices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320)
    }
}
