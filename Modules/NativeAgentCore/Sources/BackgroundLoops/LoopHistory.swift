import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LoopHistory.swift` | SwiftNativeLoopScheduler durable run/completion history, first-seen stamps, organ pulses and ordered checkpoints |

extension SwiftNativeLoopScheduler {

    /// Register and start join one retained history read before scheduling against its stamps.
    internal func loadPersistedStateIfNeeded() async {
        if persistedStateLoaded { return }
        let load: Task<PersistedLoopState, Never>
        if let inFlight = persistedStateLoad {
            load = inFlight
        } else {
            let path = loopStatePath
            load = Task { await Self.readLoopState(path) }
            persistedStateLoad = load
        }
        let loaded = await load.value
        guard !persistedStateLoaded else { return }
        persistedStateLoaded = true
        persistedStateLoad = nil
        // Never clobber a stamp recorded while the read was in flight — that
        // one is newer than anything on disk.
        for (id, date) in loaded.runs where persistedLastRun[id] == nil {
            persistedLastRun[id] = date
        }
        for (id, date) in loaded.completions where persistedLastCompleted[id] == nil {
            persistedLastCompleted[id] = date
        }
        // First-seen is the OLDEST stamp, not the newest: a register that ran
        // while the read was in flight recorded "now", and disk holds the truth.
        for (id, date) in loaded.firstSeen {
            persistedFirstSeen[id] = [persistedFirstSeen[id], date].compactMap { $0 }.min()
        }
        for (organ, pulse) in loaded.pulses where persistedPulses[organ] == nil {
            persistedPulses[organ] = pulse
        }
        if let fault = loaded.fault {
            persistedStateFault = fault
            await appendFailureReceipt(loopId: Self.loopStateReceiptId,
                error: fault + "; every loop's timing restarted from this launch")
        }
    }


    /// A missing file yields no persisted history. A damaged one (readJSON
    /// keeps corrupt bytes beside it) or damaged entries yield what survived
    /// plus the fault, so startup never blocks and the damage is never silent.
    package static func readLoopState(
        _ path: URL?
    ) async -> PersistedLoopState {
        guard let path else { return ([:], [:], [:], [:], nil) }
        let value: JSONValue
        do {
            value = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
        } catch {
            nativeLog("BackgroundLoops: loop state unreadable, starting with no run history: %@", "\(error)")
            return ([:], [:], [:], [:], "Loop run history unreadable: \(error.localizedDescription)")
        }
        return decodeLoopState(value)
    }

    package static func decodeLoopState(_ value: JSONValue) -> PersistedLoopState {
        guard case .object(let root) = value else {
            return ([:], [:], [:], [:], "Loop run history is not a JSON object")
        }
        var damaged: [String] = []
        func stamps(_ key: String) -> [String: Date] {
            guard let section = root[key] else { return [:] }
            guard case .object(let rows) = section else { damaged.append(key); return [:] }
            var result: [String: Date] = [:]
            for (id, raw) in rows {
                guard case .string(let stamp) = raw, let date = NativeTimestampFormat.parsePlainISO8601(stamp) else {
                    damaged.append("\(key).\(id)")
                    continue
                }
                result[id] = date
            }
            return result
        }
        var pulses: [String: OrganPulse] = [:]
        if case .object(let rows)? = root["pulses"] {
            for (organ, raw) in rows {
                guard case .object(let row) = raw,
                      case .string(let stamp)? = row["at"], let at = NativeTimestampFormat.parsePlainISO8601(stamp),
                      case .string(let word)? = row["outcome"], let outcome = OrganPulse.Outcome(rawValue: word)
                else { damaged.append("pulses.\(organ)"); continue }
                let note: String = if case .string(let text)? = row["note"] { text } else { "" }
                let cadence: TimeInterval? = switch row["cadenceSeconds"] {
                case .int(let seconds)?: TimeInterval(seconds)
                case .double(let seconds)?: seconds
                default: nil
                }
                pulses[organ] = OrganPulse(organ: organ, at: at, outcome: outcome, note: note, cadence: cadence)
            }
        }
        let runs = stamps("loops"), completions = stamps("completions"), firstSeen = stamps("firstSeen")
        return (runs, completions, firstSeen, pulses,
                damaged.isEmpty ? nil : "Loop run history has unreadable entries: " + damaged.sorted().joined(separator: ", "))
    }

    /// Serializes the whole (small — one entry per loop id ever registered)
    /// map. Entries deliberately OUTLIVE `unregister`: a hot-reload via
    /// `restartLoop` must not reset a weekly loop's due clock back to zero.
    internal func flushLoopState() async {
        guard let loopStatePath else { return }
        lastDurableFlushAt = clock()
        let pulses = persistedPulses.mapValues { pulse -> JSONValue in
            var row: [String: JSONValue] = [
                "at": .string(NativeTimestampFormat.plainZulu(pulse.at)),
                "outcome": .string(pulse.outcome.rawValue),
                "note": .string(pulse.note),
            ]
            row["cadenceSeconds"] = pulse.cadence.map { .double($0) }
            return .object(row)
        }
        let snapshot = JSONValue.object([
            "version": .string("1"),
            "loops": .object(persistedLastRun.mapValues { .string(NativeTimestampFormat.plainZulu($0)) }),
            "completions": .object(persistedLastCompleted.mapValues { .string(NativeTimestampFormat.plainZulu($0)) }),
            "firstSeen": .object(persistedFirstSeen.mapValues { .string(NativeTimestampFormat.plainZulu($0)) }),
            "pulses": .object(pulses),
        ])
        let previous = persistedStateWrite
        let write = Task {
            await previous?.value
            do {
                try await SwiftNativePersistenceCore.writeJSON(snapshot, to: loopStatePath)
                consecutiveFailures[Self.loopStateReceiptId] = 0
            } catch {
                lastDurableFlushAt = nil
                FileHandle.standardError.write(Data(
                    "BackgroundLoops: failed to persist loop run state: \(error)\n".utf8
                ))
                // The attempt outlives this process as a receipt; repeats coalesce.
                await appendFailureReceipt(loopId: Self.loopStateReceiptId,
                    error: "Loop run history could not be saved: \(error.localizedDescription)")
                consecutiveFailures[Self.loopStateReceiptId, default: 0] += 1
            }
        }
        persistedStateWrite = write
        await write.value
    }

    /// Keep sub-minute liveness current in memory and checkpoint it on an
    /// existing tick. Long-period and unclassified work stays immediately
    /// durable; stop flushes the final live stamps without another wakeup.
    internal func recordDurableRun(loopId: String, at date: Date) async {
        persistedLastRun[loopId] = date
        await flushLoopState(cadence: loops[loopId]?.loop.interval, at: clock())
    }

    private func flushLoopState(cadence: TimeInterval?, at date: Date) async {
        if let cadence, cadence < durableFlushImmediateInterval,
           let lastDurableFlushAt,
           date.timeIntervalSince(lastDurableFlushAt) < durableFlushImmediateInterval {
            return
        }
        await flushLoopState()
    }

    /// An organ's pulse rides the same checkpoint rule as a loop's run stamp.
    func recordPulse(_ pulse: OrganPulse) async {
        await loadPersistedStateIfNeeded()
        if let held = persistedPulses[pulse.organ], held.at > pulse.at { return }
        persistedPulses[pulse.organ] = pulse
        await flushLoopState(cadence: pulse.cadence, at: pulse.at)
    }

    func organPulses() async -> [OrganPulse] {
        await loadPersistedStateIfNeeded()
        return Array(persistedPulses.values)
    }


}
