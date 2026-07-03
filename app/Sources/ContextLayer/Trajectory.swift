import Foundation

/// Per-run record of every local-model call — full prompt, full response,
/// latency, errors — written as JSONL beside harness.log. It never leaves
/// the machine unless the user explicitly uploads logs; prompts contain
/// excerpts of their messages, so the upload consent copy must say so.
enum Trajectory {
    /// Local safety valve: a runaway loop shouldn't eat the disk.
    static let maxBytes = 64_000_000
    private static let queue = DispatchQueue(label: "com.nikliolios.contextlayer.trajectory")
    private static var truncated = false
    private static let iso = ISO8601DateFormatter()

    static var fileURL: URL {
        HarnessRuntime.supportDir.appendingPathComponent("trajectory.jsonl")
    }
    static var prevURL: URL {
        HarnessRuntime.supportDir.appendingPathComponent("trajectory.prev.jsonl")
    }

    /// Called at the start of every distillation run, mirroring harness.log.
    static func rotate() {
        queue.sync {
            let fm = FileManager.default
            try? fm.removeItem(at: prevURL)
            try? fm.moveItem(at: fileURL, to: prevURL)
            truncated = false
        }
    }

    static func record(model: String, prompt: String,
                       response: String?, error: String?, ms: Int) {
        queue.async {
            if let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int,
               size > maxBytes {
                if !truncated {
                    truncated = true
                    append(#"{"marker":"truncated — local trajectory cap reached"}"# + "\n")
                }
                return
            }
            var rec: [String: Any] = [
                "ts": iso.string(from: Date()),
                "model": model,
                "ms": ms,
                "prompt": prompt,
            ]
            if let r = response { rec["response"] = r }
            if let e = error { rec["error"] = e }
            guard let data = try? JSONSerialization.data(withJSONObject: rec) else { return }
            append(String(decoding: data, as: UTF8.self) + "\n")
        }
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Previous run + current run, chronological, with a marker line between —
    /// reports usually concern whichever of the two just went wrong.
    static func combinedForUpload() -> Data {
        var out = Data()
        if let prev = try? Data(contentsOf: prevURL), !prev.isEmpty {
            out.append(prev)
            out.append(Data((#"{"marker":"=== current run ==="}"# + "\n").utf8))
        }
        if let cur = try? Data(contentsOf: fileURL) { out.append(cur) }
        return out
    }
}
