import Foundation
import JavaScriptCore

/// Executes the distillation harness — a JavaScript program — against local
/// capabilities. The app is the stable runtime; the harness hot-reloads.
///
/// Script resolution order (first hit wins):
///   1. CL_HARNESS env var → explicit script path (development)
///   2. ~/Library/Application Support/ContextLayer/harness-dev.js (development)
///   3. https://context.nikliolios.com/harness.js (fetched fresh each run, 5s cap)
///   4. last successfully fetched copy (cache)
///   5. the copy bundled with the app (guaranteed fallback)
///
/// The JSC sandbox exposes ONLY these globals — no network, no filesystem:
///   host.chats()                    → [{id,name,kind,isGroup,participants,messageCount,
///                                       stats:{...,tableRow},period,sampleIncoming}]
///   host.transcript(id, opts)       → string; opts {maxMessages,maxChars,fromDate,toDate}
///   host.corpusHeadlines()          → [string]
///   llm.generate(prompt, model?)    → string  (blocks; local Ollama only)
///   llm.generateParallel(prompts, model?) → [string]  (bounded concurrency)
///   ui.status(text) / ui.fact(text) / ui.progress(done, total)
///   log(text)                       → appended to harness.log for debugging
enum HarnessRuntime {
    static let remoteURL = URL(string: "https://context.nikliolios.com/harness.js")!

    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ContextLayer")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Script resolution

    static func loadScript() async -> (source: String, origin: String) {
        if let path = ProcessInfo.processInfo.environment["CL_HARNESS"],
           let s = try? String(contentsOfFile: path, encoding: .utf8) {
            return (s, "env:\(path)")
        }
        let dev = supportDir.appendingPathComponent("harness-dev.js")
        if let s = try? String(contentsOf: dev, encoding: .utf8) {
            return (s, "dev-override")
        }
        let cache = supportDir.appendingPathComponent("harness-cached.js")
        if let fetched = await fetchRemote() {
            try? fetched.write(to: cache, atomically: true, encoding: .utf8)
            return (fetched, "remote")
        }
        if let s = try? String(contentsOf: cache, encoding: .utf8) {
            return (s, "cache")
        }
        for base in [Bundle.main.resourcePath,
                     Bundle.main.executablePath.map {
                         URL(fileURLWithPath: $0).deletingLastPathComponent().path
                     }].compactMap({ $0 }) {
            if let s = try? String(contentsOfFile: base + "/harness.js", encoding: .utf8) {
                return (s, "bundled")
            }
        }
        return ("", "missing")
    }

