import Foundation

extension SwiftNativeDeskStore {
    // MARK: - Compaction (pure fold — rebuild MUST equal in-memory fold)

    /// Fold the op stream into the live DeskState. Ops apply in FILE ORDER:
    /// create_item seeds an item; later ops mutate by handle; archive_item
    /// removes it from the live set. A mutation whose create aged out (orphan)
    /// is tolerated (skipped). Items are returned in alias order — top-level by
    /// numeric seq, each immediately followed by its children in child-seq order
    /// (orphaned-parent live items appended last).
    public static func compact(_ ops: [DeskOp]) -> DeskState {
        compact(base: nil, ops)
    }

    /// Fold seeded from a compaction base: the base's items ARE the reduced
    /// state through `lastCompactedOpId`, so the tail ops apply on top exactly
    /// as if the compacted prefix had just been replayed. A tail mutation
    /// targeting a handle the base no longer carries (archived before the
    /// snapshot) is skipped by the same orphan tolerance as always.
    static func compact(base: DeskCompactionBase?, _ ops: [DeskOp]) -> DeskState {
        var byHandle: [String: DeskItem] = [:]
        var createOrder: [String] = []
        var archived: Set<String> = []
        if let base {
            for item in base.state.items {
                byHandle[item.handle] = item
                createOrder.append(item.handle)
            }
        }

        for op in ops {
            switch op.body {
            case let .createItem(alias, kind, project, title, parent, summary, assignee, laneOf, origin, pursuit):
                if byHandle[op.handle] == nil { createOrder.append(op.handle) }
                byHandle[op.handle] = DeskItem(
                    handle: op.handle, alias: alias, parent: parent, kind: kind,
                    status: .watch, project: project, title: title, summary: summary,
                    assignee: assignee, laneOf: laneOf,
                    cadence: Cadence(), notify: NotifyPolicy(),
                    openedAt: op.ts, updatedAt: op.ts,
                    origin: origin, pursuit: pursuit
                )
            case let .openPursuit(alias, project, title, summary, pursuit, notify):
                // Dedicated agent-pursuit create (H2). Same materialization as a
                // create_item pinned to origin=.agent/kind=.project.
                if byHandle[op.handle] == nil { createOrder.append(op.handle) }
                byHandle[op.handle] = DeskItem(
                    handle: op.handle, alias: alias, parent: nil, kind: .project,
                    status: .watch, project: project, title: title, summary: summary,
                    cadence: Cadence(), notify: notify,
                    openedAt: op.ts, updatedAt: op.ts,
                    origin: .agent, pursuit: pursuit
                )
            case let .setStatus(status, blockedReason, waitingOn, progress, assignee, laneOf):
                guard var item = byHandle[op.handle] else { continue }
                item.status = status
                item.blockedReason = blockedReason
                item.waitingOn = waitingOn
                if let progress { item.progress = progress }
                if let assignee { item.assignee = assignee }
                if let laneOf { item.laneOf = laneOf }
                // A terminal status reached via set_status (not close_item) still
                // needs closedAt, or archiveSweep + the "archives in" countdown
                // skip it forever (gpt-5.5 review HIGH). A non-terminal status
                // re-opens the row, so clear any stale closedAt.
                if status.isTerminal {
                    if item.closedAt == nil { item.closedAt = op.ts }
                } else {
                    item.closedAt = nil
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .updateTitle(title, summary):
                guard var item = byHandle[op.handle] else { continue }
                if let title, !title.isEmpty { item.title = title }
                // Empty summary is a NO-OP (mirrors title, and the encode that
                // omits empty strings) — NOT a clear. The old `isEmpty ? nil`
                // clear could never round-trip: the encode dropped the empty
                // string, so the clear was silently lost (gpt-5.5 review HIGH).
                if let summary, !summary.isEmpty { item.summary = summary }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .addRef(ref):
                guard var item = byHandle[op.handle] else { continue }
                Self.appendRefCapped(&item, ref)
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .updateRef(refId, cachedFields):
                guard var item = byHandle[op.handle] else { continue }
                if let idx = item.refs.firstIndex(where: { $0.refId == refId }) {
                    item.refs[idx].kind = item.refs[idx].kind.applyingCachedFields(cachedFields)
                    item.updatedAt = op.ts
                }
                byHandle[op.handle] = item
            case let .appendNote(text):
                guard var item = byHandle[op.handle] else { continue }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: text))
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
                item.notify = policy
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
                // Stamps notify.lastNotifiedAt ONLY — deliberately does NOT bump
                // updatedAt, so a notification can't masquerade as a content
                // change and re-trigger itself (notify-evaluator idempotency).
                guard var item = byHandle[op.handle] else { continue }
                item.notify.lastNotifiedAt = at
                byHandle[op.handle] = item
            case .archiveItem:
                archived.insert(op.handle)
            case let .reserveWorkSession(reservationId, day, slot):
                // Only pursuits carry a reservation ledger; a reserve op on a
                // non-pursuit is tolerated (skipped). Dedup by id so a replayed
                // reserve op is idempotent — the caps count DISTINCT rows.
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                if !p.reservations.contains(where: { $0.reservationId == reservationId }) {
                    p.reservations.append(WorkReservation(reservationId: reservationId, day: day, slot: slot, reservedAt: op.ts))
                }
                Self.recomputePursuitCounters(&p)
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .completeWorkSession(reservationId, receipt):
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                if let idx = p.reservations.firstIndex(where: { $0.reservationId == reservationId }) {
                    p.reservations[idx].receipt = receipt
                    p.reservations[idx].completedAt = op.ts
                }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                p.lastWorkedAt = op.ts
                Self.recomputePursuitCounters(&p)
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .settleWorkSession(reservationId, receipt, disposition, artifactRefs):
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                if let idx = p.reservations.firstIndex(where: { $0.reservationId == reservationId }) {
                    p.reservations[idx].receipt = receipt
                    p.reservations[idx].completedAt = op.ts
                    p.reservations[idx].disposition = disposition
                    p.reservations[idx].artifactRefs = Array(artifactRefs.prefix(16))
                }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                p.lastWorkedAt = op.ts
                Self.recomputePursuitCounters(&p)
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .reserveWorkAttempt(attemptId, lane, day, slot):
                guard var item = byHandle[op.handle] else { continue }
                if !item.workAttempts.contains(where: { $0.attemptId == attemptId }) {
                    item.workAttempts.append(DeskWorkAttempt(
                        attemptId: attemptId,
                        lane: lane,
                        day: day,
                        slot: slot,
                        reservedAt: op.ts
                    ))
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .completeWorkAttempt(attemptId, receipt):
                guard var item = byHandle[op.handle],
                      let index = item.workAttempts.firstIndex(where: { $0.attemptId == attemptId }) else { continue }
                item.workAttempts[index].receipt = receipt
                item.workAttempts[index].completedAt = op.ts
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                item.cadence.lastRefreshAt = op.ts
                item.cadence.nextRefreshAt = Self.nextCadenceRefresh(after: op.ts, cadence: item.cadence)
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setBlockedOn(handles):
                // Whole-set REPLACE, same orphan tolerance as every other
                // mutation. Blockedness is DERIVED from this edge set on read
                // (DeskSequencing) — no status op is written here, which is what
                // makes the auto-unblock cascade need no writer at all.
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
            }
        }

        let live = createOrder.compactMap { byHandle[$0] }.filter { !archived.contains($0.handle) }
        let ordered = orderByAlias(live)
        // DETERMINISTIC fold: the rev stamp is the newest of (last op ts, base
        // stamp) — NOT wall-clock — so the same feed always folds to an equal
        // DeskState and state.json never drifts on a no-op recompaction. The
        // max matters: the raw append path does not restamp, so a tail op can
        // carry a ts OLDER than the base; taking just ops.last would regress
        // generatedTs, and if that state became the next base an empty-tail
        // maxCommittedTs would floor future commit stamps on the stale value
        // (gpt-5.5 compaction review MED — Lamport floor regression).
        let revision = [ops.last?.ts, base?.state.generatedTs].compactMap { $0 }.max() ?? ""
        return DeskState(items: ordered, generatedTs: revision)
    }

