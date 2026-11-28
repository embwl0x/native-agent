import Foundation
import NativeAgentCore
import NativeAgentShared
import SenseCore
import MacNerves
import DeskCore
import MindCore
import PersistenceCore
// Blueprint: | `EngineScheduledWork.swift` | Attention's night and the clock's part schedules, watches, scans and helpers |

extension NativeAgentEngine {
    public static func clockWork(dataRoot: URL) -> ClockWork {
        ClockWork(root: dataRoot, attentionRouter: { NativeAgentEngine.forRoot(dataRoot).ports.backgroundWork.attention })
    }

    /// Asked times belong to their declaring owners. The night belongs to attention. Helpers attach and part times are followed;
    /// the deliveries themselves are the mind's (`handleClockOwners`).
    static func registerClockOwners(dataRoot: URL) async {
        let root = dataRoot.standardizedFileURL
        await NativeAgentEngine.live.bots.attach()
        await handleClockOwners(dataRoot: root)
        let changes = NotificationCenter.default.invalidations(for: AbilityStore.DidChange.self)
        await declarePartTimes(dataRoot: root)
        await retainLaunchWork {
            // A part header's schedule:<cron> is a part time; editing the part moves it, removing the wake withdraws it.
            for await _ in changes { await declarePartTimes(dataRoot: root) }
        }
    }

    /// The clock owners a running mind takes delivery for. While no mind runs their times stay pending, and are delivered once when the next mind
    /// handles them; the mind's own queue moments (`MyQueueReady.owner`) are handled by the runtime when it opens.
    static let mindClockOwners = ["part", "watch", "scan"]

    static func releaseClockOwners(dataRoot: URL) async {
        let clock = OneClock.at(dataRoot.standardizedFileURL)
        for owner in mindClockOwners + [MyQueueReady.owner] { await clock.release(owner) }
    }

    static func handleClockOwners(dataRoot: URL) async {
        let root = dataRoot.standardizedFileURL
        let clock = OneClock.at(root)
        await clock.handle("part") { time, _ in
            guard let part = time.payload?.objectValue?["part"]?.stringValue, let signal = time.payload?.objectValue?["signal"]?.stringValue else {
                ModuleLog.app("[clock] %@ carries no part and signal; nothing was posted", time.id)
                return
            }
            // The clock only posts the signal; the run is the part's, on its own gate chain, and recorded on the ability.
            AbilityStore(dataRoot: root).signal(signal, part: part, origin: .schedule)
        }
        await clock.handle("watch") { time, _ in await watch(time, dataRoot: root) }
        await clock.handle("scan") { time, _ in await scan(time, dataRoot: root) }
    }

    // MARK: - The night and REM

    /// The night, through attention or an explicit sleep request: the sleep thought runs the dream, then the night's reading of the agent's parts,
    /// and a thought of the agent's when the reading holds something. Returns its admission outcome; the stream holds the running night. With no mind
    /// running (setup not finished, or a reset closed it) there is no night to begin.
    public static func sleep(dataRoot: URL, attended: Attended? = nil, parent: Turn? = nil) async -> MindStream.NightOutcome {
        guard let stream = live.mind?.stream else { return .failed(cause: "The mind starts when setup finishes; there is no mind to sleep yet.") }
        return await sleep(dataRoot: dataRoot, attended: attended, parent: parent, on: stream)
    }

    static func sleep(dataRoot: URL, attended: Attended? = nil, parent: Turn? = nil, on stream: MindStream) async -> MindStream.NightOutcome {
        let root = dataRoot.standardizedFileURL
        return await stream.night(attended: attended, request: parent, dream: { parent, beganAt in
            await dreamTheNight(dataRoot: root, parent: parent, beganAt: beganAt)
            await nightREM(dataRoot: root)
        }, reading: { await EngineSleep.night(dataRoot: root) })
    }

