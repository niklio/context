import Foundation

/// Instant, fully-local facts about the corpus — streamed into the UI while
/// distillation runs, so the wait is the demo.
struct CorpusStats {
    let totalMessages: Int
    let sentMessages: Int
    let chatCount: Int
    let firstDate: Date?
    let lastDate: Date?
    let topContacts: [(name: String, count: Int)]   // by total volume, 1:1 chats
    let busiestHour: Int?                           // local hour with most sent messages
    let medianSentLength: Int
    let tapbacksGiven: Int

    var spanDescription: String? {
        guard let first = firstDate, let last = lastDate else { return nil }
        let years = last.timeIntervalSince(first) / 31_557_600
        if years >= 1 { return String(format: "%.1f years", years) }
        let days = max(1, Int(last.timeIntervalSince(first) / 86_400))
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Human lines in reveal order.
    var headlines: [String] {
        var lines: [String] = []
        if let span = spanDescription {
            lines.append("\(totalMessages.formatted()) messages across \(span) of history")
        } else {
            lines.append("\(totalMessages.formatted()) messages found")
        }
        lines.append("\(chatCount) conversations — you sent \(sentMessages.formatted()) of the messages")
        if let top = topContacts.first {
            lines.append("Most-messaged: \(top.name) (\(top.count.formatted()) messages)")
        }
        if let hour = busiestHour {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            lines.append("You text most around \(h12)\(hour < 12 ? "am" : "pm")")
        }
        lines.append("Median text length: \(medianSentLength) characters"
            + (tapbacksGiven > 0 ? " · \(tapbacksGiven.formatted()) tapbacks given" : ""))
        return lines
    }

    static func compute(_ result: ExtractionResult) -> CorpusStats {
        var total = 0, sent = 0, tapbacks = 0
        var first: Date?, last: Date?
        var hourCounts = [Int](repeating: 0, count: 24)
        var sentLengths: [Int] = []
        var contactVolume: [String: Int] = [:]
        let cal = Calendar.current

        for chat in result.chats {
            for m in chat.messages {
                total += 1
                if first == nil || m.date < first! { first = m.date }
                if last == nil || m.date > last! { last = m.date }
                if m.tapback != nil && m.isFromMe { tapbacks += 1 }
                if m.isFromMe {
                    sent += 1
                    hourCounts[cal.component(.hour, from: m.date)] += 1
                    if let t = m.text, m.tapback == nil { sentLengths.append(t.count) }
                }
            }
            if !chat.isGroup {
                let name = chat.displayName ?? chat.identifier
                contactVolume[name, default: 0] += chat.messages.count
            }
        }

        sentLengths.sort()
        let median = sentLengths.isEmpty ? 0 : sentLengths[sentLengths.count / 2]
        let top = contactVolume.sorted { $0.value > $1.value }
            .prefix(5).map { (name: $0.key, count: $0.value) }
        let busiest = sent > 0 ? hourCounts.enumerated().max(by: { $0.element < $1.element })?.offset : nil

        return CorpusStats(
            totalMessages: total, sentMessages: sent, chatCount: result.chats.count,
            firstDate: first, lastDate: last, topContacts: Array(top),
            busiestHour: busiest, medianSentLength: median, tapbacksGiven: tapbacks)
    }
}
