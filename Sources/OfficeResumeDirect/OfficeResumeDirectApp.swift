import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeDirectApp: App {
    @NSApplicationDelegateAdaptor(OfficeResumeApplicationDelegate.self) private var appDelegate
    @StateObject private var runtime = OfficeResumeAppRuntime(channel: .direct)

    var body: some Scene {
        OfficeResumeMenuScene(model: runtime.menuModel)
        OfficeResumeAccountScene(model: runtime.accountModel)
    }
}