    /// Today and Desk read the night sense independently of the dream's switch; neither can hide the other's facts or failure.
    func nextNightReading() async -> [String: JSONValue] {
        var reading: [String: JSONValue]
        do {
            let sense = try await Self.requiredMind(for: dataRoot).nextNight()
            guard let facts = sense.objectValue else { throw PersistenceCoreError.ioFailure("The night sense returned no fields.") }
            reading = facts
        } catch {
            reading = ["state": .string("unavailable"), "reason": .string(error.localizedDescription)]
        }
        do {
            let enabled = try await cognitionView.dreamEnabled()
            reading["dream"] = .object(["state": .string(enabled ? "enabled" : "off")])
        } catch {
            reading["dream"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        return reading
    }

    /// The night's owner: today's dream, exactly as the nightly dream ran it. A failure the dream did not already owe as repair is owed here.
    private static func dreamTheNight(dataRoot root: URL, parent: Turn, beganAt: Date) async {
        let detail: String
        do {
            var response: [String: Any]
            repeat {
                response = try await runDream(dataRoot: root, parent: parent, beganAt: beganAt)
            } while response["status"] as? String != "stopped" && response["remedy"] == nil
                && response["moreMessagesRemain"] as? Bool == true && response["entriesWritten"] as? Int ?? 0 > 0
            guard response["remedy"] == nil, (response["skipReason"] as? String) == "already_running" else { return }
            detail = "another dream run held the reservation while the night began"
        } catch DreamREMCycleError.cycleDisabled(_, _) {
            return
        } catch is CancellationError {
            // Stop is not a failure of the night: nothing is owed for it.
            return
        } catch {
            detail = JSONValue.describe(error)
        }
        await RepairOwed.owe(root, id: "night-dream-repair:" + UUID().uuidString, kind: .run, operation: "dream", owner: "attention > night",
            words: "The night's dream remains owed: " + detail, nextCall: ToolFailureError.call("app", ["action": .string("mind.dream")])).value
    }

    private static func nightREM(dataRoot root: URL) async {
        do {
            _ = try await clockWork(dataRoot: root).surfaceREMResult(try await runRem(dataRoot: root, force: false))
            await RepairOwed.settle(root, operation: "rem", evidence: .init(source: "attention", id: "night")).value
        } catch DreamREMCycleError.cycleDisabled(_, _) {
            // REM turned off is a setting, not a failed night.
            return
        } catch is CancellationError {
            return
        } catch {
            await RepairOwed.owe(root, id: "night-rem-repair:" + UUID().uuidString, kind: .run, operation: "rem", owner: "attention > night",
                words: "The night's REM pass did not complete: " + error.localizedDescription,
                nextCall: ToolFailureError.call("app", ["action": .string("mind.rem")])).value
        }
    }

    // MARK: - Watches and scans

    private static func watch(_ time: OneClock.Time, dataRoot root: URL) async {
        let payload = time.payload?.objectValue ?? [:]
        let name = payload["name"]?.stringValue ?? time.id
        let operation = "clock:" + time.id
        do {
            guard let action = payload["actionId"]?.stringValue else {
                throw PersistenceCoreError.ioFailure("The watch \(time.id) names no action to read.")
            }
            let output = try await read(action: action, input: payload["input"]?.objectValue ?? [:])
            let seen = payload["seen"]?.arrayValue?.compactMap(\.stringValue)
            let read = try await ClockWork.watch(id: time.id, name: name, actionId: action, seen: seen, output: output)
            try await ScheduledReads.remember(seen: read.seen, read: time, dataRoot: root)
            await RepairOwed.settle(root, operation: operation, evidence: .init(source: "clock", id: time.id)).value
        } catch {
            // A stop is owed here too: a one-shot read interrupted at shutdown has no other record of being missed.
            await RepairOwed.owe(root, id: "watch-read:" + time.id + ":" + UUID().uuidString, kind: .run, operation: operation,
                owner: "clock/times.json > " + time.id, words: "The watch \(name) did not read: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")])).value
        }
    }

    private static func scan(_ time: OneClock.Time, dataRoot root: URL) async {
        let operation = "clock:" + time.id
        do {
            var payload = try ScheduledReads.checkedPayload(time)
            let seen = payload.removeValue(forKey: "seen")?.arrayValue?.compactMap(\.stringValue) ?? []
            payload["name"] = nil
            payload["made"] = nil
            let posted = try await clockWork(dataRoot: root).scan(id: time.id, payload: payload, seen: seen)
            try await ScheduledReads.remember(seen: posted, read: time, dataRoot: root)
            await RepairOwed.settle(root, operation: operation, evidence: .init(source: "clock", id: time.id)).value
        } catch {
            // A stop is owed here too: a one-shot read interrupted at shutdown has no other record of being missed.
            await RepairOwed.owe(root, id: "scan:" + time.id + ":" + UUID().uuidString, kind: .run, operation: operation,
                owner: "clock/times.json > " + time.id, words: "The proactive scan \(time.id) did not complete: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")])).value
        }
    }

    /// A watch's read: its action through the app door, as any of the agent's calls, held to a read. Throws what refused or failed it.
    private static func read(action: String, input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeAgentEngine.live.withPartDoor(envelope: .native("scheduler:watch:" + action), traced: true) { door in
            if let refusal = SchedulerJobNormalizer.watchRefusal(action: action, input: input, turn: door.turn) {
                throw PartCallError(code: "not_a_read", message: refusal)
            }
            let result = try await door.perform("app", ["action": .string(action), "args": .object(input)])
            let reply = ToolResult(result)
            let exactStatus = reply.payload.objectValue?["status"]?.stringValue?.lowercased() == reply.status
            let skipped = exactStatus && (reply.said("skipped") || reply.said("needs_input"))
            guard !reply.outcome.isFailure && !(reply.outcome == .unknown && skipped) else {
                throw PartCallError(code: "read_failed", message: "\(action) did not read: "
                    + ChatToolOutcome.displaySummary(result: reply.payload)
                    + (ChatToolOutcome.remedy(reply.payload).map { " " + $0 } ?? ""))
            }
            return reply.payload
        }
    }

    // MARK: - Part schedules

    /// Each `schedule:<cron>` wake in a part header is the time `part:<id>:<cron>`; a time whose part no longer wakes on it is withdrawn. Unreadable parts
    /// leave the part times as they are.
    private static func declarePartTimes(dataRoot root: URL) async {
        let clock = OneClock.at(root)
        do {
            let files = try AbilityStore(dataRoot: root).files(includeProposals: false)
            let declared = try await clock.times(owner: "part")
            var wanted: Set<String> = []
            for file in files {
                for signal in file.wakes where signal.hasPrefix("schedule:") {
                    let id = "part:\(file.id):\(signal.dropFirst("schedule:".count))"
                    guard let rhythm = SchedulerJobNormalizer.rhythm(.object(["type": .string("cron"),
                                                                              "expression": .string(String(signal.dropFirst("schedule:".count)))])),
                          let next = SchedulerJobNormalizer.nextOccurrence(rhythm, after: Date()) else {
                        ModuleLog.app("[clock] %@ wakes on %@, which is not a five-field cron; it is not on the clock", file.id, signal)
                        continue
                    }
                    wanted.insert(id)
                    if declared.contains(where: { $0.id == id }) { continue }
                    try await clock.declare(.init(id: id, rhythm: rhythm, next: next,
                                                  payload: .object(["part": .string(file.id), "signal": .string(signal)])))
                }
            }
            for time in declared where !wanted.contains(time.id) { try await clock.withdraw(time.id) }
        } catch {
            ModuleLog.app("[clock] part schedules were left as they are: %@", error.localizedDescription)
        }
    }

}
