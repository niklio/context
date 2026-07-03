import Foundation

/// The app side of distillation: a stable local runtime. It manages the
/// bundled model server and hands the corpus to the hot-reloadable harness
/// script (see HarnessRuntime), which contains the entire pipeline.
enum DistillError: LocalizedError {
    case ollamaNotFound
    case ollamaFailed(String)

    var errorDescription: String? {
        switch self {
        case .ollamaNotFound:
            return "The bundled local-model runtime is missing — re-download the app from context.nikliolios.com, or install Ollama from ollama.com."
        case .ollamaFailed(let m):
            return "Distillation failed: \(m)"
        }
    }
}

struct DistillProgress {
    var completedChunks: Int = 0
    var totalChunks: Int = 0
    var latestInsights: [String] = []
    var status: String?
    var downloadCompleted: Int64?
    var downloadTotal: Int64?
}

// MARK: - Ollama client

struct OllamaClient {
    // Dedicated port: never adopt a stranger's (possibly orphaned) server on
    // the default 11434 — an ollama spawned by a deleted app install keeps
    // running but can't start its inference worker (binary gone).
    static let port = 11435
    static let baseURL = URL(string: "http://127.0.0.1:11435")!
    static var model: String {
        ProcessInfo.processInfo.environment["CL_MODEL"] ?? "gemma3:4b"
    }
    /// The synthesis stages are where reasoning quality is decided — they get
    /// their own knob so they can run a bigger model while extraction stays 4B.
    static var synthesisModel: String {
        ProcessInfo.processInfo.environment["CL_SYNTH_MODEL"] ?? model
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    static let pullSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 86_400
        return URLSession(configuration: cfg)
    }()

    static func binaryPath() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("ollama").path {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                       "/Applications/Ollama.app/Contents/Resources/ollama"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isUp() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        req.timeoutInterval = 2
        return (try? await session.data(for: req)) != nil
    }

    static let numParallel = 4
    private static var markerURL: URL {
        HarnessRuntime.supportDir.appendingPathComponent("server.json")
    }

    static func ensureServer() async throws {
        if await isUp() {
            // Reuse only if it was spawned with the current config; an older
            // server of ours decodes serially and would silently queue.
            if let data = try? Data(contentsOf: markerURL),
               let marker = try? JSONDecoder().decode([String: Int].self, from: data),
               marker["parallel"] == numParallel {
                return
            }
            killServerOnPort()
            try? await Task.sleep(for: .seconds(1))
        }
        guard let bin = binaryPath() else { throw DistillError.ollamaNotFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(port)"
        env["OLLAMA_NUM_PARALLEL"] = "\(numParallel)"
        env["OLLAMA_KEEP_ALIVE"] = "30m"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if await isUp() {
                let marker = try? JSONEncoder().encode(["parallel": numParallel])
                try? marker?.write(to: markerURL)
                return
            }
        }
        throw DistillError.ollamaFailed("couldn't start the Ollama server")
    }

