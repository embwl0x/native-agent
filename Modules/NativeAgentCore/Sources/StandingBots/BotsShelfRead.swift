import Foundation
import NativeAgentCore
// Blueprint: | `BotsShelfRead.swift` | Shelf and Desk consume `BotRunnerScheduler.Projection`; one running/queued/model-choice/pause/run-status classification for Mac, quiet reads and iPhone; approval and run-feed read models |

/// A bot occurrence that never ran, for the Desk's schedule fold. Read-only.
public struct DeskMissedBot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let line: String
    public let dueAt: Date

    public static func load(root: URL, timing: BotRunnerScheduler.Projection) -> [DeskMissedBot] {
        let missed = timing.missed
        guard !missed.isEmpty,
              let bots = try? BotDefinitionStore(dataRoot: root).list() else { return [] }
        return bots.compactMap { bot in
            guard bot.cadence != .manual, let run = missed[bot.id] else { return nil }
            return DeskMissedBot(id: bot.id, name: bot.name,
                                 line: "Missed · \(run.words).", dueAt: run.dueAt)
        }.sorted { $0.dueAt > $1.dueAt }
    }
}

/// An unpaused bot on a schedule, for the Desk's schedule fold. Read-only.
public struct DeskTimedBot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let line: String
    public let nextRun: Date?

    public static func load(root: URL, timing: BotRunnerScheduler.Projection) -> [DeskTimedBot] {
        guard let bots = try? BotDefinitionStore(dataRoot: root).list() else { return [] }
        return bots.filter { !$0.paused && $0.cadence != .manual }.map { bot in
            DeskTimedBot(id: bot.id, name: bot.name, line: BotsShelfRecord.cadence(bot.cadence) + ".", nextRun: timing.dates[bot.id])
        }
    }
}

/// What the Bots page says when unattended work is switched off.
public enum BotsShelfUnattended {
    public static let pageLine = "Scheduled and event runs are off. Run once still works \u{2014} turn on \u{201C}Let me work unattended\u{201D} in Trust, or choose Full Mac."
    public static let cardLine = "Won\u{2019}t run on its own: unattended work is off"
}

