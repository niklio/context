import Foundation

/// The distillation harness. Architecture: evidence → merge → synthesize → write.
///
///   0. Classify counterparts (person / business / automated) — heuristics
///      first, one batched model call for the ambiguous.
///   1. One evidence pass per conversation: relationship signals + persona
///      observations, with provenance. Local passes are FORBIDDEN from
///      conclusions, role verdicts, and superlatives.
///   2. Code merges evidence per person and computes deterministic stats
///      (cadence, span, recency, initiation) — context for judgment, not rules.
///   3. Relationship synthesis: ONE pass that sees everyone assigns roles
///      from a taxonomy ("unclear" allowed) and may make comparative calls
///      like "closest friend" — the only stage allowed to.
///   4. Persona synthesis (3 grouped passes) consumes the resolved role graph.
///   5. Cards written per person; a final polish pass sanity-checks the
///      Relationships section for unsupported superlatives.
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
    static let baseURL = URL(string: "http://127.0.0.1:11434")!
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

    static func generate(prompt: String, model modelName: String? = nil) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName ?? model,
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
    static let maxPersons = 25
    static let maxGroups = 5
    static let maxBusinessThreads = 15    // persona-only sources
    static let maxMessagesPerChat = 400
    static let transcriptCharBudget = 12_000
    static let evidenceCharCap = 700      // per-person bundle inside synthesis
    static let obsPerTagCap = 40
    static let mapConcurrency = 2

    static let roleTaxonomy = """
        Spouse/Wife/Husband, Partner, Girlfriend/Boyfriend, Mother, Father, \
        Sibling, Child, Grandparent, Extended family, In-law, Close friend, \
        Friend, Roommate, Manager, Direct report, Colleague, Client, \
        Service provider, Acquaintance, unclear
        """

    static let sections: [(tag: String, heading: String)] = [
        ("ABOUT", "About me"),
        ("COMM", "Communication & voice"),
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

        // ---- Stage 0: classify counterparts -------------------------------
        var persons: [Chat] = [], businesses: [Chat] = [], ambiguous: [Chat] = []
        var groups: [Chat] = []
        for chat in result.chats {
            if chat.isGroup { groups.append(chat); continue }
            let resolved = Contacts.resolve(chat.identifier, in: names)
            switch Heuristics.classify(chat, resolvedName: resolved) {
            case .person: persons.append(chat)
            case .business, .automated: businesses.append(chat)
            case nil: ambiguous.append(chat)
            }
        }
        if !ambiguous.isEmpty {
            let verdicts = try await classifyAmbiguous(ambiguous, names: names)
            for (chat, kind) in zip(ambiguous, verdicts) {
                if kind == .person { persons.append(chat) } else { businesses.append(chat) }
            }
        }
        persons = Array(persons.sorted { $0.messages.count > $1.messages.count }.prefix(maxPersons))
        groups = Array(groups.sorted { $0.messages.count > $1.messages.count }.prefix(maxGroups))
        businesses = Array(businesses.sorted { $0.messages.count > $1.messages.count }
            .prefix(maxBusinessThreads))

        // ---- Stage 2 prep: dossiers with deterministic stats ---------------
        func handleKey(_ h: String) -> String {
            h.contains("@") ? h.lowercased() : Contacts.normalize(h)
        }
        var groupNamesByMember: [String: [String]] = [:]
        for g in groups {
            let gname = displayName(for: g, names: names)
            for p in g.participants {
                groupNamesByMember[handleKey(p), default: []].append(gname)
            }
        }
        var dossiers: [String: PersonDossier] = [:]
        for chat in persons {
            let name = displayName(for: chat, names: names)
            let memberGroups = groupNamesByMember[handleKey(chat.identifier)] ?? []
            dossiers[name] = PersonDossier(
                name: name,
                stats: PersonStats.compute(for: chat, name: name, groups: memberGroups))
        }
        for g in groups {
            let name = displayName(for: g, names: names)
            var d = PersonDossier(
                name: name,
                stats: PersonStats.compute(for: g, name: name, groups: []))
            d.isGroup = true
            dossiers[name] = d
        }

        let evidenceUnits = persons.count + groups.count + businesses.count
        let totalUnits = evidenceUnits + persons.count + groups.count + 6
        var completed = 0
        func bump(_ teasers: [String] = []) {
            completed += 1
            progress(DistillProgress(completedChunks: completed, totalChunks: totalUnits,
                                     latestInsights: teasers))
        }

        // ---- Stage 1: evidence passes (both tracks, one call per chat) -----
        var observations: [PersonaObservation] = []
        var eventMentions: [EventMention] = []
        struct EvidenceJob { let chat: Chat; let name: String; let kind: String }
        var jobs: [EvidenceJob] = persons.map {
            .init(chat: $0, name: displayName(for: $0, names: names), kind: "person")
        }
        jobs += groups.map {
            .init(chat: $0, name: displayName(for: $0, names: names), kind: "group")
        }
        jobs += businesses.map {
            .init(chat: $0, name: displayName(for: $0, names: names), kind: "business")
        }

        try await withThrowingTaskGroup(of: (EvidenceJob, String).self) { taskGroup in
            var iterator = jobs.makeIterator()
            var inFlight = 0
            func addNext(_ g: inout ThrowingTaskGroup<(EvidenceJob, String), Error>) {
                if let job = iterator.next() {
                    let prompt = evidencePrompt(
                        name: job.name, kind: job.kind,
                        transcript: transcript(for: job.chat, names: names),
                        statsRow: dossiers[job.name]?.stats.tableRow)
                    g.addTask { (job, try await OllamaClient.generate(prompt: prompt)) }
                    inFlight += 1
                }
            }
            for _ in 0..<mapConcurrency { addNext(&taskGroup) }
            while inFlight > 0 {
                let (job, output) = try await taskGroup.next()!
                inFlight -= 1
                var teasers: [String] = []
                let (signals, obs, events) = parseEvidence(output, source: job.name,
                                                           period: period(of: job.chat))
                if dossiers[job.name] != nil { dossiers[job.name]!.evidence += signals }
                observations += obs
                eventMentions += events
                if let first = obs.first { teasers.append(first.text) }
                bump(teasers)
                addNext(&taskGroup)
            }
        }

        // ---- Stage 3: relationship synthesis (sees everyone) ---------------
        progress(DistillProgress(status: "Figuring out who's who…"))
        let people = dossiers.values.filter { !$0.isGroup }
            .sorted { $0.stats.messageCount > $1.stats.messageCount }
        let assignments = try await synthesizeRoles(people)
        bump(assignments.prefix(3).map { "\($0.name) — \($0.role.lowercased())" })

        // ---- Stage 4a: persona synthesis (consumes the role graph) ---------
        progress(DistillProgress(status: "Piecing together who you are…"))
        let roleGraph = assignments.map { a in
            "\(a.name) — \(a.role)\(a.note.isEmpty ? "" : " (\(a.note))")"
        }.joined(separator: "\n")

        let sectionGroups: [[String]] = [["ABOUT", "COMM", "WORK"],
                                         ["INTERESTS", "HEALTH", "DAILY"],
                                         ["DATES", "VALUES", "ASSIST"]]
        var sectionBullets: [String: [String]] = [:]
        for tags in sectionGroups {
            let out = try await OllamaClient.generate(
                prompt: personaSynthesisPrompt(tags: tags, roleGraph: roleGraph,
                                               observations: observations),
                model: OllamaClient.synthesisModel)
            for (tag, bullet) in parseTagged(out, validTags: Set(tags)) {
                sectionBullets[tag, default: []].append(bullet)
            }
            bump(sectionBullets[tags[0]]?.prefix(1).map { "- \($0)" } ?? [])
        }

        // ---- Stage 4t: timeline (merge event mentions, count corroborations) --
        progress(DistillProgress(status: "Reconstructing your timeline…"))
        let timeline = try await synthesizeTimeline(eventMentions) { teaser in
            progress(DistillProgress(completedChunks: completed, totalChunks: totalUnits,
                                     latestInsights: [teaser]))
        }
        bump(timeline.prefix(1).map { "- \($0)" })

        // ---- Stage 4b: relationship cards -----------------------------------
        var cards: [(name: String, card: String)] = []
        let assignmentByName = Dictionary(uniqueKeysWithValues: assignments.map { ($0.name, $0) })
        for dossier in dossiers.values.sorted(by: { $0.stats.messageCount > $1.stats.messageCount }) {
            let assignment = assignmentByName[dossier.name]
            let out = try await OllamaClient.generate(prompt: cardPrompt(
                dossier: dossier,
                role: dossier.isGroup ? "Group chat" : (assignment?.role ?? "unclear"),
                note: assignment?.note ?? ""))
            let card = cleanCard(out, name: dossier.name,
                                 role: dossier.isGroup ? nil : assignment?.role)
            if !card.isEmpty {
                cards.append((dossier.name, card))
                bump(["\(dossier.name): \(firstBullet(of: card) ?? "card written")"])
            } else { bump() }
        }

        // ---- Stage 5: polish + assemble -------------------------------------
        var relationsSection = cards.map(\.card).joined(separator: "\n")
        if relationsSection.count < 12_000, cards.count > 1 {
            progress(DistillProgress(status: "Double-checking claims…"))
            let polished = try await OllamaClient.generate(
                prompt: polishPrompt(section: relationsSection, roleGraph: roleGraph),
                model: OllamaClient.synthesisModel)
            if polished.contains("###"), polished.count > relationsSection.count / 2 {
                relationsSection = polished.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        bump()

        var rendered: [String] = ["# Your Profile"]
        for (tag, heading) in sections {
            let bullets = dedupe(sectionBullets[tag] ?? [])
            if !bullets.isEmpty {
                rendered.append("\n## \(heading)")
                rendered.append(contentsOf: bullets.map { "- \($0)" })
            }
            if tag == "COMM", !relationsSection.isEmpty {
                rendered.append("\n## Relationships")
                rendered.append(relationsSection)
            }
            if tag == "DATES", !timeline.isEmpty {
                rendered.append("\n## Timeline")
                rendered.append(contentsOf: timeline.map { "- \($0)" })
            }
        }
        let profile = rendered.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.count > 40 else { throw DistillError.ollamaFailed("model returned an empty profile") }
        return profile
    }

    // MARK: Stage 0 — ambiguous classification

    static func classifyAmbiguous(_ chats: [Chat], names: [String: String]) async throws -> [CounterpartKind] {
        let lines = chats.enumerated().map { i, chat -> String in
            let name = displayName(for: chat, names: names)
            let samples = chat.messages.filter { !$0.isFromMe && $0.text != nil }
                .suffix(3).map { String($0.text!.prefix(90)) }.joined(separator: " ⏐ ")
            return "\(i + 1). \(name): \(samples)"
        }.joined(separator: "\n")
        let out = try await OllamaClient.generate(prompt: """
            For each numbered sender below, decide if it is a real PERSON I know, or a \
            BUSINESS/automated sender (airline, bank, store, appointment reminders, \
            verification codes, delivery notices). Output one line per number, exactly:
            <number>. PERSON  or  <number>. BUSINESS

            \(lines)
            """)
        var verdicts = [CounterpartKind](repeating: .person, count: chats.count)
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ".", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               (1...chats.count).contains(n),
               parts[1].uppercased().contains("BUSINESS") {
                verdicts[n - 1] = .business
            }
        }
        return verdicts
    }

    // MARK: Stage 1 — evidence prompts

    static func evidencePrompt(name: String, kind: String,
                               transcript: String, statsRow: String?) -> String {
        let base = """
        You are gathering EVIDENCE from one conversation in my message history. This runs \
        locally at my request. You see ONLY this conversation, so you must not draw \
        conclusions that require seeing my other relationships: NO role verdicts, NO \
        superlatives ("closest", "best friend", "favorite"), NO "always/never" claims. \
        Evidence only — a later stage that sees everything will judge.
        """
        let personaTags = """
        OBS: <TAG> | <explicit or inferred> | <complete sentence about Me>
        Tags: ABOUT (identity: name, job, city, life stage), COMM (how I write in THIS \
        conversation), WORK, INTERESTS, HEALTH, DAILY, DATES (upcoming dates/events), \
        VALUES, ASSIST (how an assistant could help me based on what I ask for here). \
        Specifics beat generalities; only what this transcript supports.

        Also extract every real-world EVENT from my life this conversation evidences — \
        small (met someone for breakfast, a dinner, a ride) or big (wedding, move, new \
        job, race, birth). Date each one using the [YYYY-MM-DD] message timestamps \
        ("yesterday"/"next Saturday" resolve relative to the message's date):
        EVENT: <YYYY-MM-DD or YYYY-MM> | <what happened> | <explicit or inferred>
        """
        switch kind {
        case "business":
            return """
            \(base)

            This is a conversation with a business/automated sender ("\(name)"). \
            Extract only persona observations about Me (what it reveals about my travel, \
            purchases, appointments, habits). Output ONLY OBS lines:
            \(personaTags)

            TRANSCRIPT:
            \(transcript)
            """
        default:
            return """
            \(base)

            Conversation with \(name)\(kind == "group" ? " (group chat)" : ""). \
            \(statsRow.map { "Measured: \($0)." } ?? "")

            Output THREE kinds of lines, nothing else:
            SIGNAL: <role-relevant evidence with its supporting detail — how we address \
            each other ("mom", "babe", first names), events mentioned (anniversary, \
            performance review, family dinners), shared logistics (same home, kids, \
            projects), emotional register>
            HYPOTHESIS: <a possible relationship role> — <the evidence for it> \
            (several allowed; uncertainty is fine)
            \(personaTags)

            TRANSCRIPT:
            \(transcript)
            """
        }
    }

    // MARK: Stage 3 — relationship synthesis

    static func synthesizeRoles(_ people: [PersonDossier]) async throws -> [RoleAssignment] {
        let entries = people.map { d -> String in
            var e = "== \(d.name)\n\(d.stats.tableRow)"
            let bundle = d.evidence.joined(separator: "; ")
            if !bundle.isEmpty { e += "\nEvidence: \(String(bundle.prefix(evidenceCharCap)))" }
            return e
        }.joined(separator: "\n")

        let out = try await OllamaClient.generate(prompt: """
            You can now see ALL of my personal relationships at once — the only vantage \
            point from which comparative judgments are legitimate. For each person, using \
            their measured stats and gathered evidence (and comparing across people), \
            assign the most specific relationship role the evidence supports.

            Taxonomy: \(roleTaxonomy)

            Rules:
            - Prefer "unclear" over guessing when evidence is thin.
            - Evidence may need combining: pet names + shared home + anniversary → Spouse \
            or Partner; choose Spouse only with marriage evidence.
            - Comparative calls ARE allowed here and only here: you may name a "closest \
            friend" if the whole picture (cadence, history, what we confide, the stats) \
            clearly supports one; if it's close between several, say "one of my closest \
            friends" in the note instead.
            - At most ONE person may carry a "closest friend" note.

            Output exactly one line per person:
            PERSON: <name> | <role> | <optional short note, e.g. comparative context>

            \(entries)
            """, model: OllamaClient.synthesisModel)

        var assignments: [RoleAssignment] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("PERSON:") else { continue }
            let parts = trimmed.dropFirst(7).split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 2 else { continue }
            assignments.append(RoleAssignment(
                name: parts[0], role: parts[1],
                note: parts.count > 2 ? parts[2] : ""))
        }
        // Anyone the model skipped stays explicitly unclear.
        let covered = Set(assignments.map(\.name))
        for d in people where !covered.contains(d.name) {
            assignments.append(RoleAssignment(name: d.name, role: "unclear", note: ""))
        }
        return assignments
    }

    // MARK: Stage 4a — persona synthesis

    static func personaSynthesisPrompt(tags: [String], roleGraph: String,
                                       observations: [PersonaObservation]) -> String {
        let guidance: [String: String] = [
            "ABOUT": "Triangulate identity: name from how people address me, job/city corroborated across conversations. Resolve contradictions by recency and say so ('moved from X to Y').",
            "COMM": "Compare my style ACROSS audiences using the role graph — describe the register shifts (how I write to my partner vs colleagues vs friends), not one thread's tone.",
            "WORK": "Separate corroborated facts (employer, role) from ambitions and side projects.",
            "INTERESTS": "Tier them: core interests (many conversations, long span, recent) vs current phase vs historical. Weigh breadth of audiences, not enthusiasm in one thread.",
            "HEALTH": "Only durable patterns across time; skip one-off complaints.",
            "DAILY": "Recurring routines and practical logistics only.",
            "DATES": "Specific dates with what they are; recurring greetings imply birthdays/anniversaries.",
            "VALUES": "High bar: explicit self-statements, or the same stance shown to at least two different people.",
            "ASSIST": "Derive instructions an AI assistant should follow for me, from how I ask for things across all conversations.",
        ]
        let relevant = observations.filter { tags.contains($0.tag) }
        var byTag: [String: [PersonaObservation]] = [:]
        for o in relevant { byTag[o.tag, default: []].append(o) }
        let body = tags.compactMap { tag -> String? in
            guard let list = byTag[tag], !list.isEmpty else { return nil }
            let capped = list.suffix(obsPerTagCap)
            return "\(tag) observations:\n" + capped.map(\.line).joined(separator: "\n")
        }.joined(separator: "\n\n")

        return """
        You are synthesizing sections of my profile from observations gathered across ALL \
        my conversations — each carries its source and time period. You also know who \
        everyone is to me:

        \(roleGraph)

        Section guidance (instructions for you — NEVER copy these into the output):
        \(tags.map { "• \($0) — \(guidance[$0] ?? "")" }.joined(separator: "\n"))

        Cross-reference the observations: facts seen across several conversations and \
        recent time periods are load-bearing; one-off inferred items are background or \
        droppable. Write final profile bullets, each a complete sentence about me, \
        in the form `TAG: bullet`. A tag with no observations gets NO output lines. \
        If the observations are too thin to conclude anything, output nothing for that \
        tag — never pad, never restate the guidance. Output ONLY conclusion lines.

        \(body)
        """
    }

    // MARK: Stage 4b/5 — cards & polish

    static func cardPrompt(dossier: PersonDossier, role: String, note: String) -> String {
        """
        Write my relationship card for \(dossier.name). The role was determined by a \
        stage that compared all my relationships: \(role)\(note.isEmpty ? "" : " — \(note)").
        Measured: \(dossier.stats.tableRow)
        Evidence gathered: \(dossier.evidence.joined(separator: "; ").prefix(1400))

        Output: first line exactly `### \(dossier.name)`, then 1 to 10 bullets (`- `). \
        The first bullet states who they are to me using the given role naturally. Cover \
        what we talk about, how we communicate, shared history and plans, practical facts, \
        how we support each other. Only evidence-supported claims; do NOT add comparative \
        claims beyond the note; no speculation. Output ONLY the heading and bullets.
        """
    }

    static func polishPrompt(section: String, roleGraph: String) -> String {
        """
        Below is the Relationships section of my profile, plus the authoritative role \
        assignments. Fix ONLY these problems, changing nothing else:
        - superlatives ("closest", "best", "favorite") that are NOT in the role \
        assignments — soften them ("a close friend")
        - role contradictions with the assignments
        Return the full corrected section verbatim otherwise, starting with the first ###.

        ROLE ASSIGNMENTS:
        \(roleGraph)

        SECTION:
        \(section)
        """
    }

    // MARK: Stage 4t — timeline

    /// Merge per-conversation event mentions into one chronological timeline.
    /// Batches are time-contiguous so mentions of the same real-world event
    /// land in the same batch; each merged duplicate counts as corroboration.
    static func synthesizeTimeline(_ mentions: [EventMention],
                                   teaser: @escaping (String) -> Void) async throws -> [String] {
        guard !mentions.isEmpty else { return [] }
        let sorted = mentions.sorted { $0.sortKey < $1.sortKey }
        var batches: [[EventMention]] = [[]]
        var chars = 0
        for m in sorted {
            if chars + m.line.count > 9_000, !batches[batches.count - 1].isEmpty {
                batches.append([]); chars = 0
            }
            batches[batches.count - 1].append(m)
            chars += m.line.count
        }

        var timeline: [String] = []
        for batch in batches {
            let mentionList = batch.map { $0.line }.joined(separator: "\n")
            let out = try await OllamaClient.generate(prompt: """
                Below are mentions of real-world events from my life, gathered from \
                different conversations, sorted by date. Merge them into a clean \
                chronological timeline:
                - Mentions of the SAME real-world event (same date range, same happening, \
                possibly described differently to different people) become ONE entry. \
                Count the distinct conversations it appeared in; if 2 or more, append \
                " (corroborated in N conversations)" — more corroboration means more \
                confidence it happened.
                - Keep small events (a breakfast, a ride, a dinner) AND big ones \
                (weddings, moves, job changes). Drop non-events and pure plans that \
                never resolved.
                - Output one line per event, exactly: `<YYYY-MM-DD or YYYY-MM> — <event>` \
                with the optional corroboration suffix. Chronological order. Nothing else.

                \(mentionList)
                """, model: OllamaClient.synthesisModel)
            var entries: [String] = []
            for rawLine in out.split(separator: "\n") {
                var entry: String = rawLine.trimmingCharacters(in: .whitespaces)
                if entry.hasPrefix("- ") { entry = String(entry.dropFirst(2)) }
                guard entry.count > 12 else { continue }
                let century: String = String(entry.prefix(2))
                if century == "20" || century == "19" { entries.append(entry) }
            }
            if let first = entries.first { teaser(first) }
            timeline += entries
        }
        return timeline
    }

    // MARK: Shared helpers

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

    static func transcript(for chat: Chat, names: [String: String]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var lines: [String] = []
        for m in chat.messages.suffix(maxMessagesPerChat) {
            guard let text = m.text, !text.isEmpty, !m.isSystemEvent, m.tapback == nil
            else { continue }
            let who = m.isFromMe ? "Me"
                : (m.sender.flatMap { Contacts.resolve($0, in: names) } ?? m.sender ?? "them")
            lines.append("[\(df.string(from: m.date))] \(who): \(text)")
        }
        var t = lines.joined(separator: "\n")
        if t.count > transcriptCharBudget { t = String(t.suffix(transcriptCharBudget)) }
        return t
    }

    static func period(of chat: Chat) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM yyyy"
        guard let first = chat.messages.first?.date, let last = chat.messages.last?.date
        else { return "" }
        let a = df.string(from: first), b = df.string(from: last)
        return a == b ? a : "\(a)–\(b)"
    }

    static func parseEvidence(_ output: String, source: String, period: String)
        -> (signals: [String], observations: [PersonaObservation], events: [EventMention]) {
        var signals: [String] = []
        var obs: [PersonaObservation] = []
        var events: [EventMention] = []
        let validTags = Set(sections.map(\.tag))
        for raw in output.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            let upper = line.uppercased()
            if upper.hasPrefix("SIGNAL:") {
                let body = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if body.count > 8 { signals.append(body) }
            } else if upper.hasPrefix("HYPOTHESIS:") {
                let body = line.dropFirst(11).trimmingCharacters(in: .whitespaces)
                if body.count > 8 { signals.append("hypothesis: \(body)") }
            } else if upper.hasPrefix("EVENT:") {
                let parts = line.dropFirst(6).split(separator: "|", maxSplits: 2)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2, parts[0].count >= 4,
                      parts[0].prefix(2) == "20" || parts[0].prefix(2) == "19",
                      parts[1].count > 6 else { continue }
                events.append(EventMention(
                    dateText: parts[0], text: parts[1], source: source,
                    explicit: parts.count > 2 && parts[2].lowercased().contains("explicit")))
            } else if upper.hasPrefix("OBS:") {
                let parts = line.dropFirst(4).split(separator: "|", maxSplits: 2)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 3 else { continue }
                let tag = parts[0].uppercased()
                guard validTags.contains(tag), parts[2].count > 8 else { continue }
                obs.append(PersonaObservation(
                    tag: tag, text: parts[2], source: source, period: period,
                    explicit: parts[1].lowercased().contains("explicit")))
            }
        }
        return (signals, obs, events)
    }

    static func parseTagged(_ output: String, validTags: Set<String>) -> [(String, String)] {
        var results: [(String, String)] = []
        for raw in output.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let tag = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let lower = body.lowercased()
            let filler = lower.contains("no observation") || lower.contains("n/a")
                || lower.contains("insufficient") || lower.contains("not enough evidence")
                || lower.contains("nothing to conclude")
            if validTags.contains(tag), body.count > 8, !filler,
               !(body.contains("[") && body.contains("]")) {
                results.append((tag, body))
            }
        }
        return results
    }

    static func cleanCard(_ output: String, name: String, role: String?) -> String {
        var lines = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        lines.removeAll { $0.hasPrefix("###") }
        let bullets = lines.filter { $0.hasPrefix("- ") }
            .filter { !($0.contains("[") && $0.contains("]")) }   // template placeholders
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .prefix(10)
        guard !bullets.isEmpty else { return "" }
        let heading = role.map { r in
            r.lowercased() == "unclear" ? "### \(name)" : "### \(name) · \(r)"
        } ?? "### \(name)"
        return heading + "\n" + bullets.joined(separator: "\n")
    }

    static func firstBullet(of card: String) -> String? {
        card.split(separator: "\n").first { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
    }

    static func dedupe(_ bullets: [String]) -> [String] {
        var seen = Set<String>()
        return bullets.filter {
            seen.insert($0.lowercased().trimmingCharacters(in: .punctuationCharacters)).inserted
        }
    }
}
