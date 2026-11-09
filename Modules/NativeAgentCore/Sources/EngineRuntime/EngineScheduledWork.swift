import Foundation
import NativeAgentCore
import NativeAgentShared
import AgentConversations
import AppToolRuntime
import AttentionRouting
import Agents
import AuthoredCapabilities
import BackgroundLoops
import BackgroundWork
import ChatToolParsing
import ChatToolRuntime
import ChatTurnRuntime
import Cognition
import Desk
import DoctorChecks
import DreamREMCycle
import Experiences
import MemoryV2
import PersistenceCore
import SchedulerExecution
import StandingBots
import TelegramBot
import ToolExecution
import TriggerScheduler
// Blueprint: | `EngineScheduledWork.swift` | Attention's night and the clock's part schedules, watches, scans, inbox briefs and helpers |

extension NativeAgentEngine {
    public static func makeNativeTriggerScheduler(dataRoot: URL) -> SwiftNativeTriggerScheduler {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let notifier: TriggerNotifier? = isLiveRoot
            ? NativeAgentEngine.live.ports.backgroundWork.triggerNotifier
            : nil
        return SwiftNativeTriggerScheduler(
            root: standardized,
            notifier: notifier,
            morningBriefPart: { input in
                if !isLiveRoot, input.objectValue?["operation"] == .string("brief") {
                    throw TriggerSchedulerError.persistenceFailure("A secondary root cannot spend the live morning-brief model route.")
                }
                let engine = NativeAgentEngine.forRoot(standardized)
                // The clock is not a requester: her own scheduled work runs at her own standing (Trust decides), like her own thoughts.
                return try await engine.tools.withPartDoor(envelope: .native("trigger:morning_brief"), fileAccess: "auto") { door in
                    switch await Parts(root: standardized).call(id: "native-morning-brief", input: input, invocation: door.invocation, as: JSONValue.self) {
                    case .success(let value): return value
                    case .failure(let error): throw error
                    }
                }
            }
        )
    }

    /// What the clock's dream, REM, watch and scan deliveries leave behind, told through this root's attention router.
    public static func clockWork(dataRoot: URL) -> ClockWork {
        ClockWork(root: dataRoot, attentionRouter: { NativeAgentEngine.forRoot(dataRoot).ports.backgroundWork.attention })
    }

    /// Asked times belong to their declaring owners. The night belongs to attention.
    static func registerClockOwners(dataRoot: URL) async {
        let root = dataRoot.standardizedFileURL
        let clock = OneClock.at(root)
        do {
            try await clock.withdraw("sleep:night")
            try await clock.withdraw("rem:weekly")
            try await clock.withdraw("wander:hour")
        } catch {
            await DoctorReadout.recordReadings([CheckResult(source: "clock/times.json", id: "night.withdraw", title: "Night times",
                status: "fail", detail: error.localizedDescription)], dataRoot: root)
        }
        _ = await NativeAgentEngine.live.bots.attach(carryingOver: false)
        await clock.handle("part") { time, _ in
            guard let part = time.payload?.objectValue?["part"]?.stringValue, let signal = time.payload?.objectValue?["signal"]?.stringValue else {
                ModuleLog.app("[clock] %@ carries no part and signal; nothing was posted", time.id)
                return
            }
            // The clock only posts the signal; the run is the part's, on its own gate chain, and recorded on the ability.
            AbilityStore(dataRoot: root).signal(signal, part: part)
        }
        await clock.handle("watch") { time, _ in await watch(time, dataRoot: root) }
        await clock.handle("scan") { time, _ in await scan(time, dataRoot: root) }
        await clock.handle(SwiftNativeTriggerScheduler.clockOwner) { time, occurrence in
            guard let name = time.payload?.objectValue?["name"]?.stringValue else {
                ModuleLog.app("[clock] %@ carries no trigger name; nothing was published", time.id)
                return
            }
            await makeNativeTriggerScheduler(dataRoot: root).deliver(name: name, occurrence: occurrence)
        }
        await declarePartTimes(dataRoot: root)
        Task.detached(priority: .utility) {
            // A part header's schedule:<cron> is a part time; editing the part moves it, removing the wake withdraws it.
            for await _ in NotificationCenter.default.notifications(named: AbilityStore.didChange) { await declarePartTimes(dataRoot: root) }
        }
        do { try await makeNativeTriggerScheduler(dataRoot: root).declareTimes() }
        catch {
            await DoctorReadout.recordReadings([CheckResult(source: "triggers/trigger_config.json", id: "clock.briefs", title: "Inbox brief times",
                status: "fail", detail: "Inbox trigger times are not on the clock: \(error.localizedDescription)")], dataRoot: root)
        }
    }