    /// Kill whatever owns our port (an out-of-date instance of our own server).
    static func killServerOnPort() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        try? lsof.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { kill(pid, SIGKILL) }
        }
    }

    static func hasModel() async throws -> Bool {
        let (data, _) = try await session.data(
            from: baseURL.appendingPathComponent("api/tags"))
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M]? }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return (tags.models ?? []).contains {
            $0.name == model || $0.name.hasPrefix(model + ":")
        }
    }

    static func pullModel(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (bytes, _) = try await pullSession.bytes(for: req)
        struct Line: Decodable {
            let status: String?; let total: Int64?; let completed: Int64?; let error: String?
        }
        var lastPct = -1
        for try await line in bytes.lines {
            guard let parsed = try? JSONDecoder().decode(Line.self, from: Data(line.utf8))
            else { continue }
            if let err = parsed.error { throw DistillError.ollamaFailed(err) }
            if let total = parsed.total, let done = parsed.completed, total > 0 {
                let pct = Int(done * 100 / total)
                if pct != lastPct { lastPct = pct; progress(done, total) }
            }
        }
    }

    /// Kill ollama processes whose executable no longer exists on disk —
    /// orphans from deleted app bundles. They hold the port and fail every
    /// generate with "llama-server binary not found".
    static func killOrphanedServers() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        ps.arguments = ["-fl", "ollama"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let cmd = String(parts[1])
            guard let binPath = cmd.split(separator: " ").first.map(String.init),
                  binPath.hasPrefix("/"),
                  !FileManager.default.fileExists(atPath: binPath) else { continue }
            kill(pid, SIGKILL)
        }
    }

    /// One tiny generate to prove the server can actually run inference; on
    /// the orphaned-server failure, sweep and respawn once.
    static func warmup() async throws {
        do {
            _ = try await generateRaw(prompt: "hi", modelName: model, numPredict: 1)
        } catch {
            killOrphanedServers()
            try? await Task.sleep(for: .seconds(1))
            try await ensureServer()
            _ = try await generateRaw(prompt: "hi", modelName: model, numPredict: 1)
        }
    }

    static func generate(prompt: String, model modelName: String? = nil) async throws -> String {
        try await generateRaw(prompt: prompt, modelName: modelName ?? model, numPredict: nil)
    }

    private static func generateRaw(prompt: String, modelName: String,
                                    numPredict: Int?) async throws -> String {
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        do {
            let out = try await generateRawInner(prompt: prompt, modelName: modelName,
                                                 numPredict: numPredict)
            Trajectory.record(model: modelName, prompt: prompt,
                              response: out, error: nil, ms: elapsed())
            return out
        } catch {
            Trajectory.record(model: modelName, prompt: prompt, response: nil,
                              error: error.localizedDescription, ms: elapsed())
            throw error
        }
    }

    private static func generateRawInner(prompt: String, modelName: String,
                                         numPredict: Int?) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        var options: [String: Any] = ["num_ctx": 16384, "temperature": 0.3]
        if let n = numPredict { options["num_predict"] = n }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "prompt": prompt,
            "stream": false,
            "options": options,
        ] as [String: Any])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            throw DistillError.ollamaFailed(String(body.prefix(300)))
        }
        struct Gen: Decodable { let response: String? ; let error: String? }
        let gen = try JSONDecoder().decode(Gen.self, from: data)
        if let err = gen.error { throw DistillError.ollamaFailed(err) }
        return gen.response ?? ""
    }
}

// MARK: - Distiller (runtime glue)

enum Distiller {
    static func run(_ result: ExtractionResult, stats: CorpusStats,
                    progress: @escaping @Sendable (DistillProgress) -> Void) async throws -> String {
        Trajectory.rotate()
        try await OllamaClient.ensureServer()
        if !(try await OllamaClient.hasModel()) {
            try await OllamaClient.pullModel { done, total in
                progress(DistillProgress(downloadCompleted: done, downloadTotal: total))
            }
        }

        progress(DistillProgress(status: "Warming up the local model…"))
        try await OllamaClient.warmup()

        let (script, origin) = await HarnessRuntime.loadScript()
        progress(DistillProgress(status: "Studying your conversations…"))

        let corpus = CorpusIndex(chats: result.chats,
                                 names: Contacts.nameMap(),
                                 headlines: stats.headlines)
        let callbacks = HarnessRuntime.Callbacks(
            status: { progress(DistillProgress(status: $0)) },
            fact: { progress(DistillProgress(latestInsights: [$0.hasPrefix("- ") ? $0 : "- \($0)"])) },
            progress: { done, total in
                progress(DistillProgress(completedChunks: done, totalChunks: total))
            })

        // The harness blocks its thread on model calls — run it off-actor.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let profile = try HarnessRuntime.execute(
                        script: script, origin: origin, corpus: corpus, callbacks: callbacks)
                    cont.resume(returning: profile)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Shared helpers (used by CorpusIndex)

    static func displayName(for chat: Chat, names: [String: String]) -> String {
        if let dn = chat.displayName, !dn.isEmpty { return dn }
        if !chat.isGroup, let resolved = Contacts.resolve(chat.identifier, in: names) {
            return resolved
        }
        if chat.isGroup {
            let members = chat.participants
                .map { Contacts.resolve($0, in: names) ?? $0 }
                .prefix(4).joined(separator: ", ")
            return "Group: \(members)"
        }
        return chat.identifier
    }

    static func period(of chat: Chat) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM yyyy"
        guard let first = chat.messages.first?.date, let last = chat.messages.last?.date
        else { return "" }
        let a = df.string(from: first), b = df.string(from: last)
        return a == b ? a : "\(a)–\(b)"
    }
}