/// Value-only shelf projection. No store, acknowledgement, scheduling or budget writes.
public struct BotsShelfRecord: Identifiable, Equatable, Sendable {
    public var definition: BotDefinition
    public var entries: [ShelfEntry]
    public var nextRun: Date?
    /// The last occurrence the scheduler found already past its window.
    public var missed: BotMissedRun?
    /// The last event that woke this bot, when it wakes on one.
    public var lastEvent: BotEventRecord? = nil
    /// The scheduler's unattended admission; false suppresses scheduled dates,
    /// while queued manual requests remain runnable.
    public var unattendedAllowed: Bool = true
    public var followingModel: String? = nil
    public var running = false
    public var queued = false
    public enum Status: String, Sendable {
        case running = "Running", queued = "Queued", paused = "Paused", new = "New"
        case needsModelChoice = "Choose a model"
        case waitingForApproval = "Waiting for approval", waitingOnPerson = "Waiting on you"
        case failed = "Failed", stopped = "Stopped", interrupted = "Interrupted", ready = "Ready"
    }
    public var status: Status {
        if running { return .running }
        if queued { return .queued }
        if needsModelChoice { return .needsModelChoice }
        if definition.paused { return .paused }
        guard let latest = entries.max(by: { $0.runAt < $1.runAt }) else { return .new }
        switch latest.runtimeStatus {
        case .waitingForApproval: return .waitingForApproval
        case .waitingOnPerson: return .waitingOnPerson
        case .failed: return .failed
        case .stopped: return .stopped
        case .interrupted: return .interrupted
        case .completed: return .ready
        }
    }
    public var statusWord: String {
        status == .paused ? definition.offReason ?? status.rawValue : status.rawValue
    }
    /// "Missed Sep 12 at 9:00 AM · the Mac was asleep", or nothing to say.
    public var missedLine: String? {
        guard let missed else { return nil }
        return "Missed \(Self.metadataDate(missed.dueAt)) · \(missed.words)"
    }
    public var sortedEntries: [ShelfEntry] { entries.sorted { $0.runAt > $1.runAt } }
    public var id: UUID { definition.id }
    public var needsModelChoice: Bool { definition.needsModelChoice }
    public static func shortDate(_ date: Date) -> String { metadataDate(date) }
    private static func metadataDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return formatter.string(from: date)
    }
    public var choiceLine: String {
        definition.modelSelection(currentModel: followingModel) + " · " + cadence
    }
    /// "Wakes on: Slack · C0123ABCD", plus the last event when one arrived.
    public var wakeLine: String? {
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
    public var runsWithUnattendedOff: Bool {
        guard definition.eventTrigger == nil else { return false }
        if case .manual = definition.cadence { return true }
        return false
    }
    public var scheduleLine: String {
        if needsModelChoice { return "Choose a model" }
        if definition.paused { return definition.offReason ?? "Paused" }
        // Unattended work off: the scheduler returns no deadline and the event
        // intake holds every event, so a time or a wake line would be a lie.
        if !unattendedAllowed, !runsWithUnattendedOff { return BotsShelfUnattended.cardLine }
        if let wakeLine { return wakeLine }
        if case .manual = definition.cadence { return "Manual" }
        if let nextRun { return "\(cadence) · Next \(Self.metadataDate(nextRun))" }
        return "\(cadence) · Not scheduled yet"
    }
    /// "Last Sep 10 at 1:47 AM · Next Sep 17 at 1:47 AM", or the part that exists.
    public var timingLine: String {
        var parts: [String] = []
        if let last = sortedEntries.first { parts.append("Last \(Self.metadataDate(last.runAt))") }
        if let nextRun {
            parts.append("Next \(Self.metadataDate(nextRun))")
        }
        return parts.isEmpty ? "No runs yet" : parts.joined(separator: " · ")
    }
    /// "Sep 10 at 1:47 AM · Blocked. I don't have a headless fetch tool": when it last
    /// spoke and the first line of what it said, so a card is never just a timestamp.
    public var lastOutcomeLine: String {
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
        case .stopped:
            said = last.statusDetail.map { "Stopped, " + $0 } ?? firstLine.map { "Stopped, partial reply kept: " + $0 } ?? "Stopped"
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
    public var cadence: String { Self.cadence(definition.cadence) }
    public static func cadence(_ cadence: BotCadence) -> String { StandingBotSchedule.words(cadence) }
    public static func health(_ health: ShelfRunHealth) -> String {
        switch health {
        case .ok: "Checked · findings available"
        case .nothingNew: "Checked, nothing new"
        case .partial: "Partly checked · coverage incomplete"
        case .failed: "Could not check"
        }
    }
    public static func read(root: URL, timing: BotRunnerScheduler.Projection, followingModel: String? = nil) throws -> [BotsShelfRecord] {
        let shelf = ShelfStore(dataRoot: root)
        let events = (try? BotEventStore(dataRoot: root).lastEvents()) ?? [:]
        // One checked bulk read for the whole shelf, instead of paginating
        // every bot's history and then re-reading each row through `entry`
        // (each of which decoded and sorted every book of every bot).
        let stored = try shelf.entriesByBot()
        let pending = ShelfStore.pendingApprovalIDs(dataRoot: root)
        let runs = try BotRunQueue(dataRoot: root).activeAndQueuedIDs()
        return try BotDefinitionStore(dataRoot: root).list().map { bot in
            // The shared shelf-reading boundary, the same one shelf_read and
            // shelf_entry go through: an approval resolved from Telegram or the
            // iPhone settles the entry wherever it is read next, not only here.
            let entries = shelf.reconciling(stored[bot.id] ?? [], pending: pending)
            return BotsShelfRecord(definition: bot, entries: entries,
                                   nextRun: timing.dates[bot.id],
                                   missed: bot.cadence == .manual ? nil : timing.missed[bot.id], lastEvent: events[bot.id],
                                   unattendedAllowed: timing.unattended, followingModel: followingModel,
                                   running: runs.active.contains(bot.id), queued: runs.queued.contains(bot.id))
        }.sorted { $0.definition.createdAt < $1.definition.createdAt }
    }
}

/// The run feed behind a bot's detail. Five uneventful checks used to push
/// yesterday's finding off the card; consecutive completed `.nothingNew` runs
/// now fold into one dated row that keeps its count, and the exact runs are
/// still there when the row is opened.
public enum BotRunFeed {
    public enum Row: Identifiable {
        case run(ShelfEntry)
        case quiet([ShelfEntry])   // newest first, at least two

        public var id: String {
            switch self {
            case .run(let entry): return entry.id.uuidString
            case .quiet(let entries): return "quiet:\(entries.first?.id.uuidString ?? "")"
            }
        }
    }

    /// A run that said nothing and ended cleanly. Findings, artifacts, failures
    /// and approval waits are never folded.
    public static func isQuiet(_ entry: ShelfEntry) -> Bool {
        entry.runtimeStatus == .completed
            && entry.runHealth == .nothingNew
            && entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (entry.artifacts ?? []).isEmpty
    }

    public static func rows(_ sortedEntries: [ShelfEntry]) -> [Row] {
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
}