    // MARK: - The night and REM

    /// The night, through attention or an explicit sleep request: the sleep thought runs the dream, then the night's reading of the agent's parts,
    /// and a thought of the agent's when the reading holds something. Returns its admission outcome; the stream holds the running night.
    public static func sleep(dataRoot: URL, attended: Attended? = nil, parent: Turn? = nil) async -> MindStream.NightOutcome {
        let root = dataRoot.standardizedFileURL
        return await live.agents.stream.night(attended: attended, request: parent, dream: { parent, beganAt in
            await dreamTheNight(dataRoot: root, parent: parent, beganAt: beganAt)
            await nightREM(dataRoot: root)
        }, reading: { await EngineSleep.night(dataRoot: root) })
    }

    /// Today and Desk read the night sense independently of the dream's switch; neither can hide the other's facts or failure.
    func nextNightReading() async -> [String: JSONValue] {
        var reading: [String: JSONValue]
        do {
            let sense = try await Self.cognitionRuntime(for: dataRoot).nextNight()
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
            let response = try await runDream(dataRoot: root, force: false, parent: parent, beganAt: beganAt)
            guard response["remedy"] == nil, (response["skipReason"] as? String) == "already_running" else { return }
            detail = "another dream run held the reservation while the night began"
        } catch DreamREMCycleError.cycleDisabled(_, _) {
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
            try await ScheduledReads.remember(seen: read.seen, watch: time.id, dataRoot: root)
            await RepairOwed.settle(root, operation: operation, evidence: .init(source: "clock", id: time.id)).value
        } catch {
            await RepairOwed.owe(root, id: "watch-read:" + time.id + ":" + UUID().uuidString, kind: .run, operation: operation,
                owner: "clock/times.json > " + time.id, words: "The watch \(name) did not read: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")])).value
        }
    }

    private static func scan(_ time: OneClock.Time, dataRoot root: URL) async {
        var payload = time.payload?.objectValue ?? [:]
        payload["name"] = nil
        let operation = "clock:" + time.id
        do {
            _ = try await clockWork(dataRoot: root).scan(payload: payload)
            await RepairOwed.settle(root, operation: operation, evidence: .init(source: "clock", id: time.id)).value
        } catch {
            await RepairOwed.owe(root, id: "scan:" + time.id + ":" + UUID().uuidString, kind: .run, operation: operation,
                owner: "clock/times.json > " + time.id, words: "The proactive scan \(time.id) did not complete: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")])).value
        }
    }

    /// A watch's read: its action through the app door, as any of the agent's calls, held to a read. Throws what refused or failed it.
    private static func read(action: String, input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeAgentEngine.live.tools.withPartDoor(envelope: .native("scheduler:watch:" + action)) { door in
            if let refusal = SwiftNativeTriggerScheduler.watchRefusal(action: action, input: input, turn: door.turn) {
                throw PartCallError(code: "not_a_read", message: refusal)
            }
            let result = try await door.perform("app", ["action": .string(action), "args": .object(input)])
            let reply = ToolResult(result)
            let exactStatus = reply.payload.objectValue?["status"]?.stringValue?.lowercased() == reply.status
            let skipped = exactStatus && (reply.said("skipped") || reply.said("needs_input"))
            guard !reply.outcome.isFailure && !(reply.outcome == .unknown && skipped) else {
                throw PartCallError(code: "read_failed", message: "\(action) did not read: "
                    + ChatToolOutcome.displaySummary(outcome: .failed, input: nil, result: reply.payload)
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
