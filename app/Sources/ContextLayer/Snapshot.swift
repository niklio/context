import AppKit
import SwiftUI

/// Dev tool: render every UI state to PNGs without a display.
///   ContextLayer --snapshot [outdir]
/// Used for design review; states are staged with representative data.
@MainActor
enum Snapshot {
    static func run() {
        let args = CommandLine.arguments
        let outDir = args.indices.contains(2) && !args[2].hasPrefix("-")
            ? args[2] : "ui-snapshots"
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)

        let sampleProfile = """
        # Your Profile

        ## Life context
        You live in NYC and work as a product manager on AI personalization. \
        You're expecting a baby and are deep in registry research mode.

        ## Communication style
        Dry, direct, lowercase in casual threads. You answer questions with \
        data and links rather than opinions.

        ## Relationships
        You coordinate household logistics with your partner and keep a \
        tight group of training friends.

        ## Interests
        Triathlon training, AI benchmarks, home automation.
        """

        var states: [(String, AppModel)] = []
        func state(_ name: String, _ configure: (AppModel) -> Void) {
            let m = AppModel()
            m.stage = .needsGrant   // neutral before configure (init may auto-start)
            configure(m)
            states.append((name, m))
        }

        state("1-grant") { $0.stage = .needsGrant }
        state("2-building-download") { m in
            m.stage = .building
            m.progress = 0.29
            m.statusText = "Downloading the local model…"
            m.etaText = "~2 min left"
            m.currentFact = "142,318 messages across 9.4 years of history"
        }
        state("3-building-distill") { m in
            m.stage = .building
            m.progress = 0.81
            m.statusText = "Distilling your profile…"
            m.etaText = "~40s left"
            m.currentFact = "You plan long weekend rides with a tight group of training friends"
        }
        state("4-ready-upload") { m in
            m.stage = .review
            m.profile = sampleProfile
            m.publishedURL = nil
        }
        state("5-ready-linked") { m in
            m.stage = .review
            m.profile = sampleProfile
            m.publishedURL = "https://context.nikliolios.com/p/63f6327db8c84a19b749e55ee15cc9"
        }
        state("6-failed") { m in
            m.stage = .failed("Upload failed: the network connection was lost. Your profile is safe on this Mac — try again.")
        }

        for (name, model) in states {
            render(MenuContent(model: model), width: 340,
                   to: "\(outDir)/\(name).png")
        }

        let reviewModel = AppModel()
        reviewModel.stage = .review
        reviewModel.profile = sampleProfile
        render(ReviewWindow(model: reviewModel), width: 640, height: 560,
               to: "\(outDir)/7-review-window.png")

        print("snapshots written to \(outDir)/")
    }

    static func render(_ view: some View, width: CGFloat,
                       height: CGFloat? = nil, to path: String) {
        let hosting = NSHostingView(rootView: view)
        let fit = hosting.fittingSize
        let size = NSSize(width: width, height: height ?? max(fit.height, 80))

        // A real (borderless, never-shown) window gives SwiftUI a proper
        // environment: appearance, display scale, and a layout pass.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        // Second layout pass after intrinsic height settles.
        let settled = hosting.fittingSize
        if height == nil, settled.height > size.height {
            window.setContentSize(NSSize(width: width, height: settled.height))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: settled.height)
            hosting.layoutSubtreeIfNeeded()
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("snapshot failed: \(path)"); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("png encode failed: \(path)"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("  \(path) (\(Int(hosting.bounds.width))×\(Int(hosting.bounds.height)))")
    }
}
