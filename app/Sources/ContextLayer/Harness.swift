import Foundation

/// The distillation harness's data model: evidence in, judgments out.
/// Local passes observe with provenance; code measures and merges; the
/// global synthesis stages — the only stages that see everyone — judge.

enum CounterpartKind: String {
    case person, business, automated
}

/// Deterministic per-person measurements, computed in code and handed to the
/// synthesis stage as context (never as a rulebook — judgment stays with the
/// model, which sees everyone at once).
struct PersonStats {
    let name: String
    let messageCount: Int
    let spanDays: Int
    let daysSinceLast: Int
    let perWeek: Double
    let myShare: Double          // fraction of messages that are mine
    let myInitiationShare: Double // fraction of >4h-gap restarts that are mine
    let groups: [String]

    var tableRow: String {
        let cadence = perWeek >= 1 ? String(format: "%.0f msgs/wk", perWeek)
                                   : String(format: "%.1f msgs/wk", perWeek)
        let span = spanDays > 365 ? String(format: "%.1f yrs", Double(spanDays) / 365)
                                  : "\(spanDays) days"
        var row = "\(name): \(messageCount) msgs over \(span), \(cadence), "
            + "last contact \(daysSinceLast)d ago, I send \(Int(myShare * 100))% "
            + "and start \(Int(myInitiationShare * 100))% of conversations"
        if !groups.isEmpty { row += ", shares groups: \(groups.joined(separator: ", "))" }
        return row
    }

    static func compute(for chat: Chat, name: String, groups: [String]) -> PersonStats {
        let msgs = chat.messages
        let first = msgs.first?.date ?? Date()
        let last = msgs.last?.date ?? Date()
        let span = max(1, Int(last.timeIntervalSince(first) / 86_400))
        var mine = 0, initiations = 0, myInitiations = 0
        var prev: Message?
        for m in msgs {
            if m.isFromMe { mine += 1 }
            if let p = prev, m.date.timeIntervalSince(p.date) > 4 * 3600 {
                initiations += 1
                if m.isFromMe { myInitiations += 1 }
            }
            prev = m
        }
        return PersonStats(
            name: name,
            messageCount: msgs.count,
            spanDays: span,
            daysSinceLast: max(0, Int(-last.timeIntervalSinceNow / 86_400)),
            perWeek: Double(msgs.count) / (Double(span) / 7),
            myShare: msgs.isEmpty ? 0 : Double(mine) / Double(msgs.count),
            myInitiationShare: initiations == 0 ? 0.5 : Double(myInitiations) / Double(initiations),
            groups: groups)
    }
}

enum Heuristics {
    /// Cheap counterpart classification. Ambiguous cases go to the model.
    static func classify(_ chat: Chat, resolvedName: String?) -> CounterpartKind? {
        guard !chat.isGroup else { return .person }
        let id = chat.identifier
        // Short-code senders (5-6 digits) are automated, full stop.
        if id.allSatisfy(\.isNumber), (4...6).contains(id.count) { return .automated }
        if id.lowercased().contains("no-reply") || id.lowercased().contains("noreply")
            || id.lowercased().contains("donotreply") { return .automated }
        let total = chat.messages.count
        let mine = chat.messages.filter(\.isFromMe).count
        // They broadcast, I never (or almost never) reply: business/notification.
        if total >= 8, Double(mine) / Double(total) < 0.05 { return .business }
        // A saved contact with a human-looking two-part name is a person.
        if let name = resolvedName, name.contains(" "), !name.contains("@") { return .person }
        return nil   // ambiguous → model
    }
}
