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

        let sampleStats = [
            "142,318 messages across 9.4 years of history",
            "214 conversations — you sent 71,204 of the messages",
            "Most-messaged: Hanan (31,442 messages)",
            "You text most around 9pm",
            "Median text length: 42 characters · 3,214 tapbacks given",
        ]
        let sampleInsights = [
            "- Dry, lowercase texting style with sparse but deliberate emoji",
            "- Trains for triathlons; coordinates long rides on weekends",
            "- Deeply engaged with AI tooling and benchmarks",
        ]
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

        ## Preferences & practical details
        Morning workouts, evening texting, Google Calendar for everything.
        """

        var states: [(String, AppModel)] = []
        func state(_ name: String, _ configure: (AppModel) -> Void) {
            let m = AppModel()
            configure(m)
            states.append((name, m))
        }

        state("1-grant")      { $0.stage = .needsGrant }
        state("2-ready")      { $0.stage = .ready }
        state("3-extracting") { m in
            m.stage = .extracting
            m.statLines = Array(sampleStats.prefix(3))
        }
        state("4-distill-download") { m in
            m.stage = .distilling
            m.statLines = sampleStats
            m.distillStatus = "Downloading Gemma (one-time, 3.3 GB)… 47%"
        }
        state("5-distill-progress") { m in
            m.stage = .distilling
            m.statLines = sampleStats
            m.chunkProgress = (3, 9)
            m.insightLines = sampleInsights
        }
        state("6-review-menu") { m in
            m.stage = .review
            m.profile = sampleProfile
        }
        state("7-failed") { m in
            m.stage = .failed("The bundled local-model runtime is missing — re-download the app from context.nikliolios.com, or install Ollama from ollama.com.")
        }

        for (name, model) in states {
            render(MenuContent(model: model), width: 340,
                   to: "\(outDir)/\(name).png")
        }

        let reviewModel = AppModel()
        reviewModel.stage = .review
        reviewModel.profile = sampleProfile
        render(ReviewWindow(model: reviewModel), width: 640, height: 560,
               to: "\(outDir)/8-review-window.png")

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
