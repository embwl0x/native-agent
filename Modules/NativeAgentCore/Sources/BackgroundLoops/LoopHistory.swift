import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `LoopHistory.swift` | SwiftNativeLoopScheduler durable run/completion history, first-seen stamps, organ pulses and ordered checkpoints |

extension SwiftNativeLoopScheduler {

    /// Join the retained history read before registration or start schedules against its stamps.
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
        // Never overwrite a live stamp recorded during the suspended read with older disk state.
        for (id, date) in loaded.runs where persistedLastRun[id] == nil {
            persistedLastRun[id] = date
        }
        for (id, date) in loaded.completions where persistedLastCompleted[id] == nil {
            persistedLastCompleted[id] = date
        }
        // Keep the oldest firstSeen; a concurrent registration’s now cannot replace an earlier durable origin.
        for (id, date) in loaded.firstSeen {
            persistedFirstSeen[id] = [persistedFirstSeen[id], date].compactMap { $0 }.min()
        }
        if let fault = loaded.fault {
            persistedStateFault = fault
            await appendFailureReceipt(loopId: Self.loopStateReceiptId,
                error: fault + "; every loop's timing restarted from this launch")
        }
    }


    /// Retain surviving history and an explicit fault on damaged entries so startup proceeds without hiding corruption.
    package static func readLoopState(
        _ path: URL?
    ) async -> PersistedLoopState {
        guard let path else { return ([:], [:], [:], nil) }
        let value: JSONValue
        do {
            value = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
        } catch {
            nativeLog("BackgroundLoops: loop state unreadable, starting with no run history: %@", "\(error)")
            return ([:], [:], [:], "Loop run history unreadable: \(error.localizedDescription)")
        }
        return decodeLoopState(value)
    }

    package static func decodeLoopState(_ value: JSONValue) -> PersistedLoopState {
        guard case .object(let root) = value else {
            return ([:], [:], [:], "Loop run history is not a JSON object")
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
        let runs = stamps("loops"), completions = stamps("completions"), firstSeen = stamps("firstSeen")
        return (runs, completions, firstSeen,
                damaged.isEmpty ? nil : "Loop run history has unreadable entries: " + damaged.sorted().joined(separator: ", "))
    }

    private static func decodeBeat(_ detail: ExperienceStore.Detail) throws -> OrganPulse {
        guard detail.subject.hasPrefix("organ:"), detail.subject.count > "organ:".count,
              case .object(let row) = try JSONValue.parse(detail.row),
              case .string(let word)? = row["outcome"], let outcome = OrganPulse.Outcome(rawValue: word),
              case .string(let note)? = row["note"]
        else { throw PersistenceCoreError.ioFailure("Organ beat detail \(detail.seq) is unreadable") }
        // Yield and cadence are absent when the beat had none; present and unreadable is a damaged beat.
        let counted = row["yield"], clocked = row["cadence"]
        let count = counted?.exactIntegerValue, seconds = clocked?.numberValue(coercingStrings: false, finiteOnly: true)
        guard counted == nil || count != nil, clocked == nil || seconds != nil else {
            throw PersistenceCoreError.ioFailure("Organ beat detail \(detail.seq) has unreadable yield or cadence")
        }
        return OrganPulse(organ: String(detail.subject.dropFirst("organ:".count)), at: detail.at,
                          outcome: outcome, note: note, yield: count, cadence: seconds)
    }

    /// Keep history after unregister so hot replacement cannot reset a long-period loop’s due clock.
    internal func flushLoopState() async {
        guard let loopStatePath else { return }
        lastDurableFlushAt = clock()
        let snapshot = JSONValue.object([
            "version": .string("1"),
            "loops": .object(persistedLastRun.mapValues { .string(NativeTimestampFormat.plainZulu($0)) }),
            "completions": .object(persistedLastCompleted.mapValues { .string(NativeTimestampFormat.plainZulu($0)) }),
            "firstSeen": .object(persistedFirstSeen.mapValues { .string(NativeTimestampFormat.plainZulu($0)) }),
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

    /// Checkpoint sub-minute liveness on existing ticks; persist slow work immediately and flush stop without an extra wakeup.
    internal func recordDurableRun(loopId: String, at date: Date) async {
        persistedLastRun[loopId] = date
        await flushLoopState(cadence: loops[loopId]?.loop.wake.period, at: clock())
    }

    private func flushLoopState(cadence: TimeInterval?, at date: Date) async {
        if let cadence, cadence < durableFlushImmediateInterval,
           let lastDurableFlushAt,
           date.timeIntervalSince(lastDurableFlushAt) < durableFlushImmediateInterval {
            return
        }
        await flushLoopState()
    }

    /// Concurrent beats share a flush into the record; scheduling state is never rewritten for a beat.
    func recordPulse(_ pulse: OrganPulse) async {
        do {
            var row: [String: JSONValue] = ["outcome": .string(pulse.outcome.rawValue), "note": .string(pulse.note)]
            row["yield"] = pulse.yield.map { .int(Int64($0)) }
            row["cadence"] = pulse.cadence.map(JSONValue.double)
            pendingBeats.append(.init(source: "body", at: pulse.at, subject: "organ:" + pulse.organ, kind: "beat",
                                      row: try JSONValue.object(row).serializedData(pretty: false)))
            // The reading in memory takes the beat now; a turn reading the body never waits on the record.
            beatReading.rings[pulse.organ] = Self.ring(beatReading.rings[pulse.organ] ?? [], adding: pulse)
        } catch {
            nativeLog("BackgroundLoops: organ beat could not be encoded: %@", error.localizedDescription)
            return
        }
        if beatWrite == nil {
            beatWrite = Task {
                await Task.yield()
                while !pendingBeats.isEmpty {
                    let batch = pendingBeats
                    pendingBeats = []
                    do { try await ExperienceStore.at(dataRoot).note(batch) }
                    catch { nativeLog("BackgroundLoops: organ beats could not be recorded: %@", error.localizedDescription) }
                }
                beatWrite = nil
            }
        }
        await beatWrite?.value
    }

    /// Beats arrive on unordered tasks: each takes its place in time and the ring keeps the newest `OrganRecord.capacity`.
    private static func ring(_ ring: [OrganPulse], adding beat: OrganPulse) -> [OrganPulse] {
        var ring = ring
        ring.insert(beat, at: ring.lastIndex { $0.at <= beat.at }.map { $0 + 1 } ?? 0)
        return Array(ring.suffix(OrganRecord.capacity))
    }

    /// Every organ's record, and the organs whose beat evidence did not decode (organ id: why). A beat that does not decode belongs to its organ
    /// (the detail's subject); its siblings still read. A failed record read throws: the body is unreadable, never quiet.
    func organRecords() async throws -> (records: [OrganRecord], unreadable: [String: String]) {
        if !beatReading.loaded {
            // Once per launch: the beats earlier processes left in the record join the ones this process has already fed.
            let details = try await ExperienceStore.at(dataRoot).details(.init(sources: ["body"], kinds: ["beat"]))
            if !beatReading.loaded {
                for detail in details {
                    do {
                        let pulse = try Self.decodeBeat(detail)
                        let ring = beatReading.rings[pulse.organ] ?? []
                        // A beat this process fed and also wrote reads back as the same beat (time kept to the millisecond by the record).
                        guard !ring.contains(where: { $0.outcome == pulse.outcome && $0.note == pulse.note && $0.yield == pulse.yield
                            && abs($0.at.timeIntervalSince(pulse.at)) < 0.001 }) else { continue }
                        beatReading.rings[pulse.organ] = Self.ring(ring, adding: pulse)
                    } catch {
                        let organ = detail.subject.hasPrefix("organ:") ? String(detail.subject.dropFirst("organ:".count)) : detail.subject
                        beatReading.unreadable[organ] = (detail.at, error.localizedDescription)
                    }
                }
                beatReading.loaded = true
            }
        }
        let cutoff = clock().addingTimeInterval(-ExperienceStore.detailHorizon)
        beatReading.rings = beatReading.rings.mapValues { $0.filter { $0.at >= cutoff } }
        beatReading.unreadable = beatReading.unreadable.filter { $0.value.at >= cutoff }
        let reading = beatReading
        return (reading.rings.compactMap { OrganRecord(organ: $0.key, beats: $0.value) }, reading.unreadable.mapValues { $0.why })
    }


}
