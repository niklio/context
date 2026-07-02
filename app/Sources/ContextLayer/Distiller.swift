import Foundation

/// Map-reduce distillation of the message corpus into a portable profile,
/// running entirely on-device via Ollama + Gemma. Raw messages go to the
/// local model in chunks; nothing leaves the machine.
enum DistillError: LocalizedError {
    case ollamaNotFound
    case ollamaFailed(String)

    var errorDescription: String? {
        switch self {
        case .ollamaNotFound:
            return "Ollama not found. Install it from ollama.com — the profile is distilled by Gemma running locally, so nothing leaves this Mac."
        case .ollamaFailed(let m):
            return "Distillation failed: \(m)"
        }
    }
}

struct DistillProgress {
    var completedChunks: Int = 0
    var totalChunks: Int = 0
    var latestInsights: [String] = []
    var status: String?          // e.g. model download progress
}

// MARK: - Ollama client

struct OllamaClient {
    static let baseURL = URL(string: "http://127.0.0.1:11434")!
    static var model: String {
        ProcessInfo.processInfo.environment["CL_MODEL"] ?? "gemma3:4b"
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    static func binaryPath() -> String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
         "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isUp() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        req.timeoutInterval = 2
        return (try? await session.data(for: req)) != nil
    }

    /// Start `ollama serve` if it isn't already running.
    static func ensureServer() async throws {
        if await isUp() { return }
        guard let bin = binaryPath() else { throw DistillError.ollamaNotFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if await isUp() { return }
        }
        throw DistillError.ollamaFailed("couldn't start the Ollama server")
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

    /// Pull the model, streaming download progress (first run only).
    static func pullModel(progress: @escaping @Sendable (String) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (bytes, _) = try await session.bytes(for: req)
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
                if pct != lastPct {
                    lastPct = pct
                    let gb = Double(total) / 1_073_741_824
                    progress("Downloading Gemma (one-time, \(String(format: "%.1f", gb)) GB)… \(pct)%")
                }
            } else if let status = parsed.status, status != "success" {
                progress(status)
            }
        }
    }

    static func generate(prompt: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["num_ctx": 16384, "temperature": 0.3],
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

// MARK: - Distiller

enum Distiller {
    static let maxChats = 40             // top chats by volume
    static let maxMessagesPerChat = 400  // most recent
    static let chunkCharBudget = 20_000  // ~5k tokens, comfortably inside num_ctx
    static let maxChunks = 24
    static let mapConcurrency = 2        // ollama queues server-side anyway
    static let reduceBatchSize = 60      // observations per reduce round

    // MARK: Chunking

    static func buildChunks(_ result: ExtractionResult) -> [String] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var chunks: [String] = []
        var current = ""
        for chat in result.chats.prefix(maxChats) {
            let recent = chat.messages.suffix(maxMessagesPerChat)
            var lines = ["## Conversation with \(chat.displayName ?? chat.identifier)"
                         + (chat.isGroup ? " (group: \(chat.participants.joined(separator: ", ")))" : "")]
            for m in recent {
                guard let text = m.text, !text.isEmpty, !m.isSystemEvent else { continue }
                let who = m.isFromMe ? "Me" : (m.sender ?? "them")
                if let tb = m.tapback {
                    lines.append("[\(df.string(from: m.date))] \(who): (\(tb) a message)")
                } else {
                    lines.append("[\(df.string(from: m.date))] \(who): \(text)")
                }
            }
            guard lines.count > 1 else { continue }
            let block = lines.joined(separator: "\n") + "\n\n"

            if current.count + block.count > chunkCharBudget && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            // A single huge conversation gets split across chunks.
            if block.count > chunkCharBudget {
                var rest = Substring(block)
                while !rest.isEmpty {
                    let take = rest.prefix(chunkCharBudget)
                    chunks.append(String(take))
                    rest = rest.dropFirst(take.count)
                }
            } else {
                current += block
            }
            if chunks.count >= maxChunks { break }
        }
        if !current.isEmpty && chunks.count < maxChunks { chunks.append(current) }
        return Array(chunks.prefix(maxChunks))
    }

    // MARK: Prompts

    static func mapPrompt(chunk: String) -> String {
        """
        You are analyzing a person's own message history to build a profile OF THAT PERSON \
        (the "Me" lines are them). This runs locally on their machine at their request.

        From the transcript below, extract concise observations about "Me" ONLY — not dossiers \
        on the other people. Cover, where evidenced: communication style and voice (formality, \
        humor, emoji/punctuation habits), relationships in role terms only (e.g. "has a close \
        friend they train with"), interests and activities, life context (city, work domain, \
        family stage), preferences and practical details, and values or recurring themes.

        Rules: only what the transcript supports; no speculation; no quoting private content \
        from other people; each observation is one bullet starting with "- ". \
        Output ONLY the bullets, nothing else.

        TRANSCRIPT:
        \(chunk)
        """
    }

    static func mergePrompt(observations: [String]) -> String {
        """
        Below are observation bullets about one person, extracted from different slices of \
        their message history. Merge them: combine duplicates, drop weakly-supported one-offs, \
        keep everything well-supported. Output ONLY merged bullets starting with "- ", \
        nothing else.

        \(observations.joined(separator: "\n"))
        """
    }

    static func reducePrompt(observations: [String], stats: CorpusStats) -> String {
        """
        Below are observation bullets extracted from one person's own message history, plus \
        corpus statistics. Write a single portable profile of that person in second person \
        ("You ..."), markdown format.

        Sections, in order: # Your Profile, then ## Life context, ## Communication style, \
        ## Relationships (role terms only, no private details about others), ## Interests, \
        ## Preferences & practical details. Merge duplicates, resolve conflicts by recency \
        or preponderance, drop weakly-supported one-offs. Keep it tight — this gets pasted \
        into AI assistants as standing context. No preamble, no commentary: output only \
        the markdown profile.

        CORPUS STATS: \(stats.headlines.joined(separator: " | "))

        OBSERVATIONS:
        \(observations.joined(separator: "\n"))
        """
    }

    // MARK: Run

    static func run(_ result: ExtractionResult, stats: CorpusStats,
                    progress: @escaping @Sendable (DistillProgress) -> Void) async throws -> String {
        try await OllamaClient.ensureServer()
        if !(try await OllamaClient.hasModel()) {
            try await OllamaClient.pullModel { status in
                progress(DistillProgress(status: status))
            }
        }

        let chunks = buildChunks(result)
        guard !chunks.isEmpty else { throw DistillError.ollamaFailed("no message text to distill") }

        var observations: [String] = []
        var completed = 0

        try await withThrowingTaskGroup(of: String.self) { group in
            var iterator = chunks.makeIterator()
            var inFlight = 0
            func addNext(_ group: inout ThrowingTaskGroup<String, Error>) {
                if let chunk = iterator.next() {
                    group.addTask { try await OllamaClient.generate(prompt: mapPrompt(chunk: chunk)) }
                    inFlight += 1
                }
            }
            for _ in 0..<mapConcurrency { addNext(&group) }
            while inFlight > 0 {
                let out = try await group.next()!
                inFlight -= 1
                completed += 1
                let bullets = extractBullets(out)
                observations.append(contentsOf: bullets)
                progress(DistillProgress(
                    completedChunks: completed, totalChunks: chunks.count,
                    latestInsights: Array(bullets.prefix(3))))
                addNext(&group)
            }
        }

        guard !observations.isEmpty else {
            throw DistillError.ollamaFailed("model returned no observations")
        }

        // Hierarchical reduce: a small local model can't take hundreds of
        // bullets in one shot, so merge in batches until they fit.
        while observations.count > reduceBatchSize {
            progress(DistillProgress(status: "Merging \(observations.count) observations…"))
            var merged: [String] = []
            for batch in stride(from: 0, to: observations.count, by: reduceBatchSize) {
                let slice = Array(observations[batch..<min(batch + reduceBatchSize, observations.count)])
                let out = try await OllamaClient.generate(prompt: mergePrompt(observations: slice))
                merged.append(contentsOf: extractBullets(out))
            }
            // Merge must shrink the list or we'd loop forever.
            if merged.isEmpty || merged.count >= observations.count { break }
            observations = merged
        }

        progress(DistillProgress(status: "Writing your profile…"))
        let profile = try await OllamaClient.generate(
            prompt: reducePrompt(observations: observations, stats: stats))
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DistillError.ollamaFailed("model returned an empty profile") }
        return stripCodeFence(trimmed)
    }

    static func extractBullets(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") && $0.count > 4 }
    }

    /// Small models sometimes wrap markdown output in ``` fences.
    static func stripCodeFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