    private static func fetchRemote() async -> String? {
        var req = URLRequest(url: remoteURL)
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: data, encoding: .utf8),
              s.contains("function distill") else { return nil }
        return s
    }

    // MARK: - Execution

    struct Callbacks {
        var status: (String) -> Void
        var fact: (String) -> Void
        var progress: (Int, Int) -> Void
    }

    static func execute(script: String, corpus: CorpusIndex,
                        callbacks: Callbacks) throws -> String {
        guard !script.isEmpty else {
            throw DistillError.ollamaFailed("no harness script available")
        }
        guard let ctx = JSContext() else {
            throw DistillError.ollamaFailed("couldn't create JS context")
        }
        var jsError: String?
        ctx.exceptionHandler = { _, exc in
            jsError = exc?.toString() ?? "unknown harness error"
        }

        let logURL = supportDir.appendingPathComponent("harness.log")
        try? "runtime: \(corpus.chats.count) chats extracted, \(corpus.names.count) contacts resolved\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        // ---- host bridge (JSON-string boundary keeps types simple) ---------
        let chatsJSON: @convention(block) () -> String = { corpus.chatsJSON }
        let transcript: @convention(block) (Int, String) -> String = { id, optsJSON in
            corpus.transcript(id: id, optsJSON: optsJSON)
        }
        let headlines: @convention(block) () -> String = { corpus.headlinesJSON }
        let generate: @convention(block) (String, String?) -> String = { prompt, model in
            blockingGenerate(prompt: prompt, model: model)
        }
        let generateParallel: @convention(block) (String, String?, Int32) -> String = { promptsJSON, model, concurrency in
            blockingGenerateParallel(promptsJSON: promptsJSON, model: model,
                                     concurrency: Int(concurrency))
        }
        let status: @convention(block) (String) -> Void = { callbacks.status($0) }
        let fact: @convention(block) (String) -> Void = { callbacks.fact($0) }
        let progressFn: @convention(block) (Int, Int) -> Void = { callbacks.progress($0, $1) }
        let logFn: @convention(block) (String) -> Void = { line in
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write(Data((line + "\n").utf8))
                try? h.close()
            }
        }

        ctx.setObject(chatsJSON, forKeyedSubscript: "__chats" as NSString)
        ctx.setObject(transcript, forKeyedSubscript: "__transcript" as NSString)
        ctx.setObject(headlines, forKeyedSubscript: "__headlines" as NSString)
        ctx.setObject(generate, forKeyedSubscript: "__generate" as NSString)
        ctx.setObject(generateParallel, forKeyedSubscript: "__generateParallel" as NSString)
        ctx.setObject(status, forKeyedSubscript: "__status" as NSString)
        ctx.setObject(fact, forKeyedSubscript: "__fact" as NSString)
        ctx.setObject(progressFn, forKeyedSubscript: "__progress" as NSString)
        ctx.setObject(logFn, forKeyedSubscript: "__log" as NSString)

        ctx.evaluateScript("""
            const host = {
                chats: () => JSON.parse(__chats()),
                transcript: (id, opts) => __transcript(id, JSON.stringify(opts || {})),
                corpusHeadlines: () => JSON.parse(__headlines()),
            };
            const llm = {
                generate: (prompt, model) => __generate(prompt, model || null),
                generateParallel: (prompts, model, concurrency) =>
                    JSON.parse(__generateParallel(JSON.stringify(prompts), model || null,
                                                  concurrency || 4)),
            };
            const ui = { status: __status, fact: __fact, progress: __progress };
            const log = __log;
            """)

        ctx.evaluateScript(script)
        if let e = jsError { throw DistillError.ollamaFailed("harness error: \(e)") }
        guard let distill = ctx.objectForKeyedSubscript("distill"), !distill.isUndefined else {
            throw DistillError.ollamaFailed("harness script defines no distill()")
        }
        let result = distill.call(withArguments: [])
        if let e = jsError { throw DistillError.ollamaFailed("harness error: \(e)") }
        guard let profile = result?.toString(), profile.count > 40,
              profile != "undefined" else {
            throw DistillError.ollamaFailed("harness returned an empty profile")
        }
        return profile
    }

    // MARK: - Blocking LLM bridges (the JS thread is a background thread)

    /// "synthesis" is a symbolic model name: it resolves to the (possibly
    /// larger) judgment-stage model without the script knowing environment.
    private static func resolveModel(_ model: String?) -> String? {
        // JSC bridges JS null/undefined into the literal strings "null"/"undefined".
        guard let m = model, !m.isEmpty, m != "null", m != "undefined" else { return nil }
        return m == "synthesis" ? OllamaClient.synthesisModel : m
    }

    private static func blockingGenerate(prompt: String, model: String?) -> String {
        let sem = DispatchSemaphore(value: 0)
        var output = ""
        let resolved = resolveModel(model)
        Task.detached {
            defer { sem.signal() }
            do { output = try await OllamaClient.generate(prompt: prompt, model: resolved) }
            catch { output = "__ERROR__: \(error.localizedDescription)" }
        }
        sem.wait()
        return output
    }

    private static func blockingGenerateParallel(promptsJSON: String, model: String?,
                                                  concurrency: Int) -> String {
        guard let data = promptsJSON.data(using: .utf8),
              let prompts = try? JSONDecoder().decode([String].self, from: data) else {
            return "[]"
        }
        let sem = DispatchSemaphore(value: 0)
        var outputs = [String](repeating: "", count: prompts.count)
        let resolved = resolveModel(model)
        Task.detached {
            defer { sem.signal() }
            await withTaskGroup(of: (Int, String).self) { group in
                var next = 0
                func add(_ g: inout TaskGroup<(Int, String)>) {
                    guard next < prompts.count else { return }
                    let i = next; next += 1
                    g.addTask {
                        do {
                            return (i, try await OllamaClient.generate(prompt: prompts[i], model: resolved))
                        } catch {
                            return (i, "__ERROR__: \(error.localizedDescription)")
                        }
                    }
                }
                for _ in 0..<max(1, min(concurrency, OllamaClient.numParallel)) { add(&group) }
                while let (i, out) = await group.next() {
                    outputs[i] = out
                    add(&group)
                }
            }
        }
        sem.wait()
        let encoded = (try? JSONEncoder().encode(outputs)) ?? Data("[]".utf8)
        return String(decoding: encoded, as: UTF8.self)
    }
}

