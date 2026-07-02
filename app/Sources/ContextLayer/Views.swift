import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            switch model.stage {
            case .needsGrant: grantView
            case .accessLost: accessLostView
            case .building: buildingView
            case .ready: readyView
            case .live: liveView
            case .updatePending: pendingView
            case .failed(let message): failedView(message)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.cream)
        .foregroundStyle(Theme.ink)
    }

    // MARK: - Header

    static let logo: NSImage = {
        let candidates = [
            Bundle.main.resourcePath.map { $0 + "/logo.png" },
            Bundle.main.executablePath.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
                    .appendingPathComponent("logo.png").path
            },
        ].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let img = NSImage(contentsOfFile: path) { return img }
        }
        return NSApp.applicationIconImage
    }()

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.logo)
                .resizable().interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Context").font(.system(size: 15, weight: .bold))
            Spacer()
            Menu {
                Button("Regenerate profile") { model.start() }
                    .disabled(model.stage == .building)
                Button("Check for Updates…") { Updater.checkNow() }
                Divider()
                Button("About") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .light))
                    .foregroundStyle(Theme.ink)   // match header text; menu styles override subtler colors
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
    }

    // MARK: - Grant

    private var grantView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                step(1, Text("Click ") + Text("Open Full Disk Access Settings").bold()
                        + Text(" below"))
                step(2, Text("Find ") + Text("Context").bold()
                        + Text(" in the list and flip it on. Not there? Click ")
                        + keycap("+") + Text(" and pick it from Applications"))
                step(3, Text("Come straight back — Context starts on its own"))
            }
            .padding(.bottom, 16)
            Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(PrimaryButtonStyle())
            waitingHint(
                "Waiting for access… macOS requires you to flip this switch yourself; Context can't do it for you. Your messages never leave this Mac.")
        }
    }

    private var accessLostView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
                    .padding(.top, 2)
                (Text("Context lost access to Messages. ").bold()
                    + Text("This usually happens after a macOS update or if the toggle was switched off."))
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(Color(hex: 0x7A5A34))
            .padding(10)
            .background(Color(hex: 0xF7EAD9), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(Color(hex: 0xECD3B3), lineWidth: 1.5))
            .padding(.bottom, 13)

            VStack(alignment: .leading, spacing: 14) {
                step(1, Text("Click ") + Text("Open Full Disk Access Settings").bold()
                        + Text(" below"))
                step(2, Text("Find ") + Text("Context").bold()
                        + Text(" and flip it back on. Already on? Flip it off and on again"))
                step(3, Text("Come back — updates resume, your profile and link are untouched"))
            }
            .padding(.bottom, 16)
            Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(PrimaryButtonStyle())
            waitingHint("Watching for access to come back…")
        }
    }

    private func step(_ n: Int, _ label: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.blue, in: Circle())
            label
                .font(.system(size: 13.5))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keycap(_ s: String) -> Text {
        Text(s).bold().foregroundColor(Theme.ink)
    }

    private func waitingHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Circle().fill(Theme.blue).frame(width: 7, height: 7)
                .padding(.top, 3.5)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 9)
    }

    // MARK: - Building

    private var buildingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressBar(value: model.progress)
            HStack(alignment: .firstTextBaseline) {
                Text(model.statusText).font(.system(size: 14))
                Spacer()
                Text([model.etaText, "\(Int(model.progress * 100))%"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 11)
            if let fact = model.currentFact {
                Rectangle().fill(Theme.line).frame(height: 1)
                    .padding(.vertical, 12)
                Text(fact)
                    .font(.system(size: 13.5).italic())
                    .foregroundStyle(Theme.fact)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 34, alignment: .topLeading)
                    .id(fact)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Ready (built, unpublished)

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressBar(value: 1, complete: true)
            Caption(text: "Your profile").padding(.top, 11).padding(.bottom, 5)
            snippetText(model.profile)
            lgtmButton.padding(.top, 14)
            modeLine(prefix: model.mode == .auto ? "Then auto-update" : "Then manual approval",
                     showSwitchToAuto: false)
        }
    }

    // MARK: - Live (published, resting)

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressBar(value: 1, complete: true)
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Theme.green).frame(width: 8, height: 8)
                    Caption(text: model.mode == .auto
                            ? "Live · auto-updating" : "Live · you approve updates",
                            color: Theme.green)
                }
                Spacer()
                Text(model.mode == .auto ? relativeUpdated : "up to date")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 11).padding(.bottom, 5)
            snippetText(model.profile)
            linkCard.padding(.top, 12)
        }
    }

    private var relativeUpdated: String {
        guard let date = model.lastPublished else { return "" }
        let mins = max(0, Int(-date.timeIntervalSinceNow / 60))
        if mins < 1 { return "updated just now" }
        if mins < 60 { return "updated \(mins)m ago" }
        if mins < 60 * 24 { return "updated \(mins / 60)h ago" }
        return "updated \(mins / 1440)d ago"
    }

    private var linkCard: some View {
        HStack(spacing: 10) {
            Text(displayLink)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.fact)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Open") { model.openPublishedURL() }
                .buttonStyle(SmallButtonStyle())
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1.5))
    }

    private var displayLink: String {
        (model.publishedURL ?? "")
            .replacingOccurrences(of: "https://", with: "")
    }

    // MARK: - Update pending (manual)

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressBar(value: 1, complete: true)
            Caption(text: model.newInsightCount > 0
                    ? "Updated profile · \(model.newInsightCount) new insight\(model.newInsightCount == 1 ? "" : "s")"
                    : "Updated profile")
                .padding(.top, 11).padding(.bottom, 5)
            snippetText(model.pendingProfile ?? model.profile)
            lgtmButton.padding(.top, 14)
            modeLine(prefix: "Or", showSwitchToAuto: true)
        }
    }

    // MARK: - Failed

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.orange)
                Text("Something went wrong")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.orange)
            }
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.fact)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { model.retry() }
                .buttonStyle(PrimaryButtonStyle())
            switch model.reportState {
            case .idle:
                Button("Report to developer") { model.reportFailure() }
                    .buttonStyle(GhostButtonStyle())
                    .frame(maxWidth: .infinity)
            case .sending:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Sending report…")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
            case .sent(let id):
                Text("Reported — reference \(id.suffix(6)). Only diagnostics were sent, never your messages or profile.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                Button("Report failed — try again") { model.reportFailure() }
                    .buttonStyle(GhostButtonStyle(tint: Theme.orange))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Shared pieces

    private func snippetText(_ text: String) -> some View {
        // "see more" is a real inline link so only IT is tappable, not the
        // whole snippet. The custom scheme is intercepted below.
        var snippet = AttributedString(AppModel.snippet(of: text))
        snippet.foregroundColor = Theme.body
        var more = AttributedString(" see more")
        more.foregroundColor = Theme.blue
        more.font = .system(size: 13, weight: .semibold)
        more.link = URL(string: "contextlayer://review")!
        return Text(snippet + more)
            .font(.system(size: 13))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "contextlayer" else { return .systemAction }
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
                return .handled
            })
    }

    private var lgtmButton: some View {
        Button {
            model.lgtm()
        } label: {
            if model.publishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).colorInvert()
                    Text("Publishing…")
                }
            } else {
                Text("LGTM 🚀")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.publishing)
    }

    private func modeLine(prefix: String, showSwitchToAuto: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.muted)
            if showSwitchToAuto {
                Text(prefix).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("switch to auto-update") { model.switchToAutoAndPublishPending() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .underline(true, pattern: .dot, color: Theme.line)
            } else {
                Text("\(prefix) ·").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Menu {
                    Button {
                        model.mode = .auto
                    } label: {
                        Label("Auto-update — new insights publish automatically",
                              systemImage: model.mode == .auto ? "checkmark" : "bolt.fill")
                    }
                    Button {
                        model.mode = .manual
                    } label: {
                        Label("Manual approval — review each update first",
                              systemImage: model.mode == .manual ? "checkmark" : "clock")
                    }
                } label: {
                    Text("change")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .underline(true, pattern: .dot, color: Theme.line)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.top, 9)
    }
}

// MARK: - Review window

struct ReviewWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var editingPending: Bool {
        if case .updatePending = model.stage, model.pendingProfile != nil { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: editingPending
                       ? Binding(get: { model.pendingProfile ?? "" },
                                 set: { model.pendingProfile = $0; ProfileStore.savePending($0) })
                       : Binding(get: { model.profile },
                                 set: { model.profile = $0; ProfileStore.save($0) }))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(14)
                .background(Theme.card)

            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Button("Copy") { model.copyInjectionBlock() }
                    .buttonStyle(GhostButtonStyle())
                Button("Delete profile") { model.deleteProfile(); dismiss() }
                    .buttonStyle(GhostButtonStyle(tint: Color(hex: 0xB3543F)))
                Spacer()
                Button("Done") {
                    if model.stage == .live, model.mode == .auto { model.saveProfileEdits() }
                    dismiss()
                }
                .buttonStyle(SmallButtonStyle())
            }
            .padding(12)
            .background(Theme.cream)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.cream)
    }
}
