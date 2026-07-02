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

    /// The "c." logo mark as a template image: monochrome ink that the system
    /// recolors for light/dark menu bars and highlight states.
    static let barIcon: NSImage = {
        let candidates = [
            Bundle.main.resourcePath.map { $0 + "/menubar.png" },
            Bundle.main.executablePath.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
                    .appendingPathComponent("menubar.png").path
            },
        ].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18.5, height: 14)   // half of 46×35 → pt, ~18pt bar fit
                img.isTemplate = true
                return img
            }
        }
        let fallback = NSImage(systemSymbolName: "person.text.rectangle",
                               accessibilityDescription: "Context")!
        fallback.isTemplate = true
        return fallback
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: Self.barIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Context Layer — Profile", id: "review") {
            ReviewWindow(model: model)
        }
        .defaultSize(width: 640, height: 560)
    }
}
