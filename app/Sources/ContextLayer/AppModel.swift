import Foundation
import SwiftUI

enum Stage: Equatable {
    case needsGrant
    case building
    case review
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var stage: Stage = .needsGrant

    // building
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var etaText: String?
    @Published var currentFact: String?

    // review
    @Published var profile: String = ""
    @Published var publishedURL: String? =
        UserDefaults.standard.string(forKey: "publishedURL")
    @Published var uploading = false
    @Published var linkCopied = false

    var dbPath = ChatDB.defaultPath
    private var facts: [String] = []
    private var factIndex = 0
    private var factTimer: Timer?
    private var grantTimer: Timer?

    init() {
        if let saved = ProfileStore.load() {
            profile = saved
            stage = .review
        } else if ChatDB.canRead(path: dbPath) {
            start()                  // access already granted: no idle state
        } else {
            stage = .needsGrant
            startGrantPolling()
        }
    }

    // MARK: - Grant

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        startGrantPolling()
    }

    /// The FDA toggle can't be prompted for; poll, and the moment it flips
    /// go straight to building — granting access IS the start button.
    private func startGrantPolling() {
        grantTimer?.invalidate()
        grantTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .needsGrant = self.stage else {
                    self?.grantTimer?.invalidate(); return
                }
                if ChatDB.canRead(path: self.dbPath) {
                    self.grantTimer?.invalidate()
                    self.start()
                }
            }
        }
    }

    // MARK: - Build pipeline

    // Progress layout: extract 0–6%, model download 6–55% (skipped when the
    // model is already present), distillation fills the remainder.
    private static let extractSlice = 0.06
    private static let downloadSlice = 0.49

    func start() {
        stage = .building
        progress = 0
        statusText = "Reading your messages…"
        etaText = nil
        facts = []
        currentFact = nil
        startFactRotation()
        let path = dbPath

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ChatDB.extract(path: path)
                }.value
                let stats = CorpusStats.compute(result)
                facts = stats.headlines
                advanceFact()
                progress = Self.extractSlice

                var distillStart = Self.extractSlice
                var downloadStart: Date?
                var chunkTimes: [TimeInterval] = []
                var lastChunkAt = Date()

                let profileText = try await Distiller.run(result, stats: stats) { p in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let done = p.downloadCompleted, let total = p.downloadTotal, total > 0 {
                            distillStart = Self.extractSlice + Self.downloadSlice
                            if downloadStart == nil { downloadStart = Date() }
                            let frac = Double(done) / Double(total)
                            self.progress = Self.extractSlice + Self.downloadSlice * frac
                            self.statusText = "Downloading the local model…"
                            if let began = downloadStart, frac > 0.02 {
                                let rate = Double(done) / Date().timeIntervalSince(began)
                                self.etaText = Self.eta(seconds: Double(total - done) / max(rate, 1))
                            }
                        } else if p.totalChunks > 0 {
                            chunkTimes.append(Date().timeIntervalSince(lastChunkAt))
                            lastChunkAt = Date()
                            let frac = Double(p.completedChunks) / Double(p.totalChunks)
                            self.progress = distillStart + (0.98 - distillStart) * frac
                            self.statusText = "Distilling your profile…"
                            let avg = chunkTimes.reduce(0, +) / Double(chunkTimes.count)
                            self.etaText = Self.eta(
                                seconds: avg * Double(p.totalChunks - p.completedChunks))
                            for insight in p.latestInsights {
                                self.facts.append(insight.hasPrefix("- ")
                                    ? String(insight.dropFirst(2)) : insight)
                            }
                            if !p.latestInsights.isEmpty {
                                // Surface the newest insight on the next tick.
                                self.factIndex = self.facts.count - 1
                            }
                        } else if let status = p.status {
                            self.statusText = status
                            self.etaText = nil
                            self.progress = max(self.progress, 0.98)
                        }
                    }
                }
                profile = profileText
                ProfileStore.save(profileText)
                stopFactRotation()
                stage = .review
            } catch {
                stopFactRotation()
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private static func eta(seconds: Double) -> String {
        seconds < 90 ? "~\(max(5, Int(seconds / 5) * 5))s left"
                     : "~\(Int((seconds / 60).rounded())) min left"
    }

    // MARK: - Facts carousel

    private func startFactRotation() {
        factTimer?.invalidate()
        factTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceFact() }
        }
    }

    private func stopFactRotation() {
        factTimer?.invalidate()
        factTimer = nil
    }

    private func advanceFact() {
        guard !facts.isEmpty else { return }
        let next = facts[factIndex % facts.count]
        factIndex += 1
        withAnimation(.easeInOut(duration: 0.4)) { currentFact = next }
    }

    // MARK: - Upload / review

    func uploadProfile() {
        guard !uploading else { return }
        uploading = true
        Task {
            defer { uploading = false }
            do {
                var req = URLRequest(url: URL(string: "https://context.nikliolios.com/api/profiles")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(["profile": profile])
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let parsed = try? JSONDecoder().decode([String: String].self, from: data),
                      let link = parsed["url"] else {
                    throw URLError(.badServerResponse)
                }
                publishedURL = link
                UserDefaults.standard.set(link, forKey: "publishedURL")
                NSWorkspace.shared.open(URL(string: link)!)
            } catch {
                stage = .failed("Upload failed: \(error.localizedDescription). Your profile is safe on this Mac — try again.")
            }
        }
    }

    func openPublishedURL() {
        if let link = publishedURL, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func copyPublishedURL() {
        guard let link = publishedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        linkCopied = true
    }

    func saveProfileEdits() { ProfileStore.save(profile) }

    func copyInjectionBlock() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProfileStore.injectionBlock(profile), forType: .string)
    }

    func deleteProfile() {
        ProfileStore.delete()
        UserDefaults.standard.removeObject(forKey: "publishedURL")
        publishedURL = nil
        profile = ""
        stage = ChatDB.canRead(path: dbPath) ? .review : .needsGrant
        if case .needsGrant = stage { startGrantPolling() }
    }

    func retry() {
        if ChatDB.canRead(path: dbPath) { start() }
        else { stage = .needsGrant; startGrantPolling() }
    }
}
