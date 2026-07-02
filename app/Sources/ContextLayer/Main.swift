import ServiceManagement
import Sparkle
import SwiftUI

/// Sparkle auto-updater. Checks the appcast every 6h (Info.plist) and
/// installs updates in place — no more manual reinstalls.
@MainActor
enum Updater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    static func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}

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

    init() {
        // Start at login. Registered once; users can disable it anytime in
        // System Settings → General → Login Items. Skip for the bare dev
        // binary — only a real .app bundle can be a login item.
        if Bundle.main.bundlePath.hasSuffix(".app"),
           SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
        _ = Updater.controller   // start the update cycle
    }

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
