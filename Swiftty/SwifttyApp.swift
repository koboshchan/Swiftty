import SwiftUI

@main
struct SwifttyApp: App {
    var body: some Scene {
        WindowGroup("Swiftty") {
            WorkspaceView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_520, height: 920)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