    /// Trailing numeric component of an alias ("2" -> 2, "2.10" -> 10). Defaults
    /// to a large sentinel so a malformed alias sorts last (never crashes).
    static func aliasSeq(_ alias: String) -> Int {
        Int(alias.split(separator: ".").last.map(String.init) ?? "") ?? Int.max
    }

    /// Order live items into render order via DEPTH-FIRST descent: each item is
    /// immediately followed by its whole subtree (children, grandchildren, …),
    /// siblings in child-seq order. Roots are the top-level items (parent nil)
    /// plus orphans (parent not in the live set). A final pass appends anything
    /// still unemitted (a parent cycle / unreachable node) so NO live item is
    /// ever dropped from the materialized state.
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
            guard let parent = item.parent else { return true }   // top-level
            return !liveHandles.contains(parent)                  // orphan
        }
        emit(roots)
        // Cycle / unreachable guard — never silently drop a live item.
        for item in live where !emitted.contains(item.handle) {
            result.append(item); emitted.insert(item.handle)
        }
        return result
    }
    /// Recompute a pursuit's derived counters from its reservation ledger — pure
    /// (no wall clock): `workSessionsToday` = reservations sharing the NEWEST
    /// reservation day (lexicographic max on yyyy-MM-dd). The authoritative daily
    /// cap still counts from the ops feed; this field is the display denorm.
    static func recomputePursuitCounters(_ p: inout Pursuit) {
        guard let newestDay = p.reservations.map(\.day).max() else {
            p.workSessionsToday = 0
            return
        }
        p.workSessionsToday = p.reservations.filter { $0.day == newestDay }.count
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
            seconds = cadence.interval.flatMap(DeskProjection.parseDuration) ?? 2 * 60 * 60
        default:
            return cadence.nextRefreshAt
        }
        return DeskClock.nowISO(completed.addingTimeInterval(seconds))
    }

    // MARK: - Per-item history caps (notes / refs)

    /// Newest N notes retained per item. Notes are an append-only per-item log
    /// (append_note, plus a receipt per completed work session / work_log), and
    /// the WHOLE item tree is re-serialized + fsynced on every desk op AND baked
    /// into the compaction base — so an uncapped note list makes the feed O(n²)
    /// over its life, defeating the exact cost compaction exists to bound.
    /// Readers only ever want the recent tail: the projection and DeskView read
    /// `notes.last`, the Workshop panel reads them newest-first.
    public static let notesCap = 200

    /// Max refs retained per item. Same write-amplification argument as notes.
    public static let refsCap = 64

    /// Append a note, evicting the OLDEST beyond `notesCap`.
    static func appendNoteCapped(_ item: inout DeskItem, _ note: DeskNote) {
        item.notes.append(note)
        if item.notes.count > notesCap {
            item.notes.removeFirst(item.notes.count - notesCap)
        }
    }

    /// Append a ref, evicting the LEAST IMPORTANT beyond `refsCap` — by the
    /// model's own `DeskRefKind.priority` ranking (the same one liveRefs sorts
    /// by), oldest-first among equals. Deliberately NOT a plain `suffix`: gh
    /// pr/issue refs (priority 0/1) are an item's tracking IDENTITY —
    /// GitHubProjectTracking matches and retires desk rows by them — so a
    /// newest-N cap would silently orphan a tracked row behind a flood of
    /// low-priority note/trace refs. Survivors keep insertion order.
    static func appendRefCapped(_ item: inout DeskItem, _ ref: DeskRef) {
        item.refs.append(ref)
        guard item.refs.count > refsCap else { return }
        let overflow = item.refs.count - refsCap
        // gh_pr / gh_issue refs are the row's TRACKING IDENTITY —
        // GitHubProjectTracking matches and retires a desk row by the exact
        // presence of that ref. Evicting one (even under a flood of newer,
        // equal-priority gh refs) orphans the tracked row and duplicates it on
        // the next observation (gpt-5.5 wave-2 review). So they are NEVER
        // eviction victims: overflow is drawn only from the non-tracking kinds,
        // and if tracking refs alone exceed the cap the array is allowed to
        // exceed it rather than lose an identity.
        func isTrackingRef(_ r: DeskRef) -> Bool {
            switch r.kind {
            case .ghPr, .ghIssue: return true
            default: return false
            }
        }
        let victims = Set(
            item.refs.enumerated()
                .filter { !isTrackingRef($0.element) }
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
