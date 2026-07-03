import Foundation

/// CLI mode: run the extract → stats → distill pipeline without the GUI.
///   ContextLayer --headless [chat.db] [--out profile.md] [--no-distill]
enum Headless {
    static func run() {
        var args = Array(CommandLine.arguments.dropFirst())
        args.removeAll { $0 == "--headless" }

        var outPath = "profile.md"
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            outPath = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        var dumpDir: String?
        if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
            dumpDir = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let distill = !args.contains("--no-distill")
        args.removeAll { $0 == "--no-distill" }
        let dbPath = args.first ?? ChatDB.defaultPath

        do {
            print("extracting from \(dbPath) …")
            let result = try ChatDB.extract(path: dbPath)
            let stats = CorpusStats.compute(result, names: Contacts.nameMap())
            print("  \(result.chats.count) chats, "
                + "\(stats.totalMessages) messages, "
                + "\(result.recoveredFromBlob) texts recovered from attributedBody")
            for line in stats.headlines { print("  · \(line)") }

            // Eval tooling: write every chat as a readable transcript so the
            // ground-truth miner can study the corpus without the GUI or model.
            if let dir = dumpDir {
                let fm = FileManager.default
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let names = Contacts.nameMap()
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm"
                var index: [[String: Any]] = []
                for (i, chat) in result.chats.enumerated() {
                    let name = Distiller.displayName(for: chat, names: names)
                    var lines = ["chat \(i): \(name)",
                                 "kind: \(chat.isGroup ? "group" : "1:1")  messages: \(chat.messages.count)  period: \(Distiller.period(of: chat))", ""]
                    for m in chat.messages {
                        guard let text = m.text, !text.isEmpty else { continue }
                        let who = m.isFromMe ? "ME"
                            : (chat.isGroup ? (Contacts.resolve(m.sender ?? "?", in: names) ?? m.sender ?? "?") : name)
                        lines.append("\(df.string(from: m.date)) | \(who): \(text)")
                    }
                    let safe = String(format: "%03d", i)
                    try lines.joined(separator: "\n")
                        .write(toFile: "\(dir)/chat-\(safe).txt", atomically: true, encoding: .utf8)
                    index.append(["id": i, "file": "chat-\(safe).txt", "name": name,
                                  "isGroup": chat.isGroup, "messages": chat.messages.count,
                                  "period": Distiller.period(of: chat)])
                }
                let idx = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])
                try idx.write(to: URL(fileURLWithPath: "\(dir)/index.json"))
                print("dumped \(result.chats.count) transcripts to \(dir)")
            }

            guard distill else { exit(0) }

            print("distilling with \(OllamaClient.model) (local) …")
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let profile = try await Distiller.run(result, stats: stats) { p in
                        if let status = p.status { print("  \(status)"); return }
                        if let done = p.downloadCompleted, let total = p.downloadTotal {
                            print("  model download \(done * 100 / max(total, 1))%"); return
                        }
                        guard p.totalChunks > 0 else { return }
                        print("  chunk \(p.completedChunks)/\(p.totalChunks) done"
                            + (p.latestInsights.isEmpty ? "" : " — \(p.latestInsights[0])"))
                    }
                    try profile.write(toFile: outPath, atomically: true, encoding: .utf8)
                    print("profile written to \(outPath) (\(profile.count) chars)")
                } catch {
                    fputs("error: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
                semaphore.signal()
            }
            semaphore.wait()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
