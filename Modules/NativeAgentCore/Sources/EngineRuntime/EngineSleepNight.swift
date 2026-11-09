import Foundation
import AuthoredCapabilities
import BackgroundWork
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `EngineSleepNight.swift` | `EngineSleep`: night cursor, decided-trial settlement and durable surprise-window accounting |

extension EngineSleep {
    /// Settles decided trials and the prepared surprise window, preserving each failed operation and its cause.
    public static func night(dataRoot: URL, now: Date = Date()) async -> JSONValue {
        let cursor: NightCursor
        do { cursor = try await Self.nightCursor(dataRoot: dataRoot, now: now) }
        catch let failure as NightCursorFailure {
            await Self.oweNight(dataRoot, operation: "night.cursor." + failure.source, source: failure.source, cause: failure.cause)
            return Self.night(Findings(revision: Self.revision, gaps: [Self.gap(failure.source, reason: failure.cause)]),
                since: now, through: now, closed: [], folded: [:], attend: false)
        } catch {
            await Self.oweNight(dataRoot, operation: "night.cursor", source: "night_cursor", cause: error.localizedDescription)
            return Self.night(Findings(revision: Self.revision, gaps: [Self.gap("night_cursor", reason: error.localizedDescription)]),
                since: now, through: now, closed: [], folded: [:], attend: false)
        }
        let since = cursor.since, through = cursor.through
        let store = AbilityStore(dataRoot: dataRoot)
        var pending = cursor.pending
        var gaps: [JSONValue] = []
        guard since < through else {
            // The clock moved back past the latest night row: nothing is read and no row is written, so the next night starts where that row ended.
            gaps.append(Self.gap("window", reason: "The clock is at or before the completed night cursor; no window is read or committed."))
            return Self.night(Findings(revision: Self.revision, gaps: gaps), since: since, through: through, closed: [], folded: [:],
                              attend: false)
        }
        let window = await SurpriseReading.read(dataRoot: dataRoot, since: since, through: through)
        var found = await Self.findings(dataRoot: dataRoot, since: since, through: through, window: window)
        found.gaps = gaps + found.gaps

        let closed = Self.closeTrials(store, found: &found)

        // A window whose traces or corrections could not be read is read again next night: the row's `through` stays at its `since`.
        let unreadWindow = Self.unread(window)
        // Surprise folds after the verdicts were read and closed: tonight's folded surprise is judged by the next night's reading.
        // Each surprise goes to the first of the part's current and previous versions first seen by its time; neither is unattributed, never guessed.
        var planned = pending?.folds ?? []
        var unattributed = pending?.unattributed ?? [:]
        var foldReady = pending != nil || !unreadWindow
        if pending == nil, foldReady {
            do {
                try AbilityStore.withLock { () throws -> Void in
                    let catalog = try store.catalog()
                    var counts: [String: [String: [String: Int]]] = [:]
                    for surprise in window.surprises {
                        guard case .ability(let part) = surprise.owner else { continue }
                        let versions = catalog.states[part]?.objectValue?["runs"]?.objectValue?["versions"]?.objectValue ?? [:]
                        let files = [catalog.retained[.current]?[part], catalog.retained[.previous]?[part]].compactMap { $0 }
                        let seenBy = files.first { file in
                            guard let seen = versions[store.versionKey(file)]?.objectValue?["first_seen"]?.stringValue
                                .flatMap(NativeTimestampFormat.parseISO8601) else { return false }
                            return seen <= surprise.at
                        }
                        guard let ran = seenBy else { unattributed[part] = try Self.countSum(unattributed[part] ?? 0, 1); continue }
                        let version = store.versionKey(ran)
                        let count = counts[part]?[version]?[surprise.kind] ?? 0
                        counts[part, default: [:]][version, default: [:]][surprise.kind] = try Self.countSum(count, 1)
                    }
                    for part in counts.keys.sorted() {
                        for (version, kinds) in (counts[part] ?? [:]).sorted(by: { $0.key < $1.key }) {
                            planned.append(.init(part: part, version: version, counts: kinds))
                        }
                    }
                    if !planned.isEmpty {
                        let prepared = AbilityStore.SurpriseWindow(since: since, through: through, folds: planned, unattributed: unattributed)
                        try store.prepareSurpriseWindow(prepared)
                        pending = prepared
                    }
                }
            } catch {
                planned = []; unattributed = [:]
                foldReady = false
                found.gaps.append(Self.gap("surprise_fold", reason: error.localizedDescription))
            }
        }
        let attend = found.revision && (!found.candidates.isEmpty
            || found.trials.contains { $0.objectValue?["verdict"]?.stringValue == "set_aside" })

        // Exact inputs are durable before accounting. Each version commits its whole batch and watermark together; other parts proceed if one fails.
        var folded: [String: [String: Int]] = [:]
        var failed = Set<String>()
        for fold in planned {
            do {
                try store.recordSurprises(id: fold.part, version: fold.version, counts: fold.counts, since: since, through: through, turn: nil)
                for (kind, count) in fold.counts {
                    folded[fold.part, default: [:]][kind] = try Self.countSum(folded[fold.part]?[kind] ?? 0, count)
                }
            } catch {
                failed.insert(fold.part)
                found.gaps.append(Self.gap("surprise_fold", reason: error.localizedDescription, part: fold.part))
            }
        }
        for (part, count) in unattributed { folded[part, default: [:]]["unattributed"] = count }
        let settled = foldReady && failed.isEmpty
        let row: JSONValue = .object([
            "since": .string(NativeTimestampFormat.plainZulu(since)),
            "through": .string(NativeTimestampFormat.plainZulu(settled ? through : since)),
            "parts_since": .string(NativeTimestampFormat.plainZulu(Self.completedHour(since))),
            "parts_through": .string(NativeTimestampFormat.plainZulu(Self.completedHour(settled ? through : since))),
            "attend": .bool(attend), "silent": .bool(Self.silent(found)), "closed": .array(closed), "folded": Self.folded(folded),
            "candidates": .int(Int64(found.candidates.count)), "gaps": .int(Int64(found.gaps.count)), "gap_details": .array(found.gaps),
        ])
        do {
            let data = try row.serializedData(pretty: false)
            try await ExperienceStore.at(dataRoot).note([.init(source: Attention.detailSource, at: Date(), subject: "sleep", kind: Attention.nightKind,
                row: data)], durable: true)
            await RepairOwed.settle(dataRoot, operation: "night.write_record", evidence: .init(source: "attention.night", id: "written")).value
        } catch {
            await Self.oweNight(dataRoot, operation: "night.write_record", source: "night_record", cause: error.localizedDescription)
            found.gaps.append(Self.gap("night_record", reason: error.localizedDescription))
            return Self.night(found, since: since, through: through, closed: closed, folded: folded, attend: attend)
        }
        if settled, let pending {
            do {
                try store.finishSurpriseWindow(pending)
                await RepairOwed.settle(dataRoot, operation: "night.finish_window",
                    evidence: .init(source: "abilities/.night-fold.json", id: "removed")).value
            } catch {
                await Self.oweNight(dataRoot, operation: "night.finish_window", source: "surprise_window", cause: error.localizedDescription)
                found.gaps.append(Self.gap("surprise_window", reason: error.localizedDescription))
            }
        }
        return Self.night(found, since: since, through: through, closed: closed, folded: folded, attend: attend)
    }

