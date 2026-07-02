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
