import AgentWorkspace
import ChatToolRuntime
import CognitiveSubstrate
import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import NativeAgentShared

// Blueprint: | `NativeCognitionRuntime+Rhythm.swift` | `NativeCognitionRuntime`. |

struct RhythmRuntimeState: Sendable {
    var value: PersonRhythm?
    var observation: Task<Void, Never>?
    var refresh: Task<Void, Never>?
    var dirty = false
    var awakeSince: Date?
    var present = false
    var day: Date?
    var due: Date?
    var dueClaim: PersonRhythm.Claim?
    var zone: String?
    var nightDue: Date?
    var nightEpoch = UUID().uuidString
}

extension NativeCognitionRuntime {
    func startRhythmObservation() {
        guard !isFlushedForTermination, rhythm.observation == nil else { return }
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [dataRoot.appendingPathComponent("cognition/user_turn.json")])
        rhythm.awakeSince = now()
        rhythm.observation = Task { [weak self] in
            await self?.rhythmChanged()
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.rhythmChanged()
            }
        }
    }

    func rhythmChanged() async {
        guard !isFlushedForTermination else { return }
        rhythm.dirty = true
        await rescheduleResidualRepairDeadline()
    }

    /// Release presence-carried work only after the presence edge reaches this owner.
    public func rhythmPresenceChanged(here: Bool) async {
        guard !isFlushedForTermination else { return }
        let at = now()
        // Close prior state before changing it; coalesce edges in the actor and keep refresh I/O off the turn path.
        do {
            try refreshRhythmInterval(at: at)
            rhythm.present = here
            if here { try observeRhythmActivity(.init(at: at, door: "presence")) }
        } catch { reportRhythmFailure(error); return }
        await rhythmChanged()
    }

    /// Use workspace wake/sleep edges rather than sampled uptime.
    public func rhythmAwakeChanged(awake: Bool, here: Bool?) async {
        guard !isFlushedForTermination else { return }
        let at = now()
        do {
            try refreshRhythmInterval(at: at)
            rhythm.awakeSince = awake ? at : nil
            if awake { rhythm.nightEpoch = UUID().uuidString }
            // Resume from the presence owner's reading, never the false value left by sleep.
            rhythm.present = awake && here == true
            if rhythm.present { try observeRhythmActivity(.init(at: at, door: "presence")) }
        } catch { reportRhythmFailure(error); return }
        await rhythmChanged()
    }

    private func loadRhythm() throws -> PersonRhythm {
        if let value = rhythm.value { return value }
        if let value = try PersonRhythm.load(dataRoot) { return value }
        let at = now()
        var value = PersonRhythm(at: at)
        let rows = try ChatHistoryIndex.shared(dataRoot: dataRoot).ownerActivity(
            since: at.addingTimeInterval(-30 * 86_400), until: at,
            telegramOwnerUserId: host.telegramOwnerUserId(dataRoot: dataRoot))
        try value.coldStart(rows.map { .init(at: $0.at, door: $0.door) }, at: at)
        return value
    }

    private func refreshRhythmInterval(at: Date) throws {
        var value = try loadRhythm()
        if value.timeZone != TimeZone.current.identifier { try value.recompute(at: at) }
        if let since = rhythm.awakeSince {
            if rhythm.present, let claim = value.claims.first(where: { $0.kind == .quiet }) {
                var cursor = max(since, at.addingTimeInterval(-86_400))
                while cursor < at, let hour = Calendar.current.dateInterval(of: .hour, for: cursor) {
                    if claim.contains(hour: Calendar.current.component(.hour, from: cursor)) {
                        try keepRhythmBreak("quiet", claim: claim, at: cursor, in: &value)
                    }
                    cursor = min(at, hour.end)
                }
            }
            value.observed(from: since, to: at, present: rhythm.present)
            rhythm.awakeSince = at
        }
        try value.recompute(at: at)
        rhythm.value = value
    }

    private func observeRhythmActivity(_ activity: PersonRhythm.Activity) throws {
        var value = try loadRhythm()
        if value.timeZone != TimeZone.current.identifier { try value.recompute(at: now()) }
        let h = Calendar.current.component(.hour, from: activity.at)
        if let claim = value.claims.first(where: { $0.kind == .quiet && $0.contains(hour: h) }) {
            try keepRhythmBreak("quiet", claim: claim, at: activity.at, in: &value)
        }
        value.activity(activity)
        try value.recompute(at: now())
        rhythm.value = value
    }

    private func keepRhythmBreak(_ kind: String, claim: PersonRhythm.Claim, at: Date, in value: inout PersonRhythm) throws {
        let day = Calendar.current.startOfDay(for: at)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: at)
        guard let year = parts.year, let month = parts.month, let date = parts.day else { throw CocoaError(.coderReadCorrupt) }
        let id = "rhythm:\(kind):\(year)-\(month)-\(date)"
        guard value.breaks[id] == nil else { return }
        value.breaks[id] = day
        value.pending[id] = .init(at: at, claim: claim)
    }

    func considerRhythm(runNow: Bool = false, reply: MindClockReply? = nil) {
        guard !isFlushedForTermination, rhythm.refresh == nil else {
            reply?(.init("held", "The person's day is already refreshing or the runtime is stopping.")); return
        }
        guard runNow || rhythm.dirty || rhythm.due.map({ $0 <= now() }) == true || rhythm.nightDue.map({ $0 <= now() }) == true else { return }
        rhythm.dirty = false
        rhythm.refresh = Task { [weak self] in
            guard let self else { reply?(.init("unavailable", "The runtime was released.")); return }
            let result = await self.refreshRhythm(satisfyWait: runNow)
            if let reply { reply(result) } else { await self.beat(.rhythm, result) }
            await self.finishRhythmRefresh()
        }
    }

    private func finishRhythmRefresh() async {
        await senseNight()
        rhythm.refresh = nil
        await rescheduleResidualRepairDeadline()
    }

    /// The record owns night identity; part accounting and dream consumption have independent cursors.
    public func restReading(at: Date) async throws -> JSONValue {
        let last = try await ExperienceStore.at(dataRoot).details(.init(sources: [Attention.detailSource], subjects: ["night", "sleep"],
            kinds: [Attention.nightKind], limit: 1, newestFirst: true)).first?.at
        let presence = PersonPresence.read(dataRoot: dataRoot, now: at).transition
        let value = try loadRhythm()
        let hour = Calendar.current.component(.hour, from: at)
        guard let bin = value.bins.dropFirst(hour).first else { throw CocoaError(.coderReadCorrupt) }
        return .object([
            "awayMinutes": presence.flatMap { !$0.here ? .double(max(0, at.timeIntervalSince($0.since)) / 60) : nil } ?? .null,
            "activeShare": bin.observed > 0 ? .double(bin.active / bin.observed) : .null,
            "hoursSinceNight": last.map { .double(max(0, at.timeIntervalSince($0)) / 3600) } ?? .null
        ])
    }

    /// The next reading is a sense boundary, never a promised bedtime.
    public func nextNight() async throws -> JSONValue {
        let rest = try await restReading(at: now())
        return .object(["state": .string("available"), "rest": rest,
            "at": rhythm.nightDue.map { .double($0.timeIntervalSince1970) } ?? .null,
            "reason": .string(rhythm.nightDue == nil ? "Waiting for the person to be away." : "The next reading of the night; sleep is my judgment.")])
    }

    func personTurnAt() throws -> Date? {
        struct Stamp: Decodable { let at: Double }
        let data: Data
        do { data = try Data(contentsOf: dataRoot.appendingPathComponent("cognition/user_turn.json")) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let stamp = try JSONDecoder().decode(Stamp.self, from: data)
        guard stamp.at.isFinite else { throw CocoaError(.coderReadCorrupt) }
        return Date(timeIntervalSince1970: stamp.at)
    }

    /// A source deadline reports time; only the turn program judges the world line. The body owns its 48-hour need.
    private func senseNight() async {
        rhythm.nightDue = nil
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        let at = now()
        guard let presence = PersonPresence.read(dataRoot: dataRoot, now: at).transition, !presence.here else { return }
        do {
            let rest = try await restReading(at: at)
            guard let boundary = Calendar.current.dateInterval(of: .hour, for: at)?.end else { throw CocoaError(.coderReadCorrupt) }
            let first = presence.since.addingTimeInterval(30 * 60)
            rhythm.nightDue = first > at ? min(first, boundary) : boundary
            guard at >= first else { return }
            let hours = rest.objectValue?["hoursSinceNight"]?.numberValue(coercingStrings: false, finiteOnly: true)
            if let hours, hours < 48 {
                rhythm.nightDue = min(boundary, at.addingTimeInterval((48 - hours) * 3600))
            }
            let body = hours == nil || hours.map { $0 >= 48 } == true
            guard let slot = Calendar.current.dateInterval(of: .hour, for: at)?.start else { throw CocoaError(.coderReadCorrupt) }
            let once = ["night", body ? "body" : "world", rhythm.nightEpoch,
                        String(presence.since.timeIntervalSince1970), String(slot.timeIntervalSince1970)].joined(separator: ":")
            let happening = Happening(body ? .body : .world, subject: "night", door: "sense:night", who: "self",
                words: body ? "My body needs a night." : "The person is away; this is the hour and the rest I have had.",
                once: once,
                shows: try rest.serialize(pretty: false))
            await Attention.post(happening, dataRoot: dataRoot).value
        } catch { reportRhythmFailure(error) }
    }

    private func refreshRhythm(satisfyWait: Bool = false) async -> MindClockResult {
        guard !isFlushedForTermination, !Task.isCancelled else { return .init("stopped", "The person's day refresh stopped.") }
        do {
            try refreshRhythmInterval(at: now())
            struct Stamp: Decodable { var at: Double; var key: String; var door: String? }
            let path = dataRoot.appendingPathComponent("cognition/user_turn.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let stamp = try JSONDecoder().decode(Stamp.self, from: Data(contentsOf: path))
                guard stamp.at.isFinite else { throw CocoaError(.coderReadCorrupt) }
                if rhythm.value?.lastTurnKey != stamp.key {
                    try observeRhythmActivity(.init(at: Date(timeIntervalSince1970: stamp.at), door: stamp.door ?? "chat"))
                    rhythm.value?.lastTurnKey = stamp.key
                }
            }
            guard var value = rhythm.value else { return .init("unavailable", "The person's day has no readable rhythm.") }
            let at = now(), calendar = Calendar.current, day = calendar.startOfDay(for: at)
            if rhythm.day != day || rhythm.zone != TimeZone.current.identifier {
                rhythm.day = day
                rhythm.zone = TimeZone.current.identifier
                rhythm.dueClaim = value.claims.first { $0.kind == .startsBy }
                rhythm.due = rhythm.dueClaim.flatMap {
                    calendar.date(bySettingHour: $0.to / 60, minute: $0.to % 60, second: 0, of: day)
                }
            } else if rhythm.dueClaim == nil, let claim = value.claims.first(where: { $0.kind == .startsBy }) {
                rhythm.dueClaim = claim
                rhythm.due = calendar.date(bySettingHour: claim.to / 60, minute: claim.to % 60, second: 0, of: day)
            }
            if value.started(on: day) { rhythm.due = nil }
            if let due = rhythm.due, satisfyWait || due <= at, let claim = rhythm.dueClaim {
                rhythm.due = nil
                if !value.started(on: day) {
                    try keepRhythmBreak("starts", claim: claim, at: at, in: &value)
                }
            }
            // Publish canonical state before awaiting so reentrant arrivals update the current value.
            try value.save(dataRoot)
            rhythm.value = value
            var felt = 0
            for (id, pending) in value.pending.sorted(by: { $0.key < $1.key }) {
                guard !isFlushedForTermination, !Task.isCancelled else {
                    return .init("stopped", "The person's day stopped; remaining rhythm breaks stay pending.")
                }
                let words = pending.words(person: AgentScreen.names(dataRoot).person)
                let event = CognitiveEvent(id: id, kind: .organismResolutionFelt,
                    subject: .init(type: "person_rhythm", id: id, label: "the person's day"),
                    sourceClass: .observed, occurredAt: pending.at, summary: words, importance: 0.6,
                    metadata: ["feltValence": .double(0), "feltArousal": .double(0.2), "resolutionKind": .string("rhythm")])
                // Without a live care, emit no fact; presence felt admission cannot release news or open a thought.
                if try await substrate.feelRhythmBreak(event) {
                    felt += 1
                    scheduleDirtyMicrocycle(reason: "rhythm_break")
                }
                rhythm.value?.pending.removeValue(forKey: id)
            }
            // Pending settlement or an arrival during suspension may change the current value; an identical second write does nothing.
            if let current = rhythm.value, current != value { try current.save(dataRoot) }
            RepairOwed.settle(dataRoot, operation: "mind.rhythm",
                             evidence: .init(source: PersonRhythm.path(dataRoot).path, id: "\(at.timeIntervalSince1970)"))
            return .init("refreshed",
                """
                    The person's real awake and activity history was kept; \(felt) care-admitted rhythm breaks felt, \(value.pending.count) considered. \
                    No thought was opened.
                    """, fields: [
                "felt": .int(Int64(felt)), "considered": .int(Int64(value.pending.count)),
                "path": .string(PersonRhythm.path(dataRoot).path)
            ], yield: felt)
        } catch { reportRhythmFailure(error); return .init("unavailable", error.localizedDescription) }
    }

    private func reportRhythmFailure(_ error: Error) {
        ModuleLog(category: "Cognition")("The person's day could not be kept: %@", error.localizedDescription)
        RepairOwed.owe(dataRoot, id: "rhythm", kind: .run, operation: "mind.rhythm", owner: "The person's day",
                      words: error.localizedDescription,
                          tap: "Read mind/rhythm.json and its source history; repair the reported cause, preserving the evidence.")
    }

    /// Close the real awake interval within the shared sleep settlement.
    func settleRhythmForSleep() {
        guard var value = rhythm.value else { return }
        let at = now()
        if let since = rhythm.awakeSince { value.observed(from: since, to: at, present: rhythm.present) }
        do { try value.recompute(at: at); try value.save(dataRoot); rhythm.value = value }
        catch { reportRhythmFailure(error) }
        rhythm.awakeSince = nil
    }
}