    static func closeTrials(_ store: AbilityStore, found: inout Findings) -> [JSONValue] {
        // The record decided these trials: kept closes as the stem's verdict; superseded closes once the files hold its version in neither slot.
        // set_aside, open, waiting and unread stay open: setting aside is the agent's forward revision, or the person's lever.
        var closed: [JSONValue] = []
        for case .object(let entry) in found.trials {
            guard let part = entry["part"]?.stringValue, let version = entry["version"]?.stringValue else { continue }
            let change: AbilityStore.TrialChange
            switch entry["verdict"]?.stringValue {
            case "kept": change = .judged(verdict: "kept")
            case "superseded": change = .reconcile(by: "stem")
            default: continue
            }
            do {
                // Under the store lock, the trial closed is the one this reading judged: a trial opened since is not this reading's to close.
                let written = try AbilityStore.withLock { () throws -> JSONValue? in
                    guard try store.states()[part]?.objectValue?["trial"]?.objectValue?["version"]?.stringValue == version else { return nil }
                    return try store.changeTrial(id: part, change, turn: nil)
                }
                if let verdict = written?.objectValue?["verdict"]?.stringValue {
                    closed.append(.object(["part": .string(part), "verdict": .string(verdict)]))
                }
            } catch { found.gaps.append(Self.gap("trial_close", reason: error.localizedDescription, part: part)) }
        }

        // The frozen baseline survives trace retention.
        for baseline in found.baselines {
            do {
                try store.changeTrial(id: baseline.part,
                    .baseline(version: baseline.version, kept: Self.tally(baseline.kept, counting: Self.turnCountUnit,
                        evidence: Self.turnBaselineEvidence)), turn: nil)
            }
            catch { found.gaps.append(Self.gap("trial_baseline", reason: error.localizedDescription, part: baseline.part)) }
        }

        return closed
    }

