import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch model.stage {
            case .needsGrant: grantView
            case .ready: readyView
            case .extracting: extractingView
            case .distilling: distillingView
            case .review: reviewSummaryView
            case .failed(let message): failedView(message)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.text.rectangle")
            Text("Context Layer").font(.headline)
            Spacer()
        }
    }

    // MARK: - Stages

    private var grantView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your profile is built from your own Messages history — everything stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Text("macOS requires you to grant Full Disk Access by hand:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                Label("Click the button below", systemImage: "1.circle")
                Label("Find **Context Layer** in the list, flip it on", systemImage: "2.circle")
                Label("Come back — the app notices instantly", systemImage: "3.circle")
            }.font(.callout)
            Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Messages access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Ready to read your history, distill it into a profile you review, and hand it to your assistants. Raw messages never leave this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Build my profile") { model.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var extractingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your history…").font(.callout)
            }
            statStream
        }
    }

    private var distillingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.distillStatus
                     ?? (model.chunkProgress.total > 0
                         ? "Distilling with Gemma (on-device)… \(model.chunkProgress.done)/\(model.chunkProgress.total)"
                         : "Distilling with Gemma (on-device)…"))
                    .font(.callout)
            }
            statStream
            if !model.insightLines.isEmpty {
                Divider()
                ForEach(model.insightLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var statStream: some View {
        ForEach(model.statLines, id: \.self) { line in
            Label(line, systemImage: "sparkle").font(.caption)
        }
    }

    private var reviewSummaryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your profile is ready", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Review it word-for-word, edit or delete anything, then hand it to your assistants.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Review & edit profile") { openWindow(id: "review"); NSApp.activate(ignoringOtherApps: true) }
                .buttonStyle(.borderedProminent)
            HStack {
                ForEach(Assistant.allCases) { assistant in
                    Button(assistant.rawValue) { model.inject(into: assistant) }
                }
            }
            Text(model.copiedAt != nil
                 ? "Profile copied — paste into the chat that just opened."
                 : "Buttons copy your profile and open the assistant — just paste.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Rebuild from Messages") { model.start() }
                .buttonStyle(.link).font(.caption)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Try again") { model.refreshGrant() }
        }
    }

    private var footer: some View {
        HStack {
            Button("Choose database…") { model.chooseDatabase() }
                .buttonStyle(.link).font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.link).font(.caption)
        }
    }
}

struct ReviewWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your profile — edit freely; this exact text is what gets shared.")
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
