import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window keeps the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct RBXMultiInstanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AccountStore
    @StateObject private var manager: InstanceManager
    @StateObject private var afk: AfkController

    init() {
        let s = AccountStore()
        let m = InstanceManager(store: s)
        _store = StateObject(wrappedValue: s)
        _manager = StateObject(wrappedValue: m)
        _afk = StateObject(wrappedValue: AfkController(manager: m))
    }

    var body: some Scene {
        Window("RBX Multi-Instance", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(afk)
        }
        .defaultSize(width: 900, height: 540)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(afk)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
            if !manager.instances.isEmpty {
                Text("\(manager.instances.count)")
            }
        }
    }
}
