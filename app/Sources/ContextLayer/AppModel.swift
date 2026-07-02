import Foundation
import SwiftUI

enum Stage: Equatable {
    case needsGrant
    case ready
    case extracting
    case distilling
    case review
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var stage: Stage = .needsGrant
    @Published var dbPath = ChatDB.defaultPath
    @Published var statLines: [String] = []
    @Published var insightLines: [String] = []
    @Published var chunkProgress: (done: Int, total: Int) = (0, 0)
    @Published var distillStatus: String?
    @Published var profile: String = ""
    @Published var copiedAt: Date?

    private var grantTimer: Timer?

    init() {
        if let saved = ProfileStore.load() {
            profile = saved
            stage = .review
        } else {
            refreshGrant()
        }
    }

    // MARK: - Grant

    func refreshGrant() {
        stage = ChatDB.canRead(path: dbPath) ? .ready : .needsGrant
        if case .needsGrant = stage { startGrantPolling() }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        startGrantPolling()
    }

    /// The FDA toggle can't be prompted for; poll so the app springs to life
    /// the moment it flips.
    private func startGrantPolling() {
        grantTimer?.invalidate()
        grantTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .needsGrant = self.stage else {
                    self?.grantTimer?.invalidate(); return
                }
                if ChatDB.canRead(path: self.dbPath) {
                    self.grantTimer?.invalidate()
                    self.stage = .ready
                }
            }
        }
    }

    func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Choose a chat.db"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            dbPath = url.path
            refreshGrant()
        }
    }

    // MARK: - Pipeline

    func start() {
        stage = .extracting
        statLines = []
        insightLines = []
        chunkProgress = (0, 0)
        distillStatus = nil
        let path = dbPath

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ChatDB.extract(path: path)
                }.value
                let stats = CorpusStats.compute(result)

                // Reveal the local stats one by one — the wait is the demo.
                for line in stats.headlines {
                    statLines.append(line)
                    try? await Task.sleep(for: .milliseconds(600))
                }

                stage = .distilling
                let profileText = try await Distiller.run(result, stats: stats) { p in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if p.totalChunks > 0 {
                            self.chunkProgress = (p.completedChunks, p.totalChunks)
                            self.distillStatus = nil
                        }
                        if let status = p.status { self.distillStatus = status }
                        for insight in p.latestInsights where self.insightLines.count < 12 {
                            self.insightLines.append(insight)
                        }
                    }
                }
                profile = profileText
                ProfileStore.save(profileText)
                stage = .review
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Review / Inject

    func saveProfileEdits() {
        ProfileStore.save(profile)
    }

    func deleteProfile() {
        ProfileStore.delete()
        profile = ""
        refreshGrant()
    }

    func copyInjectionBlock() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProfileStore.injectionBlock(profile), forType: .string)
        copiedAt = Date()
    }

    func inject(into assistant: Assistant) {
        copyInjectionBlock()
        NSWorkspace.shared.open(assistant.url)
    }
}

enum Assistant: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case chatgpt = "ChatGPT"
    case gemini = "Gemini"

    var id: String { rawValue }
    var url: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/new")!
        case .chatgpt: return URL(string: "https://chatgpt.com/")!
        case .gemini: return URL(string: "https://gemini.google.com/app")!
        }
    }
}
