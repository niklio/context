import Foundation

/// Distills the message corpus into a rich portable profile, entirely
/// on-device via Ollama + Gemma. Two tracks run concurrently:
///   1. Persona — corpus-wide chunks → tagged observations → ten sections
///   2. Relationships — each top conversation separately → a per-person card
/// Assembly is deterministic code; the model only extracts and merges.
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
    var status: String?           // free-form phase text (merge, final write)
    var downloadCompleted: Int64? // model pull, bytes
    var downloadTotal: Int64?
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

    /// The weights download can legitimately run for hours on a slow
    /// connection — never cap it at the shared session's 1h resource limit.
    static let pullSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 86_400
        return URLSession(configuration: cfg)
    }()

    static func binaryPath() -> String? {
        var candidates: [String] = []
        // Bundled runtime ships next to the app executable in Contents/MacOS —
        // the placement that keeps the codesign seal intact.
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
    static let maxPersonaChats = 40
    static let maxMessagesPerChat = 400
    static let chunkCharBudget = 20_000
    static let maxPersonaChunks = 20
    static let maxRelationshipChats = 25      // 1:1s by volume
    static let maxRelationshipGroups = 5
    static let relationshipCharBudget = 16_000
    static let mapConcurrency = 2
    static let mergeThreshold = 12            // bullets per section before merging

    /// Profile section order. Tag → heading.
    static let sections: [(tag: String, heading: String)] = [
        ("ABOUT", "About me"),
        ("COMM", "Communication & voice"),
        // Relationships is assembled from its own track, inserted third.
        ("WORK", "Work & projects"),
        ("INTERESTS", "Interests & tastes"),
        ("HEALTH", "Health & fitness"),
        ("DAILY", "Daily life & logistics"),
        ("DATES", "Dates & events"),
        ("VALUES", "Values & opinions"),
        ("ASSIST", "Working with me"),
    ]

    // MARK: Run

    static func run(_ result: ExtractionResult, stats: CorpusStats,
                    progress: @escaping @Sendable (DistillProgress) -> Void) async throws -> String {
        try await OllamaClient.ensureServer()
        if !(try await OllamaClient.hasModel()) {
            try await OllamaClient.pullModel { done, total in
                progress(DistillProgress(downloadCompleted: done, downloadTotal: total))
            }
        }

        let names = Contacts.nameMap()
        let personaChunks = buildPersonaChunks(result, names: names)
        let relationSources = buildRelationshipSources(result, names: names)
        let totalUnits = personaChunks.count + relationSources.count
        guard totalUnits > 0 else { throw DistillError.ollamaFailed("no message text to distill") }

        enum Unit { case persona(String); case relation(RelationshipSource) }
        var units: [Unit] = relationSources.map { .relation($0) }
        units += personaChunks.map { .persona($0) }

        var tagged: [String: [String]] = [:]
        var cards: [(name: String, card: String)] = []
        var completed = 0

        try await withThrowingTaskGroup(of: (Unit, String).self) { group in
            var iterator = units.makeIterator()
            var inFlight = 0
            func addNext(_ group: inout ThrowingTaskGroup<(Unit, String), Error>) {
                if let unit = iterator.next() {
                    group.addTask {
                        switch unit {
                        case .persona(let chunk):
                            return (unit, try await OllamaClient.generate(prompt: personaPrompt(chunk: chunk)))
                        case .relation(let source):
                            return (unit, try await OllamaClient.generate(prompt: relationshipPrompt(source)))
                        }
                    }
                    inFlight += 1
                }
            }
            for _ in 0..<mapConcurrency { addNext(&group) }
            while inFlight > 0 {
                let (unit, output) = try await group.next()!
                inFlight -= 1
                completed += 1
                var teasers: [String] = []
                switch unit {
                case .persona:
                    for (tag, bullet) in parseTagged(output) {
                        tagged[tag, default: []].append(bullet)
                        if teasers.count < 2 { teasers.append("- " + bullet) }
                    }
                case .relation(let source):
                    let card = cleanCard(output, name: source.name)
                    if !card.isEmpty {
                        cards.append((source.name, card))
                        teasers.append("- \(source.name): \(firstBullet(of: card) ?? "relationship mapped")")
                    }
                }
                progress(DistillProgress(
                    completedChunks: completed, totalChunks: totalUnits,
                    latestInsights: teasers))
                addNext(&group)
            }
        }

        // Deduplicate and, where a section overflows, let the model merge it.
        progress(DistillProgress(status: "Organizing your profile…"))
        var rendered: [String] = ["# Your Profile"]
        for (tag, heading) in sections {
            var bullets = dedupe(tagged[tag] ?? [])
            if bullets.count > mergeThreshold {
                let out = try await OllamaClient.generate(
                    prompt: mergePrompt(section: heading, observations: bullets))
                let merged = extractBullets(out)
                if !merged.isEmpty, merged.count <= bullets.count { bullets = merged }
            }
            if !bullets.isEmpty {
                rendered.append("\n## \(heading)")
                rendered.append(contentsOf: bullets.map { "- \($0)" })
            }
            // Relationships slot right after Communication & voice.
            if tag == "COMM", !cards.isEmpty {
                rendered.append("\n## Relationships")
                for (_, card) in cards.sorted(by: { $0.name < $1.name }) {
                    rendered.append(card)
                }
            }
        }

        let profile = rendered.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.count > 40 else { throw DistillError.ollamaFailed("model returned an empty profile") }
        return profile
    }

    // MARK: Sources

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

    struct RelationshipSource {
        let name: String
        let transcript: String
        let isGroup: Bool
        let messageCount: Int
    }

    static func buildRelationshipSources(_ result: ExtractionResult,
                                         names: [String: String]) -> [RelationshipSource] {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var sources: [RelationshipSource] = []
        let oneOnOnes = result.chats.filter { !$0.isGroup }.prefix(maxRelationshipChats)
        let groups = result.chats.filter { $0.isGroup }.prefix(maxRelationshipGroups)

        for chat in Array(oneOnOnes) + Array(groups) {
            let name = displayName(for: chat, names: names)
            var lines: [String] = []
            for m in chat.messages.suffix(maxMessagesPerChat) {
                guard let text = m.text, !text.isEmpty, !m.isSystemEvent, m.tapback == nil
                else { continue }
                let who = m.isFromMe ? "Me"
                    : (m.sender.flatMap { Contacts.resolve($0, in: names) } ?? m.sender ?? "them")
                lines.append("[\(df.string(from: m.date))] \(who): \(text)")
            }
            guard lines.count >= 6 else { continue }   // too thin to say anything real
            var transcript = lines.joined(separator: "\n")
            if transcript.count > relationshipCharBudget {
                transcript = String(transcript.suffix(relationshipCharBudget))
            }
            sources.append(RelationshipSource(
                name: name, transcript: transcript,
                isGroup: chat.isGroup, messageCount: chat.messages.count))
        }
        return sources
    }

    static func buildPersonaChunks(_ result: ExtractionResult,
                                   names: [String: String]) -> [String] {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var chunks: [String] = []
        var current = ""
        for chat in result.chats.prefix(maxPersonaChats) {
            let name = displayName(for: chat, names: names)
            var lines = ["## Conversation with \(name)"]
            for m in chat.messages.suffix(maxMessagesPerChat) {
                guard let text = m.text, !text.isEmpty, !m.isSystemEvent else { continue }
                let who = m.isFromMe ? "Me"
                    : (m.sender.flatMap { Contacts.resolve($0, in: names) } ?? m.sender ?? "them")
                if let tb = m.tapback {
                    lines.append("[\(df.string(from: m.date))] \(who): (\(tb) a message)")
                } else {
                    lines.append("[\(df.string(from: m.date))] \(who): \(text)")
                }
            }
            guard lines.count > 1 else { continue }
            let block = lines.joined(separator: "\n") + "\n\n"
            if current.count + block.count > chunkCharBudget && !current.isEmpty {
                chunks.append(current); current = ""
            }
            if block.count > chunkCharBudget {
                var rest = Substring(block)
                while !rest.isEmpty {
                    chunks.append(String(rest.prefix(chunkCharBudget)))
                    rest = rest.dropFirst(min(chunkCharBudget, rest.count))
                }
            } else {
                current += block
            }
            if chunks.count >= maxPersonaChunks { break }
        }
        if !current.isEmpty && chunks.count < maxPersonaChunks { chunks.append(current) }
        return Array(chunks.prefix(maxPersonaChunks))
    }

    // MARK: Prompts

    static func personaPrompt(chunk: String) -> String {
        """
        You are analyzing a person's own message history to build a rich profile OF THAT \
        PERSON (the "Me" lines are them). This runs locally on their machine at their request. \
        Err on the side of capturing MORE detail — the person reviews everything before use.

        Extract observations about "Me" from the transcript below. Each observation is one \
        line in the form `TAG: observation`, using exactly these tags:
        ABOUT — identity: name, profession/employer, where they live, life stage
        COMM — how they write: tone, formality, emoji/punctuation habits, how it shifts by audience
        WORK — job, projects, skills, tools, ambitions
        INTERESTS — hobbies, sports, media, food, brands, travel tastes
        HEALTH — fitness, training, sleep, diet, injuries
        DAILY — routines, schedule patterns, commute, errands, practical logistics
        DATES — birthdays, anniversaries, planned events or trips with dates
        VALUES — opinions, principles, worldview, what they care about
        ASSIST — instructions an AI assistant could infer: preferences for how to help, \
        recurring requests, pet peeves

        Rules: only what the transcript supports; specifics beat generalities (names, places, \
        numbers, dates); no speculation; don't quote other people's sensitive disclosures. \
        Each observation must be a complete standalone sentence about them — for example \
        `ABOUT: They live in Brooklyn and work as a nurse at Mount Sinai.` or \
        `DATES: Their sister's wedding is on 2026-09-14 in Austin.` \
        Never copy the tag descriptions above; never output fragments like "tone - informal". \
        Output ONLY `TAG: observation` lines, nothing else.

        TRANSCRIPT:
        \(chunk)
        """
    }

    static func relationshipPrompt(_ source: RelationshipSource) -> String {
        """
        Below is a message transcript between "Me" and \(source.name)\(source.isGroup ? " (a group chat)" : "") \
        — \(source.messageCount) messages in the full history. Build a relationship card \
        describing MY relationship with \(source.isGroup ? "this group" : "this person"), \
        from my perspective. This runs locally at my request; err on the side of rich detail.

        Output format — first line exactly `### \(source.name)`, then 1 to 10 bullets \
        (each starting `- `). Cover, where the transcript supports it: who they are to me \
        (partner, close friend, colleague, family…); what we talk about and do together; \
        how we communicate (tone, frequency, who initiates); shared history, plans, or \
        running jokes; practical facts I clearly know (their city, job, family, birthday); \
        how I support them and they support me.

        Rules: only what the transcript supports; specifics beat generalities; describe the \
        relationship rather than profiling their private life; no speculation. \
        Output ONLY the heading line and bullets.

        TRANSCRIPT:
        \(source.transcript)
        """
    }

    static func mergePrompt(section: String, observations: [String]) -> String {
        """
        These observation bullets all belong to the "\(section)" section of one person's \
        profile. Merge duplicates and near-duplicates, keep every distinct well-supported \
        fact, prefer the more specific phrasing when two overlap. Output ONLY merged \
        bullets starting with "- ", nothing else.

        \(observations.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    // MARK: Parsing & assembly helpers

    static func parseTagged(_ output: String) -> [(String, String)] {
        let validTags = Set(sections.map(\.tag))
        var results: [(String, String)] = []
        for raw in output.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let tag = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if validTags.contains(tag), body.count > 8 {
                results.append((tag, body))
            }
        }
        return results
    }

    static func cleanCard(_ output: String, name: String) -> String {
        var lines = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        lines.removeAll { $0.hasPrefix("###") }
        let bullets = lines.filter { $0.hasPrefix("- ") }
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .prefix(10)
        guard !bullets.isEmpty else { return "" }
        return "### \(name)\n" + bullets.joined(separator: "\n")
    }

    static func firstBullet(of card: String) -> String? {
        card.split(separator: "\n")
            .first { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    static func dedupe(_ bullets: [String]) -> [String] {
        var seen = Set<String>()
        return bullets.filter {
            seen.insert($0.lowercased().trimmingCharacters(in: .punctuationCharacters)).inserted
        }
    }

    static func extractBullets(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") && $0.count > 4 }
            .map { String($0.dropFirst(2)) }
    }
}