    struct NightCursor {
        var since: Date
        var through: Date
        var pending: AbilityStore.SurpriseWindow?
    }

    struct NightCursorFailure: LocalizedError {
        let source: String
        let cause: String
        var errorDescription: String? { source + ": " + cause }
    }

    /// The last committed row and any prepared fold inputs define the next window.
    static func nightCursor(dataRoot: URL, now: Date) async throws -> NightCursor {
        var through = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var since = through.addingTimeInterval(-86_400)
        var completed: Date?
        do {
            let rows = try await ExperienceStore.at(dataRoot).details(.init(sources: [Attention.detailSource], subjects: ["sleep"],
                kinds: [Attention.nightKind], limit: 1, newestFirst: true))
            if let latest = rows.first {
                guard let last = try JSONValue.parse(latest.row).objectValue?["through"]?.stringValue
                    .flatMap(NativeTimestampFormat.parseISO8601) else {
                    throw ToolFailureError("The latest night row has no readable through cursor.", effects: .none)
                }
                since = last
                completed = last
            }
        } catch {
            throw NightCursorFailure(source: "night_record", cause: error.localizedDescription)
        }
        await RepairOwed.settle(dataRoot, operation: "night.cursor.night_record",
            evidence: .init(source: "attention.night", id: "read")).value
        let store = AbilityStore(dataRoot: dataRoot)
        var pending: AbilityStore.SurpriseWindow?
        do {
            if let saved = try store.pendingSurpriseWindow() {
                if let completed, saved.through <= completed {
                    try store.finishSurpriseWindow(saved)
                    await RepairOwed.settle(dataRoot, operation: "night.finish_window",
                        evidence: .init(source: "abilities/.night-fold.json", id: "removed")).value
                } else {
                    guard completed == nil || completed == saved.since else {
                        throw ToolFailureError("The prepared surprise window does not meet the completed night cursor.", effects: .none)
                    }
                    pending = saved
                    since = saved.since
                    through = saved.through
                }
            }
        } catch {
            throw NightCursorFailure(source: "surprise_window", cause: error.localizedDescription)
        }
        await RepairOwed.settle(dataRoot, operation: "night.cursor.surprise_window",
            evidence: .init(source: "abilities/.night-fold.json", id: "read")).value
        return NightCursor(since: since, through: through, pending: pending)
    }

    static func oweNight(_ root: URL, operation: String, source: String, cause: String) async {
        await RepairOwed.owe(root, id: UUID().uuidString.lowercased(), kind: .run, operation: operation, owner: source,
            words: "The night's " + source + " could not settle: " + cause,
            lever: "Repair the named night's storage or evidence; the next night reads its saved cursor and prepared inputs.").value
    }
}
