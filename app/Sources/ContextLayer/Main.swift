import SwiftUI

@main
enum Entry {
    static func main() {
        // Headless pipeline for testing and scripting:
        //   ContextLayer --headless <chat.db path> [--out profile.md] [--no-distill]
        if CommandLine.arguments.contains("--headless") {
            Headless.run()
            return
        }
        if CommandLine.arguments.contains("--snapshot") {
            MainActor.assumeIsolated { Snapshot.run() }
            return
        }
        ContextLayerApp.main()
    }
}

struct ContextLayerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "person.text.rectangle")
        }
        .menuBarExtraStyle(.window)

        Window("Context Layer — Profile", id: "review") {
            ReviewWindow(model: model)
        }
        .defaultSize(width: 640, height: 560)
    }
}
