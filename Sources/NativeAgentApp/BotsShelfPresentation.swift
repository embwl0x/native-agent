import Foundation
import PersistenceCore
import StandingBots

/// Defaults-backed design experiment, following NativeAgentShellPreference.
enum BotsShelfPreference {
    static let key = "uiBotsShelfPreview"
    /// On unless the person switched it off (User: fresh installs turn everything on).
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
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

/// A bot occurrence that never ran, for the Desk's schedule fold. Read-only.
struct DeskMissedBot: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let line: String
    let dueAt: Date

    static func load(root: URL) -> [DeskMissedBot] {
        guard let missed = try? BotRunnerScheduler.missedRuns(dataRoot: root), !missed.isEmpty,
              let bots = try? BotDefinitionStore(dataRoot: root).list() else { return [] }
        return bots.compactMap { bot in
            guard let run = missed[bot.id] else { return nil }
            return DeskMissedBot(id: bot.id, name: bot.name,
                                 line: "Missed · \(run.words).", dueAt: run.dueAt)
        }.sorted { $0.dueAt > $1.dueAt }
    }
}

/// What the Bots page says when unattended work is switched off.
enum BotsShelfUnattended {
    static let pageLine = "Scheduled and event runs are off. Run once still works \u{2014} turn on \u{201C}Let the agent work unattended\u{201D} in Trust, or choose Full Mac."
    static let cardLine = "Won\u{2019}t run on its own: unattended work is off"
}

/// Value-only shelf projection. No store, acknowledgement, scheduling or budget writes.
struct BotsShelfRecord: Identifiable, Equatable, Sendable {
    var definition: BotDefinition
    var entries: [ShelfEntry]
    var unreadIDs: Set<UUID>
    var nextRun: Date?
    /// The last occurrence the scheduler found already past its window.
    var missed: BotMissedRun?
    /// The last event that woke this bot, when it wakes on one.
    var lastEvent: BotEventRecord? = nil
    /// Whether the agent may work unattended at all
    /// (`BackgroundLoopsAssembly.unattendedWorkAllowed`). False means the
    /// scheduler never wakes for this bot, so the card must not show a time.
    var unattendedAllowed: Bool = true
    var unread: Int { unreadIDs.count }
    /// "Missed Sep 12 at 9:00 AM · the Mac was asleep", or nothing to say.
    var missedLine: String? {
        guard let missed else { return nil }
        return "Missed \(Self.metadataDate(missed.dueAt)) · \(missed.words)"
    }
    var sortedEntries: [ShelfEntry] { entries.sorted { $0.runAt > $1.runAt } }
    var id: UUID { definition.id }
    /// User, 2026-09-13: a bot runs on the model it was made with. One saved
    /// before that rule has none, and says so instead of quietly running on
    /// Chat's — it does not run at all until a model is chosen.
    var needsModelChoice: Bool { definition.needsModelChoice }
    func metadata(state: String? = nil) -> String {
        let choice = [definition.provider.map(Self.providerLabel), definition.model].compactMap { $0 }.joined(separator: " · ")
        let last = sortedEntries.first.map { Self.metadataDate($0.runAt) } ?? "Never"
        let next = nextRun.map(Self.metadataDate) ?? (definition.cadence == .manual || definition.paused ? "—" : "Not scheduled yet")
        let status = state ?? (needsModelChoice ? "Choose a model" : definition.paused ? "Paused" : sortedEntries.first?.runtimeStatus == .waitingForApproval ? "Waiting for approval" : "Ready")
        return "\(needsModelChoice ? "Choose a model" : choice) / \(definition.reasoningEffort?.capitalized ?? "Think not selected") · \(cadence) · Last \(last) · Next \(next) · \(status)"
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
        formatter.timeZone = DisplayTimeZone.current
        return formatter.string(from: date)
    }
    /// "GPT-5.5 · Low · Weekly": what the bot runs on and when.
    var choiceLine: String {
        guard let model = definition.model else { return "Same model as Chat · \(cadence)" }
        return [model, definition.reasoningEffort?.capitalized, cadence].compactMap { $0 }.joined(separator: " · ")
    }
    /// "Wakes on: GitHub · owner/repo", plus the last event when one arrived.
    var wakeLine: String? {
        guard let trigger = definition.eventTrigger else { return nil }
        var line = "Wakes on: " + trigger.label
        if let event = lastEvent {
            let when = Self.metadataDate(event.at)
            switch event.outcome {
            case .queued: line += " · Last event \(when) · " + event.summary
            case .held: line += " · Last event \(when) held: " + (event.detail ?? "Autonomy is off")
            case .notRun: line += " · Last event \(when) not run: " + (event.detail ?? "reason not recorded")
            }
        } else {
            line += " · No event yet"
        }
        return line
    }
    /// "Twice daily · Next Sep 9 at 11:00 AM", "Paused", or "Manual": whether it will run again.
    /// Only a manual bot with NO event trigger still runs with the gate off:
    /// the person pressing Run once is the whole schedule. A manual bot that
    /// wakes on events does not — BotEventIntake holds the event.
    var runsWithUnattendedOff: Bool {
        guard definition.eventTrigger == nil else { return false }
        if case .manual = definition.cadence { return true }
        return false
    }
    var scheduleLine: String {
        if needsModelChoice { return "Choose a model" }
        if definition.paused { return "Paused" }
        // Unattended work off: the scheduler returns no deadline and the event
        // intake holds every event, so a time or a wake line would be a lie.
        if !unattendedAllowed, !runsWithUnattendedOff { return BotsShelfUnattended.cardLine }
        if let wakeLine { return wakeLine }
        if case .manual = definition.cadence { return "Manual" }
        if let nextRun { return "\(cadence) · Next \(Self.metadataDate(nextRun))" }
        return "\(cadence) · Not scheduled yet"
    }
    /// "Last Sep 10 at 1:47 AM · Next Sep 17 at 1:47 AM", or the part that exists.
    var timingLine: String {
        var parts: [String] = []
        if let last = sortedEntries.first { parts.append("Last \(Self.metadataDate(last.runAt))") }
        // Same rule as scheduleLine: with unattended work off the stored
        // deadline is never reached, so detail must not show it either.
        if let nextRun, !definition.paused, unattendedAllowed || runsWithUnattendedOff {
            parts.append("Next \(Self.metadataDate(nextRun))")
        }
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
        // The run raised a card and is waiting to be answered. Not a fault,
        // and never "Interrupted" (Agent, 2026-09-13).
        case .waitingOnPerson: said = last.statusDetail.map { "Waiting on you — \($0)" } ?? "Waiting on you"
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
        if needsModelChoice { return "Choose a model" }
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
        formatter.timeZone = DisplayTimeZone.current
        return formatter.string(from: date)
    }
}

