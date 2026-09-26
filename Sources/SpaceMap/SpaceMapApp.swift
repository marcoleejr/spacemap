import AppKit
import SwiftUI

@main
struct SpaceMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 980)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Saves the scan cache before quitting without blocking the main thread:
    /// the app answers "later" and confirms once the background save is done.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = SpaceMapViewModel.current else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        model.saveCacheBeforeQuit(completion: reply)
        // Never hold the quit hostage to a slow disk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: reply)
        return .terminateLater
    }
}
