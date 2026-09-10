import Foundation
import StandingBots

/// Defaults-backed design experiment, following NativeAgentShellPreference.
enum BotsShelfPreference {
    static let key = "uiBotsShelfPreview"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Option B groups, preserving callers' filtered destinations and the Bots gate.
enum BotsShelfRailProposal {
    static func destinations(_ items: [SidebarItem], enabled: Bool) -> [String] {
        guard enabled else { return items.map(\.rawValue) }
        return everyday(items).map(\.rawValue) + ["Bots"] + configuration(items).map(\.rawValue)
            + items.filter { $0 == .settings }.map(\.rawValue)
    }

    static func everyday(_ items: [SidebarItem]) -> [SidebarItem] {
        [.chat, .activity, .memories, .desk, .inboxPolicy].filter(items.contains)
    }

    static func configuration(_ items: [SidebarItem]) -> [SidebarItem] {
        items.filter { !everyday(items).contains($0) && $0 != .settings }
    }
}

/// Value-only shelf projection. No store, acknowledgement, scheduling or budget writes.
struct BotsShelfRecord: Identifiable {
    var definition: BotDefinition
    var entries: [ShelfEntry]
    var unreadIDs: Set<UUID>
    var nextRun: Date?
    var unread: Int { unreadIDs.count }
    var sortedEntries: [ShelfEntry] { entries.sorted { $0.runAt > $1.runAt } }
    var latestProblem: ShelfEntry? {
        sortedEntries.first { $0.runHealth == .partial || $0.runHealth == .failed || !$0.uncertainties.isEmpty }
    }
    var catchUp: [ShelfEntry] {
        let warning = latestProblem
        return sortedEntries.filter { unreadIDs.contains($0.id) || $0.id == warning?.id }
            .sorted { left, right in
                if left.id == warning?.id { return right.id != warning?.id }
                if right.id == warning?.id { return false }
                return left.runAt > right.runAt
            }
    }
    var id: UUID { definition.id }
    func metadata(state: String? = nil) -> String {
        let choice = [definition.provider.map(Self.providerLabel), definition.model].compactMap { $0 }.joined(separator: " · ")
        let last = sortedEntries.first.map { Self.metadataDate($0.runAt) } ?? "Never"
        let next = nextRun.map(Self.metadataDate) ?? (definition.cadence == .manual || definition.paused ? "—" : "Not scheduled yet")
        let status = state ?? (definition.paused ? "Paused" : sortedEntries.first?.runtimeStatus == .waitingForApproval ? "Waiting for approval" : "Ready")
        return "\(choice.isEmpty ? "Model not selected" : choice) / \(definition.reasoningEffort?.capitalized ?? "Think not selected") · \(cadence) · Last \(last) · Next \(next) · \(status)"
    }
    static func providerLabel(_ id: String) -> String {
        // The same names the Providers page shows for each account.
        switch id.lowercased() {
        case "openai_oauth_direct": "ChatGPT (OAuth)"
        case "codex": "Codex CLI"
        case "openai": "OpenAI (API key)"
        case "anthropic_oauth_direct": "Anthropic (OAuth / Setup-Token)"
        case "anthropic", "claude", "claude-code": "Anthropic (API key)"
        case "kimi-code": "Kimi Code"
        case "moonshot": "Moonshot AI (Kimi)"
        case "xai_oauth_direct": "xAI Grok (OAuth)"
        case "openrouter": "OpenRouter"
        case "google", "gemini": "Google"
        default: id
        }
    }
    static func shortDate(_ date: Date) -> String { metadataDate(date) }
    private static func metadataDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return formatter.string(from: date)
    }
    /// "GPT-5.5 · Low · Weekly": what the bot runs on and when.
    var choiceLine: String {
        guard let model = definition.model else { return "Same model as Chat · \(cadence)" }
        return [model, definition.reasoningEffort?.capitalized, cadence].compactMap { $0 }.joined(separator: " · ")
    }
    /// "Twice daily · Next Sep 9 at 11:00 AM", "Paused", or "Manual": whether it will run again.
    var scheduleLine: String {
        if definition.paused { return "Paused" }
        if case .manual = definition.cadence { return "Manual" }
        if let nextRun { return "\(cadence) · Next \(Self.metadataDate(nextRun))" }
        return "\(cadence) · Not scheduled yet"
    }
    /// "Last Sep 10 at 1:47 AM · Next Sep 17 at 1:47 AM", or the part that exists.
    var timingLine: String {
        var parts: [String] = []
        if let last = sortedEntries.first { parts.append("Last \(Self.metadataDate(last.runAt))") }
        if let nextRun, !definition.paused { parts.append("Next \(Self.metadataDate(nextRun))") }
        return parts.isEmpty ? "No runs yet" : parts.joined(separator: " · ")
    }
    /// "Sep 10 at 1:47 AM · Blocked. I don't have a headless fetch tool": when it last
    /// spoke and the first line of what it said, so a card is never just a timestamp.
    var lastOutcomeLine: String {
        guard let last = sortedEntries.first else { return "No runs yet" }
        let firstLine = last.actualReply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }?.replacingOccurrences(of: "**", with: "")
        let said: String
        switch last.runtimeStatus {
        case .completed: said = firstLine.map { "Reply saved: " + $0 } ?? (last.runHealth == .nothingNew ? "Checked, nothing new" : "Ended, nothing saved")
        case .waitingForApproval: said = "Waiting for approval"
        case .failed, .interrupted:
            // The cause when one was recorded; never invented.
            if last.runtimeStatus == .interrupted, let detail = last.statusDetail ?? firstLine.map({ "partial reply kept: " + $0 }) {
                said = "Interrupted, \(detail)"
            } else {
                said = "\(last.runtimeStatus == .failed ? "Failed" : "Interrupted"): \(last.statusDetail ?? "cause not recorded")"
            }
        }
        return "\(Self.metadataDate(last.runAt)) · \(said)"
    }
    var lastGood: ShelfEntry? {
        entries.filter { [.ok, .nothingNew].contains($0.runHealth) }.max { $0.runAt < $1.runAt }
    }
    var cadence: String {
        switch definition.cadence {
        case .manual: "Manual only"
        case .interval(let seconds):
            seconds == 43200 ? "Twice daily" : seconds == 86400 ? "Daily" : seconds == 604800 ? "Weekly"
                : seconds < 3600 ? "Every \(Int(seconds / 60)) minutes"
                : seconds.truncatingRemainder(dividingBy: 86400) == 0 ? "Every \(Int(seconds / 86400)) days"
                : "Every \((seconds / 3600).formatted()) hours"
        case .cron(let expression, let timeZone): "\(expression) · \(timeZone)"
        }
    }
    var state: String {
        if definition.paused { return "Paused" }
        return entries.max { $0.runAt < $1.runAt }.map { Self.health($0.runHealth) } ?? "No runs yet"
    }
    static func health(_ health: ShelfRunHealth) -> String {
        switch health {
        case .ok: "Checked · findings available"
        case .nothingNew: "Checked, nothing new"
        case .partial: "Partly checked · coverage incomplete"
        case .failed: "Could not check"
        }
    }
    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func exactDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }
}
