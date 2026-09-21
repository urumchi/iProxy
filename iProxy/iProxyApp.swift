import AppKit
import SwiftUI

/// Swift Package executables are launched as command-line processes rather
/// than an app bundle. Explicitly opt into the regular AppKit activation policy
/// so `swift run` gets a visible, foreground window.
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct IProxyApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("iProxy") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 700, minHeight: 460)
        }
    }
}
