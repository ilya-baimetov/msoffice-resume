import SwiftUI
import OfficeResumeCore

@main
struct OfficeResumeMASApp: App {
    @NSApplicationDelegateAdaptor(OfficeResumeApplicationDelegate.self) private var appDelegate
    @StateObject private var runtime = OfficeResumeAppRuntime(channel: .mas)

    var body: some Scene {
        OfficeResumeMenuScene(model: runtime.menuModel)
        OfficeResumeAccountScene(model: runtime.accountModel)
    }
}
