import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
