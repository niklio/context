import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.stage {
            case .needsGrant: grantView
            case .building: buildingView
            case .review: reviewView
            case .failed(let message): failedView(message)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    static let logo: NSImage = {
        // Resources/logo.png inside the .app; falls back to the icon next to
        // the bare binary (snapshot/headless runs), then the generic app icon.
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
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("Context").font(.headline)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Quit Context")
        }
    }

    // MARK: - Grant

    private var grantView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Open the button below", systemImage: "1.circle.fill")
                Label("Turn on **Context Layer** in the list", systemImage: "2.circle.fill")
                Label("Come back — it starts on its own", systemImage: "3.circle.fill")
            }
            .font(.callout)
            .labelStyle(StepLabelStyle())
            Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Building

    private var buildingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(.blue)
            HStack(alignment: .firstTextBaseline) {
                Text(model.statusText).font(.callout)
                Spacer()
                Text([model.etaText, "\(Int(model.progress * 100))%"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let fact = model.currentFact {
                Divider()
                Text(fact)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(fact)
                    .transition(.opacity)
                    .frame(minHeight: 36, alignment: .topLeading)
            }
        }
    }

    // MARK: - Review / upload

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your profile is ready", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))

            if let link = model.publishedURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text(link)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Open") { model.openPublishedURL() }
                            .buttonStyle(.borderedProminent)
                        Button(model.linkCopied ? "Copied" : "Copy link") {
                            model.copyPublishedURL()
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Button {
                    model.uploadProfile()
                } label: {
                    if model.uploading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Uploading…")
                        }.frame(maxWidth: .infinity)
                    } else {
                        Text("Upload & get your link").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.uploading)
                Text("Your link opens the Context web app, where you connect your assistants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Review profile first…") {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    // MARK: - Failed

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { model.retry() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct StepLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(.blue)
            configuration.title
        }
    }
}

struct ReviewWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Edit freely — this exact text is what gets uploaded and shared.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy inject block") { model.copyInjectionBlock() }
                Button(role: .destructive) { model.deleteProfile() } label: { Text("Delete profile") }
            }
            .padding(12)
            Divider()
            TextEditor(text: $model.profile)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .onChange(of: model.profile) { model.saveProfileEdits() }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
