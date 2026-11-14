import Foundation
import NativeAgentCore
// Blueprint: | `BotsShelfRead.swift` | `BotRunnerScheduler.BotSchedule` drives shared shelf, Desk and phone classification |

public struct DeskMissedBot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let line: String
    public let dueAt: Date

    public static func load(root: URL, timing: BotRunnerScheduler.BotSchedule) throws -> [DeskMissedBot] {
        let missed = timing.missed
        guard !missed.isEmpty else { return [] }
        let bots = try BotDefinitionStore(dataRoot: root).list()
        return bots.compactMap { bot in
            guard bot.cadence != .manual, let run = missed[bot.id] else { return nil }
            return DeskMissedBot(id: bot.id, name: bot.name,
                                 line: "Missed · \(run.words).", dueAt: run.dueAt)
        }.sorted { $0.dueAt > $1.dueAt }
    }
}

public struct DeskTimedBot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let line: String
    public let nextRun: Date?

    public static func load(root: URL, timing: BotRunnerScheduler.BotSchedule) throws -> [DeskTimedBot] {
        let bots = try BotDefinitionStore(dataRoot: root).list()
        return bots.filter { !$0.paused && $0.cadence != .manual }.map { bot in
            DeskTimedBot(id: bot.id, name: bot.name, line: BotsShelfRecord.cadence(bot.cadence) + ".", nextRun: timing.dates[bot.id])
        }
    }
}

public enum BotsShelfUnattended {
    public static let pageLine = """
        Scheduled and event runs are off. Run once still works \u{2014} turn on \u{201C}Let me work unattended\u{201D} in \
        Trust, or choose Full Mac.
        """
    public static let cardLine = "Won\u{2019}t run on its own: unattended work is off"
}

/// Shelf projection cannot write stores, acknowledgements, scheduling or budgets.
public struct BotsShelfRecord: Identifiable, Equatable, Sendable {
    public var definition: BotDefinition
    public var entries: [ShelfEntry]
    public var nextRun: Date?
    public var missed: BotMissedRun?
    public var lastEvent: BotEventRecord? = nil
    /// Unattended refusal suppresses scheduled dates while explicit manual requests remain runnable.
    public var unattendedAllowed: Bool = true
    public var followingModel: String? = nil
    public var running = false
    public var queued = false
    public var startedAt: Date? = nil
    public var modelChoiceIssue: String? = nil
    public var runReadIssue: String? = nil
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
        guard let latest = latestEntry else { return .new }
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
        status.rawValue
    }
    /// Whether the helper waits on the person: for their answer, their approval or their choice of model.
    public var needsYou: Bool { [.waitingOnPerson, .waitingForApproval, .needsModelChoice].contains(status) }
    public var missedLine: String? {
        guard let missed else { return nil }
        return "Missed \(Self.metadataDate(missed.dueAt)) · \(missed.words)"
    }
    public var sortedEntries: [ShelfEntry] { entries.sorted { $0.runAt > $1.runAt } }
    /// Equal timestamps retain the first entry in recorded order.
    public var latestEntry: ShelfEntry? { entries.max { $0.runAt < $1.runAt } }
    public var id: UUID { definition.id }
    public var needsModelChoice: Bool { definition.needsModelChoice || modelChoiceIssue != nil }
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
    /// Manual-only work carries explicit authority; event-triggered manual cadences still require unattended admission.
    public var runsWithUnattendedOff: Bool {
        guard definition.eventTrigger == nil else { return false }
        if case .manual = definition.cadence { return true }
        return false
    }
    public var scheduleLine: String {
        if needsModelChoice { return "Choose a model" }
        if definition.paused { return "Paused" }
        // A date or wake line would promise work the scheduler and event intake cannot admit.
        if !unattendedAllowed, !runsWithUnattendedOff { return BotsShelfUnattended.cardLine }
        if let wakeLine { return wakeLine }
        if case .manual = definition.cadence { return "Manual" }
        if let nextRun { return "\(cadence) · Next \(Self.metadataDate(nextRun))" }
        return "\(cadence) · Not scheduled yet"
    }
    public var timingLine: String {
        var parts: [String] = []
        if let last = latestEntry { parts.append("Last \(Self.metadataDate(last.runAt))") }
        if let nextRun {
            parts.append("Next \(Self.metadataDate(nextRun))")
        }
        return parts.isEmpty ? "No runs yet" : parts.joined(separator: " · ")
    }
    /// Pair the observed reply with its time so a result card conveys more than a timestamp.
    public var lastOutcomeLine: String {
        guard let last = latestEntry else { return "No runs yet" }
        let firstLine = last.actualReply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }?.replacingOccurrences(of: "**", with: "")
        let said: String
        switch last.runtimeStatus {
        case .completed: said = firstLine.map { "Reply saved: " + $0 } ?? (last.runHealth == .nothingNew ? "Checked, nothing new" : "Ended, nothing saved")
        case .waitingForApproval: said = "Waiting for approval"
        // Awaiting a person's answer is a waiting status, not an interruption.
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
    public static func read(root: URL, timing: BotRunnerScheduler.BotSchedule, followingModel: String? = nil) throws -> [BotsShelfRecord] {
        let shelf = ShelfStore(dataRoot: root)
        let events = try BotEventStore(dataRoot: root).lastEvents()
        // One checked bulk read avoids repeatedly decoding and sorting the entire shelf.
        let stored = try shelf.entriesByBot()
        let runs = try BotRunQueue(dataRoot: root).shelfRuns()
        return try BotDefinitionStore(dataRoot: root).list().map { bot in
            let entries = stored[bot.id] ?? []
            return BotsShelfRecord(definition: bot, entries: entries,
                                   nextRun: timing.dates[bot.id],
                                   missed: bot.cadence == .manual ? nil : timing.missed[bot.id], lastEvent: events[bot.id],
                                   unattendedAllowed: timing.unattended, followingModel: followingModel,
                                   running: runs.active.contains(bot.id), queued: runs.queued.contains(bot.id),
                                   startedAt: runs.started[bot.id], runReadIssue: runs.issues[bot.id])
        }.sorted { $0.definition.createdAt < $1.definition.createdAt }
    }
}