/// The run feed behind a bot's detail. Five uneventful checks used to push
/// yesterday's finding off the card; consecutive completed `.nothingNew` runs
/// now fold into one dated row that keeps its count, and the exact runs are
/// still there when the row is opened.
enum BotRunFeed {
    enum Row: Identifiable {
        case run(ShelfEntry)
        case quiet([ShelfEntry])   // newest first, at least two

        var id: String {
            switch self {
            case .run(let entry): return entry.id.uuidString
            case .quiet(let entries): return "quiet:\(entries.first?.id.uuidString ?? "")"
            }
        }
    }

    /// A run that said nothing and ended cleanly. Findings, artifacts, failures
    /// and approval waits are never folded.
    static func isQuiet(_ entry: ShelfEntry) -> Bool {
        entry.runtimeStatus == .completed
            && entry.runHealth == .nothingNew
            && entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (entry.artifacts ?? []).isEmpty
    }

    static func rows(_ sortedEntries: [ShelfEntry]) -> [Row] {
        var rows: [Row] = []
        var quiet: [ShelfEntry] = []
        func flush() {
            if quiet.count >= 2 {
                rows.append(.quiet(quiet))
            } else {
                rows.append(contentsOf: quiet.map { Row.run($0) })
            }
            quiet = []
        }
        for entry in sortedEntries {
            if isQuiet(entry) {
                quiet.append(entry)
            } else {
                flush()
                rows.append(.run(entry))
            }
        }
        flush()
        return rows
    }

    /// "Three quiet checks since Sep 10 at 1:47 AM" — the count stays visible.
    static func quietLine(_ entries: [ShelfEntry]) -> String {
        let since = entries.last.map { BotsShelfRecord.shortDate($0.runAt) }
        return "\(TodayWords.spelled(entries.count)) quiet check\(entries.count == 1 ? "" : "s")"
            + (since.map { " since \($0)" } ?? "")
    }
}
