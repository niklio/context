import AppKit
import SwiftUI

/// Dev tool: render every UI state to PNGs without a display.
///   ContextLayer --snapshot [outdir]
@MainActor
enum Snapshot {
    static let sampleProfile = """
    # Your Profile

    ## Life context
    You live in NYC and work as a PM on AI personalization, and you're deep \
    in baby-registry research.

    ## Communication style
    Your texting is dry, lowercase, and direct — you reply with data and \
    links, not opinions.

    ## Relationships
    You coordinate household logistics with your partner and protect weekend \
    mornings for long rides with training friends.

    ## Interests
    Triathlon training, AI benchmarks, home automation.
    """

    static func run() {
        let args = CommandLine.arguments
        let outDir = args.indices.contains(2) && !args[2].hasPrefix("-")
            ? args[2] : "ui-snapshots"
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)

        var states: [(String, AppModel)] = []
        func state(_ name: String, _ configure: (AppModel) -> Void) {
            let m = AppModel()
            configure(m)
            states.append((name, m))
        }

        state("01-grant") { $0.stage = .needsGrant }
        state("02-building-download") { m in
            m.stage = .building
            m.progress = 0.28
            m.statusText = "Downloading the local model…"
            m.etaText = "~2 min"
            m.currentFact = "142,318 messages across 9.4 years of history"
        }
        state("03-building-distill") { m in
            m.stage = .building
            m.progress = 0.81
            m.statusText = "Distilling your profile…"
            m.etaText = "~40s"
            m.currentFact = "You plan long weekend rides with a tight group of training friends"
        }
        state("04-ready") { m in
            m.stage = .ready
            m.profile = sampleProfile
            m.mode = .auto
        }
        state("05-live-auto") { m in
            m.stage = .live
            m.profile = sampleProfile
            m.mode = .auto
            m.publishedURL = "https://context.nikliolios.com/p/63f6327db8c84a19b749e55ee15cc9"
            m.lastPublished = Date(timeIntervalSinceNow: -120)
        }
        state("06-update-pending") { m in
            m.stage = .updatePending
            m.profile = sampleProfile
            m.pendingProfile = sampleProfile.replacingOccurrences(
                of: "Triathlon training",
                with: "Half-Ironman training (this fall!)")
            m.newInsightCount = 3
            m.mode = .manual
        }
        state("07-live-manual") { m in
            m.stage = .live
            m.profile = sampleProfile
            m.mode = .manual
            m.publishedURL = "https://context.nikliolios.com/p/63f6327db8c84a19b749e55ee15cc9"
        }
        state("08-failed") { m in
            m.stage = .failed("Upload failed: the network connection was lost. Your profile is safe on this Mac — try again.")
        }

        for (name, model) in states {
            render(MenuContent(model: model), width: 340, to: "\(outDir)/\(name).png")
        }

        let reviewModel = AppModel()
        reviewModel.stage = .ready
        reviewModel.profile = sampleProfile
        render(ReviewWindow(model: reviewModel), width: 640, height: 520,
               to: "\(outDir)/09-review-window.png")

        print("snapshots written to \(outDir)/")
    }

    static func render(_ view: some View, width: CGFloat,
                       height: CGFloat? = nil, to path: String) {
        let hosting = NSHostingView(rootView: view)
        let fit = hosting.fittingSize
        let size = NSSize(width: width, height: height ?? max(fit.height, 80))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

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
