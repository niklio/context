import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            switch model.stage {
            case .needsGrant: grantView
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
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Quit Context")
        }
    }

    // MARK: - Grant

    private var grantView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                step(1, Text("Open the button below"))
                step(2, Text("Turn on ") + Text("Context Layer").bold() + Text(" in the list"))
                step(3, Text("Come back — it starts on its own"))
            }
            .padding(.bottom, 4)
            Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func step(_ n: Int, _ label: Text) -> some View {
        HStack(spacing: 9) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.blue, in: Circle())
            label.font(.system(size: 14))
        }
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
        }
    }

    // MARK: - Shared pieces

    private func snippetText(_ text: String) -> some View {
        (Text(AppModel.snippet(of: text))
            + Text(" see more")
                .foregroundColor(Theme.blue)
                .fontWeight(.semibold))
            .font(.system(size: 13))
            .foregroundStyle(Theme.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            }
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
