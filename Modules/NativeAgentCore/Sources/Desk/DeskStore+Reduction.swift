import Foundation
import PersistenceCore
// Blueprint: | `DeskStore+Reduction.swift` | `SwiftNativeDeskStore`: `compact`, `aliasSeq`, `orderByAlias` |

extension SwiftNativeDeskStore {
    // MARK: - Compaction (pure fold — rebuild MUST equal in-memory fold)

    /// Apply ops in append order; orphan mutations cannot recreate archived items.
    /// Retain orphaned-parent items so malformed hierarchy never loses live work.
    public static func compact(_ ops: [DeskOp]) -> DeskState {
        compact(base: nil, ops)
    }

    /// Seed from the base and apply only its following tail so compacted work survives truncation.
    static func compact(base: DeskCompactionBase?, _ ops: [DeskOp]) -> DeskState {
        var byHandle: [String: DeskItem] = [:]
        var createOrder: [String] = []
        var archived: Set<String> = []
        var accounting = base?.state ?? DeskState(items: [], generatedTs: "")
        if let base {
            for item in base.state.items {
                byHandle[item.handle] = item
                createOrder.append(item.handle)
            }
        }

        for op in ops {
            switch op.body {
            case let .createItem(alias, kind, project, title, parent, summary, assignee, laneOf, origin, pursuit, findingKey):
                if byHandle[op.handle] == nil { createOrder.append(op.handle) }
                byHandle[op.handle] = DeskItem(
                    handle: op.handle, alias: alias, parent: parent, kind: kind,
                    status: .watch, project: project, title: title, summary: summary,
                    assignee: assignee, laneOf: laneOf,
                    cadence: Cadence(), notify: NotifyPolicy(),
                    openedAt: op.ts, updatedAt: op.ts,
                    origin: origin, pursuit: pursuit, workAttempts: op.workAttempts, findingKey: findingKey
                )
                for attempt in op.workAttempts where attempt.disposition != .unstarted {
                    accounting.chargeWorkSlot(handle: op.handle, day: attempt.day, id: attempt.attemptId)
                }
            case let .openPursuit(alias, project, title, summary, pursuit, notify):
                if byHandle[op.handle] == nil { createOrder.append(op.handle) }
                byHandle[op.handle] = DeskItem(
                    handle: op.handle, alias: alias, parent: nil, kind: .project,
                    status: .watch, project: project, title: title, summary: summary,
                    cadence: Cadence(), notify: notify,
                    openedAt: op.ts, updatedAt: op.ts,
                    origin: .agent, pursuit: pursuit, workAttempts: op.workAttempts
                )
                for attempt in op.workAttempts where attempt.disposition != .unstarted {
                    accounting.chargeWorkSlot(handle: op.handle, day: attempt.day, id: attempt.attemptId)
                }
            case let .setStatus(status, blockedReason, waitingOn, progress, assignee, laneOf):
                guard var item = byHandle[op.handle] else { continue }
                item.status = status
                item.blockedReason = blockedReason
                item.waitingOn = waitingOn
                if let progress { item.progress = progress }
                if let assignee { item.assignee = assignee }
                if let laneOf { item.laneOf = laneOf }
                // Terminal status needs closedAt for archival; reopening clears that eligibility.
                if status.isTerminal {
                    if item.closedAt == nil { item.closedAt = op.ts }
                } else {
                    item.closedAt = nil
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .updateTitle(title, summary, refs):
                guard var item = byHandle[op.handle] else { continue }
                if let title, !title.isEmpty { item.title = title }
                if let summary, !summary.isEmpty { item.summary = summary }
                if let refs { item.refs = refs }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .addRef(ref):
                guard var item = byHandle[op.handle] else { continue }
                Self.appendRefCapped(&item, ref)
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .appendNote(text, author, releaseCondition):
                guard var item = byHandle[op.handle] else { continue }
                let note = DeskNote(ts: op.ts, text: text, author: author, releaseCondition: releaseCondition)
                Self.appendNoteCapped(&item, note)
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .vetoPursuit(note):
                guard var item = byHandle[op.handle] else { continue }
                item.status = .canceled
                item.blockedReason = nil
                item.waitingOn = nil
                if item.closedAt == nil { item.closedAt = op.ts }
                if !item.notes.contains(where: { $0.text == note }) {
                    Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: note))
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setCadence(cadence):
                guard var item = byHandle[op.handle] else { continue }
                item.cadence = cadence
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setNotify(policy):
                guard var item = byHandle[op.handle] else { continue }
                let lastNotifiedAt = item.notify.lastNotifiedAt
                item.notify = policy
                item.notify.lastNotifiedAt = lastNotifiedAt
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .closeItem(outcomeSummary, status):
                guard var item = byHandle[op.handle] else { continue }
                item.status = status
                item.summary = outcomeSummary
                item.closedAt = op.ts
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .markNotified(at):
                // Notifications cannot bump content revision and trigger another notification.
                guard var item = byHandle[op.handle] else { continue }
                item.notify.lastNotifiedAt = at
                byHandle[op.handle] = item
            case .archiveItem:
                archived.insert(op.handle)
            case let .reserveWorkAttempt(attemptId, lane, day, slot):
                guard var item = byHandle[op.handle] else { continue }
                if lane == .pursuit, item.pursuit == nil { continue }
                if !accounting.hasWorkSlot(handle: op.handle, id: attemptId),
                   !item.workAttempts.contains(where: { $0.attemptId == attemptId }) {
                    item.workAttempts.append(DeskWorkAttempt(
                        attemptId: attemptId,
                        lane: lane,
                        day: day,
                        slot: slot,
                        reservedAt: op.ts
                    ))
                    accounting.chargeWorkSlot(handle: op.handle, day: day, id: attemptId)
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .completeWorkAttempt(attemptId, receipt, disposition, artifactRefs):
                guard var item = byHandle[op.handle],
                      let index = item.workAttempts.firstIndex(where: { $0.attemptId == attemptId }) else { continue }
                item.workAttempts[index].receipt = receipt
                item.workAttempts[index].completedAt = op.ts
                item.workAttempts[index].disposition = disposition
                item.workAttempts[index].artifactRefs = Array(artifactRefs.prefix(16))
                if disposition == .unstarted {
                    accounting.releaseWorkSlot(handle: op.handle, day: item.workAttempts[index].day, id: attemptId)
                }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                if var pursuit = item.pursuit, item.workAttempts[index].lane == .pursuit {
                    if disposition != .unstarted { pursuit.lastWorkedAt = op.ts }
                    item.pursuit = pursuit
                } else if disposition != .unstarted {
                    item.cadence.lastRefreshAt = op.ts
                    item.cadence.nextRefreshAt = Self.nextCadenceRefresh(after: op.ts, cadence: item.cadence)
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .handOffWorkReceipt(reservationId):
                guard var item = byHandle[op.handle] else { continue }
                if let index = item.workAttempts.firstIndex(where: { $0.attemptId == reservationId }),
                   item.workAttempts[index].completedAt != nil {
                    item.workAttempts[index].receiptHandedOff = true
                }
                byHandle[op.handle] = item
            case let .setBlockedOn(handles):
                // Replace dependency edges; readers derive unblocking without a second writer.
                guard var item = byHandle[op.handle] else { continue }
                item.blockedOn = handles
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setDeferUntil(until):
                guard var item = byHandle[op.handle] else { continue }
                item.deferUntil = (until?.isEmpty == true) ? nil : until
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .workLog(receipt):
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                p.lastWorkedAt = op.ts
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setContinuation(record):
                guard var item = byHandle[op.handle] else { continue }
                item.continuation = record
                byHandle[op.handle] = item
            }
        }

        // Revision and retention share the committed feed clock, never wall time.
        let revision = [ops.last?.ts, base?.state.generatedTs].compactMap { $0 }.max() ?? ""
        let currentDay = DeskClock.parseISO(revision).map(DeskClock.dayStamp)
        let live = createOrder.compactMap { byHandle[$0] }.filter { !archived.contains($0.handle) }.map { item in
            var retained = item
            let settled = item.workAttempts.filter { $0.completedAt != nil && $0.receiptHandedOff }
            var recent = Set(settled.filter { $0.lane == .ownerCadence }.suffix(4).map(\.attemptId))
            recent.formUnion(settled.filter { $0.lane == .pursuit }.suffix(4).map(\.attemptId))
            if let satisfied = item.workAttempts.last(where: { $0.lane == .pursuit && $0.disposition == .goalSatisfied }) {
                recent.insert(satisfied.attemptId)
            }
            for attempt in settled where !recent.contains(attempt.attemptId)
                && attempt.lane == .pursuit && attempt.disposition != .unstarted {
                retained.pursuit?.retiredSessionsByDay[attempt.day, default: 0] += 1
            }
            retained.workAttempts.removeAll {
                $0.completedAt != nil && $0.receiptHandedOff && !recent.contains($0.attemptId)
                    && ($0.disposition != .unstarted || $0.day < (currentDay ?? ""))
            }
            return retained
        }
        let ordered = orderByAlias(live)
        let liveSlots = DeskState(items: ordered, generatedTs: revision).workSlotsByDay
        accounting.workSlotsByDay = accounting.workSlotsByDay.reduce(into: [:]) { retained, row in
            let (day, handles) = row
            if let currentDay, day >= currentDay {
                retained[day] = handles
            } else {
                let live = handles.reduce(into: [String: [String]]()) { kept, entry in
                    let ids = entry.value.filter { liveSlots[day]?[entry.key]?.contains($0) == true }
                    if !ids.isEmpty { kept[entry.key] = ids }
                }
                if !live.isEmpty { retained[day] = live }
            }
        }
        return DeskState(items: ordered, generatedTs: revision, workSlotsByDay: accounting.workSlotsByDay)
    }

    /// Malformed aliases sort last so authored state cannot crash rendering.
    static func aliasSeq(_ alias: String) -> Int {
        Int(alias.split(separator: ".").last.map(String.init) ?? "") ?? Int.max
    }

    /// Retain orphans and unreachable nodes so depth-first ordering cannot lose live work.
    static func orderByAlias(_ live: [DeskItem]) -> [DeskItem] {
        let liveHandles = Set(live.map { $0.handle })
        let byParent = Dictionary(grouping: live, by: { $0.parent ?? "" })
        var result: [DeskItem] = []
        var emitted: Set<String> = []

        func emit(_ items: [DeskItem]) {
            for item in items.sorted(by: { aliasSeq($0.alias) < aliasSeq($1.alias) }) {
                if emitted.contains(item.handle) { continue }
                result.append(item); emitted.insert(item.handle)
                emit(byParent[item.handle] ?? [])
            }
        }

        let roots = live.filter { item in
            guard let parent = item.parent else { return true }
            return !liveHandles.contains(parent)
        }
        emit(roots)
        // Preserve even cyclic or unreachable items.
        for item in live where !emitted.contains(item.handle) {
            result.append(item); emitted.insert(item.handle)
        }
        return result
    }
    static func nextCadenceRefresh(after completedAt: String, cadence: Cadence) -> String? {
        guard let completed = DeskClock.parseISO(completedAt) else { return nil }
        let seconds: TimeInterval
        switch cadence.mode {
        case .daily:
            seconds = 24 * 60 * 60
        case .weekly:
            seconds = 7 * 24 * 60 * 60
        case .tick:
            seconds = cadence.interval.flatMap(DeskPage.parseDuration) ?? 2 * 60 * 60
        default:
            return cadence.nextRefreshAt
        }
        return DeskClock.nowISO(completed.addingTimeInterval(seconds))
    }

    // MARK: - Per-item history caps (notes / refs)

    /// Cap notes because every op rewrites the item tree; unbounded history makes feed growth quadratic.
    public static let notesCap = 200

    /// Refs share the notes' write-amplification bound.
    public static let refsCap = 64

    static func appendNoteCapped(_ item: inout DeskItem, _ note: DeskNote) {
        item.notes.append(note)
        if item.notes.count > notesCap {
            item.notes.removeFirst(item.notes.count - notesCap)
        }
    }

    /// Evict low-priority refs first because tracking references carry identity.
    /// A newest-only cap could orphan tracked rows; survivors retain insertion order.
    static func appendRefCapped(_ item: inout DeskItem, _ incoming: DeskRef) {
        var ref = incoming
        if case .step(var step) = ref.kind, let previous = item.step {
            step.promiseCaptures = previous.promiseCaptures + step.promiseCaptures.filter { !previous.promiseCaptures.contains($0) }
            ref.kind = .step(step)
        }
        item.refs.append(ref)
        guard item.refs.count > refsCap else { return }
        let overflow = item.refs.count - refsCap
        // Tracking refs are never evicted, even when preserving every identity exceeds the cap.
        func isTrackingRef(_ r: DeskRef) -> Bool {
            switch r.kind {
            case .ghPr, .ghIssue: return true
            default: return false
            }
        }
        // The newest step owns queue readiness and peer provenance.
        let newestStep = item.refs.lastIndex { if case .step = $0.kind { return true }; return false }
        let victims = Set(
            item.refs.enumerated()
                .filter { !isTrackingRef($0.element) && $0.offset != newestStep }
                .sorted { a, b in
                    a.element.priority == b.element.priority
                        ? a.offset < b.offset
                        : a.element.priority > b.element.priority
                }
                .prefix(overflow)
                .map(\.offset)
        )
        item.refs = item.refs.enumerated().filter { !victims.contains($0.offset) }.map(\.element)
    }

}
