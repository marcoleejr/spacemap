import SwiftUI

@main
struct SpaceMapApp: App {
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
