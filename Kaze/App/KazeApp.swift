import SwiftUI

@main
struct KazeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Kaze lives in the menu bar; its windows are managed by AppDelegate.
        Settings { EmptyView() }
    }
}
