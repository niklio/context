import Foundation
import SwiftUI

enum Stage: Equatable {
    case needsGrant
    case accessLost     // had access, lost it (macOS update, toggle flipped)
    case building
    case ready          // built, never published
    case live           // published; mode governs how updates flow
    case updatePending  // manual mode: a rebuilt profile awaits LGTM
    case failed(String)
}

enum UpdateMode: String {
    case auto, manual
}

@MainActor
final class AppModel: ObservableObject {
    @Published var stage: Stage = .needsGrant
    @Published var mode: UpdateMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "updateMode") }
    }

    // building
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var etaText: String?
    @Published var currentFact: String?

    // profile + publication
    @Published var profile: String = ""
    @Published var pendingProfile: String?
    @Published var newInsightCount = 0
    @Published var publishedURL: String?
    @Published var lastPublished: Date?
    @Published var publishing = false

    var dbPath = ChatDB.defaultPath
    private var profileID: String? { didSet { defaults.set(profileID, forKey: "profileID") } }
    private var writeToken: String? { didSet { defaults.set(writeToken, forKey: "writeToken") } }
    private var lastBuilt: Date? { didSet { defaults.set(lastBuilt, forKey: "lastBuilt") } }

    private let defaults = UserDefaults.standard
    // The harness fully owns fact content and ordering (hot-reloadable);
    // the app is just a display loop over the most recent arrivals.
    private var recentFacts: [String] = []
    private var factIndex = 0
    private var factTimer: Timer?
    private var grantTimer: Timer?
    private var refreshTimer: Timer?
    private var rebuilding = false

    static let rebuildInterval: TimeInterval = 6 * 3600
    static let apiBase = "https://context.nikliolios.com"

    init() {
        mode = UpdateMode(rawValue: defaults.string(forKey: "updateMode") ?? "") ?? .auto
        publishedURL = defaults.string(forKey: "publishedURL")
        profileID = defaults.string(forKey: "profileID")
        writeToken = defaults.string(forKey: "writeToken")
        lastBuilt = defaults.object(forKey: "lastBuilt") as? Date
        lastPublished = defaults.object(forKey: "lastPublished") as? Date
        pendingProfile = ProfileStore.loadPending()
        newInsightCount = defaults.integer(forKey: "newInsightCount")

        if let saved = ProfileStore.load() {
            profile = saved
            if pendingProfile != nil { stage = .updatePending }
            else if publishedURL != nil { stage = .live }
            else { stage = .ready }
        } else if ChatDB.canRead(path: dbPath) {
            start()                  // access already granted: no idle state
        } else {
            stage = .needsGrant
            startGrantPolling()
        }
        startRefreshLoop()
    }

    // MARK: - Grant

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        startGrantPolling()
    }

    /// FDA can't be prompted for; poll, and the moment it flips resume on our
    /// own — granting access IS the start button.
    private func startGrantPolling() {
        grantTimer?.invalidate()
        grantTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let waiting = self.stage == .needsGrant || self.stage == .accessLost
                guard waiting else { self.grantTimer?.invalidate(); return }
                if ChatDB.canRead(path: self.dbPath) {
                    self.grantTimer?.invalidate()
                    if self.stage == .accessLost, !self.profile.isEmpty {
                        // Access restored: pick up where we left off.
                        self.stage = self.publishedURL != nil ? .live : .ready
                    } else {
                        self.start()
                    }
                }
            }
        }
    }

    // MARK: - First build (visible)

    private static let extractSlice = 0.06
    private static let downloadSlice = 0.49

    func start() {
        guard stage != .building else { return }
        clearPending()          // a regenerate supersedes any queued update
        stage = .building
        progress = 0
        statusText = "Reading your messages…"
        etaText = nil
        recentFacts = []; factIndex = 0; currentFact = nil
        startFactRotation()
        let path = dbPath

        Task {
            do {
                let built = try await buildProfile(path: path) { [weak self] update in
                    Task { @MainActor in self?.applyBuildProgress(update) }
                }
                profile = built
                ProfileStore.save(built)
                lastBuilt = Date()
                stopFactRotation()
                stage = .ready
            } catch {
                stopFactRotation()
                if case ChatDBError.notReadable = error {
                    stage = .accessLost
                    startGrantPolling()
                } else {
                    stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    private struct BuildProgress {
        var extractedStats: [String]?
        var distill: DistillProgress?
    }

    /// Shared by the visible first build and silent rebuilds.
    private nonisolated func buildProfile(
        path: String,
        onProgress: @escaping @Sendable (DistillProgress) -> Void
    ) async throws -> String {
        let result = try await Task.detached(priority: .userInitiated) {
            try ChatDB.extract(path: path)
        }.value
        let stats = CorpusStats.compute(result, names: Contacts.nameMap())
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.progress = max(self.progress, Self.extractSlice)
        }
        return try await Distiller.run(result, stats: stats, progress: onProgress)
    }

    private var distillStart = extractSlice
    private var downloadStart: Date?
    private var chunkTimes: [TimeInterval] = []
    private var lastChunkAt = Date()

    private func applyBuildProgress(_ p: DistillProgress) {
        guard case .building = stage else { return }
        // Facts are independent events — never gate them on other fields.
        if !p.latestInsights.isEmpty {
            for insight in p.latestInsights {
                recentFacts.append(insight.hasPrefix("- ") ? String(insight.dropFirst(2)) : insight)
            }
            recentFacts = Array(recentFacts.suffix(8))
            let freshest = p.latestInsights[0]
            factIndex = 0
            withAnimation(.easeInOut(duration: 0.4)) {
                currentFact = freshest.hasPrefix("- ")
                    ? String(freshest.dropFirst(2)) : freshest
            }
        }
        if let done = p.downloadCompleted, let total = p.downloadTotal, total > 0 {
            distillStart = Self.extractSlice + Self.downloadSlice
            if downloadStart == nil { downloadStart = Date() }
            let frac = Double(done) / Double(total)
            progress = Self.extractSlice + Self.downloadSlice * frac
            statusText = "Downloading the local model…"
            if let began = downloadStart, frac > 0.02 {
                let rate = Double(done) / Date().timeIntervalSince(began)
                etaText = Self.eta(seconds: Double(total - done) / max(rate, 1))
            }
        } else if p.totalChunks > 0 {
            // Progress ticks drive the bar and ETA; the harness owns statusText
            // via explicit status events.
            chunkTimes.append(Date().timeIntervalSince(lastChunkAt))
            lastChunkAt = Date()
            let frac = Double(p.completedChunks) / Double(p.totalChunks)
            progress = max(progress, distillStart + (0.98 - distillStart) * frac)
            let avg = chunkTimes.reduce(0, +) / Double(chunkTimes.count)
            etaText = Self.eta(seconds: avg * Double(p.totalChunks - p.completedChunks))
        } else if let status = p.status {
            statusText = status
        }
    }

    private static func eta(seconds: Double) -> String {
        seconds < 90 ? "~\(max(5, Int(seconds / 5) * 5))s" : "~\(Int((seconds / 60).rounded())) min"
    }

    // MARK: - Facts carousel

    private func startFactRotation() {
        factTimer?.invalidate()
        factTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceFact() }
        }
    }

    private func stopFactRotation() {
        factTimer?.invalidate(); factTimer = nil
    }

    private func advanceFact() {
        // Recycle the freshest arrivals (newest first) between new facts.
        let pool = Array(recentFacts.reversed())
        guard !pool.isEmpty else { return }
        let next = pool[factIndex % pool.count]
        factIndex += 1
        withAnimation(.easeInOut(duration: 0.4)) { currentFact = next }
    }

    // MARK: - Publish (LGTM)

    func lgtm() {
        if case .updatePending = stage, let pending = pendingProfile {
            profile = pending
            ProfileStore.save(pending)
            clearPending()
        }
        publish()
    }

    private func publish() {
        guard !publishing else { return }
        publishing = true
        Task {
            defer { publishing = false }
            do {
                if let id = profileID, let token = writeToken {
                    var req = URLRequest(url: URL(string: "\(Self.apiBase)/api/profiles/\(id)")!)
                    req.httpMethod = "PUT"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try JSONEncoder().encode(["profile": profile])
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 404 || code == 401 {         // expired/foreign: re-create
                        try await createRemote()
                    } else if code != 200 {
                        throw URLError(.badServerResponse)
                    }
                } else {
                    try await createRemote()
                    if let link = publishedURL, let url = URL(string: link) {
                        NSWorkspace.shared.open(url)         // first publish: show the page
                    }
                }
                lastPublished = Date()
                defaults.set(lastPublished, forKey: "lastPublished")
                stage = .live
            } catch {
                stage = .failed("Upload failed: \(error.localizedDescription). Your profile is safe on this Mac — try again.")
            }
        }
    }

    private func createRemote() async throws {
        var req = URLRequest(url: URL(string: "\(Self.apiBase)/api/profiles")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["profile": profile])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode([String: String].self, from: data),
              let link = parsed["url"] else { throw URLError(.badServerResponse) }
        publishedURL = link
        profileID = parsed["id"]
        writeToken = parsed["token"]
        defaults.set(link, forKey: "publishedURL")
    }

    // MARK: - Continuous updates

    private func startRefreshLoop() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeRebuild() }
        }
        Task { @MainActor in self.maybeRebuild() }
    }

    private func maybeRebuild() {
        // Detect revoked access from the resting states and surface recovery
        // guidance instead of failing generically later.
        if (stage == .live || stage == .ready || stage == .updatePending),
           !ChatDB.canRead(path: dbPath) {
            stage = .accessLost
            startGrantPolling()
            return
        }
        guard !rebuilding,
              stage == .live,   // don't stack on pending/ building/ failed
              ChatDB.canRead(path: dbPath),
              Date().timeIntervalSince(lastBuilt ?? .distantPast) > Self.rebuildInterval
        else { return }
        rebuilding = true
        let path = dbPath
        Task {
            defer { rebuilding = false }
            guard let fresh = try? await buildProfile(path: path, onProgress: { _ in }),
                  !fresh.isEmpty else { return }
            lastBuilt = Date()
            let count = Self.newSentenceCount(old: profile, new: fresh)
            guard count > 0 else { return }
            switch mode {
            case .auto:
                profile = fresh
                ProfileStore.save(fresh)
                publish()
            case .manual:
                pendingProfile = fresh
                ProfileStore.savePending(fresh)
                newInsightCount = count
                defaults.set(count, forKey: "newInsightCount")
                stage = .updatePending
            }
        }
    }

    /// Rough "N new insights": sentences present in the new profile only.
    static func newSentenceCount(old: String, new: String) -> Int {
        func sentences(_ s: String) -> Set<String> {
            Set(s.components(separatedBy: CharacterSet(charactersIn: ".\n"))
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { $0.count > 12 })
        }
        let fresh = sentences(new).subtracting(sentences(old))
        return fresh.count
    }

    private func clearPending() {
        pendingProfile = nil
        ProfileStore.deletePending()
        newInsightCount = 0
        defaults.removeObject(forKey: "newInsightCount")
    }

    // MARK: - Misc actions

    func switchToAutoAndPublishPending() {
        mode = .auto
        lgtm()
    }

    func openPublishedURL() {
        if let link = publishedURL, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func saveProfileEdits() {
        ProfileStore.save(profile)
        if stage == .live, mode == .auto { publish() }
    }

    func copyInjectionBlock() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProfileStore.injectionBlock(profile), forType: .string)
    }

    func deleteProfile() {
        ProfileStore.delete()
        clearPending()
        for key in ["publishedURL", "profileID", "writeToken", "lastPublished", "lastBuilt"] {
            defaults.removeObject(forKey: key)
        }
        if let id = profileID {
            Task {   // best-effort server delete
                var req = URLRequest(url: URL(string: "\(Self.apiBase)/api/profiles/\(id)")!)
                req.httpMethod = "DELETE"
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        publishedURL = nil; profileID = nil; writeToken = nil
        lastPublished = nil; lastBuilt = nil
        profile = ""
        stage = ChatDB.canRead(path: dbPath) ? .ready : .needsGrant
        if case .needsGrant = stage { startGrantPolling() } else { start() }
    }

    // MARK: - Failure reporting

    enum ReportState: Equatable { case idle, sending, sent(String), failed }
    @Published var reportState: ReportState = .idle

    private var stageDescription: String {
        switch stage {
        case .needsGrant: return "needs grant"
        case .accessLost: return "access lost"
        case .building: return "building (\(Int(progress * 100))% — \(statusText))"
        case .ready: return "ready (unpublished)"
        case .live: return "live (\(mode.rawValue))"
        case .updatePending: return "update pending"
        case .failed(let m): return "failed: \(m)"
        }
    }

    private func reportPayload(trigger: String) -> [String: String] {
        let logURL = HarnessRuntime.supportDir.appendingPathComponent("harness.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no harness.log)"
        var error = stageDescription
        if case .failed(let m) = stage { error = m }
        return [
            "trigger": trigger,
            "stage": stageDescription,
            "error": error,
            "log": String(log.suffix(150_000)),
            "appVersion": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": OllamaClient.model,
            "synthesisModel": OllamaClient.synthesisModel,
            "mode": mode.rawValue,
        ]
    }

    private func postReport(trigger: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(Self.apiBase)/api/reports")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(reportPayload(trigger: trigger))
        let (data, resp) = try await URLSession.shared.data(for: req)
        struct Ack: Decodable { let ok: Bool; let id: String }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let ack = try? JSONDecoder().decode(Ack.self, from: data), ack.ok
        else { throw URLError(.badServerResponse) }
        return ack.id
    }

    func reportFailure() {
        guard case .failed = stage, reportState != .sending else { return }
        reportState = .sending
        Task {
            do { reportState = .sent(try await postReport(trigger: "failure")) }
            catch { reportState = .failed }
        }
    }

    /// Settings-menu upload: works in any stage, including mid-build.
    func uploadLogs() {
        Task {
            let alert = NSAlert()
            do {
                let id = try await postReport(trigger: "manual")
                alert.messageText = "Logs uploaded"
                alert.informativeText = "Reference \(id.suffix(6)). Only diagnostics were sent — never your messages or profile."
            } catch {
                alert.messageText = "Upload failed"
                alert.informativeText = "Couldn't reach the server. Try again in a bit."
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func retry() {
        reportState = .idle
        if profile.isEmpty {
            if ChatDB.canRead(path: dbPath) { start() }
            else { stage = .needsGrant; startGrantPolling() }
        } else {
            stage = publishedURL != nil ? .live : .ready
        }
    }

    // MARK: - Snippet

    /// First ~60 words of the profile as plain prose (markdown stripped).
    static func snippet(of markdown: String, wordLimit: Int = 60) -> String {
        let prose = markdown.split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: " ")
        let words = prose.split(separator: " ")
        guard words.count > wordLimit else { return prose }
        return words.prefix(wordLimit).joined(separator: " ") + "… "
    }
}
