import SwiftUI

@main
struct FixBridgeApp: App {
    var body: some Scene {
        Window(Text(verbatim: "FixBridge"), id: "main") {
            FixBridgeView()
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentMinSize)
    }
}