// MARK: - Corpus index: the local data the harness may read

/// Pre-digested view of the extraction, safe to hand across the JS boundary.
struct CorpusIndex {
    let chats: [Chat]
    let names: [String: String]
    let headlines: [String]

    private func finite(_ x: Double) -> Double {
        x.isFinite ? (x * 100).rounded() / 100 : 0
    }

    var chatsJSON: String {
        var groupNamesByMember: [String: [String]] = [:]
        func key(_ h: String) -> String {
            h.contains("@") ? h.lowercased() : Contacts.normalize(h)
        }
        for chat in chats where chat.isGroup {
            let gname = Distiller.displayName(for: chat, names: names)
            for p in chat.participants {
                groupNamesByMember[key(p), default: []].append(gname)
            }
        }
        var list: [[String: Any]] = []
        for (i, chat) in chats.enumerated() {
            let name = Distiller.displayName(for: chat, names: names)
            let resolved = chat.isGroup ? nil : Contacts.resolve(chat.identifier, in: names)
            let groups = chat.isGroup ? [] : (groupNamesByMember[key(chat.identifier)] ?? [])
            let stats = PersonStats.compute(for: chat, name: name, groups: groups)
            let kind = chat.isGroup ? "group"
                : (Heuristics.classify(chat, resolvedName: resolved)?.rawValue ?? "ambiguous")
            let samples = chat.messages.filter { !$0.isFromMe && $0.text != nil }
                .suffix(3).map { String($0.text!.prefix(90)) }
            list.append([
                "id": i,
                "name": name,
                "kind": kind,
                "isGroup": chat.isGroup,
                "identifier": chat.identifier,
                "participants": chat.participants.map {
                    Contacts.resolve($0, in: names) ?? $0
                },
                "messageCount": chat.messages.count,
                "period": Distiller.period(of: chat),
                "sampleIncoming": samples,
                "stats": [
                    "tableRow": stats.tableRow,
                    "spanDays": stats.spanDays,
                    "daysSinceLast": stats.daysSinceLast,
                    "perWeek": finite(stats.perWeek),
                    "myShare": finite(stats.myShare),
                    "myInitiationShare": finite(stats.myInitiationShare),
                    "groups": stats.groups,
                ],
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    var headlinesJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: headlines)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func transcript(id: Int, optsJSON: String) -> String {
        guard chats.indices.contains(id) else { return "" }
        struct Opts: Decodable {
            var maxMessages: Int?
            var maxChars: Int?
            var fromDate: String?
            var toDate: String?
        }
        let opts = (try? JSONDecoder().decode(Opts.self, from: Data(optsJSON.utf8))) ?? Opts()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var msgs = chats[id].messages.filter { $0.text != nil && !$0.isSystemEvent }
        if let from = opts.fromDate.flatMap(df.date(from:)) {
            msgs = msgs.filter { $0.date >= from }
        }
        if let to = opts.toDate.flatMap(df.date(from:)) {
            msgs = msgs.filter { $0.date <= to.addingTimeInterval(86_400) }
        }
        msgs = Array(msgs.suffix(opts.maxMessages ?? 400))
        var lines: [String] = []
        for m in msgs {
            guard let text = m.text, !text.isEmpty, m.tapback == nil else { continue }
            let who = m.isFromMe ? "Me"
                : (m.sender.flatMap { Contacts.resolve($0, in: names) } ?? m.sender ?? "them")
            lines.append("[\(df.string(from: m.date))] \(who): \(text)")
        }
        var t = lines.joined(separator: "\n")
        let cap = opts.maxChars ?? 12_000
        if t.count > cap { t = String(t.suffix(cap)) }
        return t
    }
}
