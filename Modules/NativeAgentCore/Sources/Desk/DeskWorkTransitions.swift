import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskWorkTransitions.swift` | Locked work creation, bounded reservations and idempotent receipts |
extension SwiftNativeDeskStore {
    /// Allocate aliases under the flock so concurrent creates cannot collide.
    @discardableResult
    public func createItem(
        kind: DeskKind,
        project: String,
        title: String,
        parent: String? = nil,
        summary: String? = nil,
        assignee: String? = nil,
        laneOf: String? = nil
    ) async throws -> DeskItem {
        try await createItemTransaction(
            kind: kind,
            project: project,
            title: title,
            parent: parent,
            summary: summary,
            assignee: assignee,
            laneOf: laneOf,
            reuseEquivalent: false
        ).item
    }
    /// Compare sibling intent under the allocation flock so concurrent asks cannot create duplicate owners.
    /// Terminal history leaves room for new work; explicit creation can intentionally repeat a sibling name.
    public func createOrReuseEquivalentItem(
        kind: DeskKind,
        project: String,
        title: String,
        parent: String? = nil,
        summary: String? = nil,
        assignee: String? = nil,
        laneOf: String? = nil
    ) async throws -> CreateResult {
        try await createItemTransaction(
            kind: kind,
            project: project,
            title: title,
            parent: parent,
            summary: summary,
            assignee: assignee,
            laneOf: laneOf,
            reuseEquivalent: true
        )
    }
    /// Key system findings under one flock so refiling preserves closure and person ownership.
    /// Reopening requires an explicit request.
    public func fileSystemItem(
        kind: DeskKind,
        project: String,
        title: String,
        summary: String?,
        assignee: String?,
        waitingOn: String? = nil,
        findingKey: String,
        note: String,
        refs: [DeskRef],
        reopen: Bool = false,
        refreshRefs: Bool = false
    ) async throws -> CreateResult {
        try await createItemTransaction(
            kind: kind, project: project, title: title, parent: nil, summary: summary,
            assignee: assignee, laneOf: nil, reuseEquivalent: false,
            origin: .system, keyNote: note, findingKey: findingKey, refs: refs, reopenKeyed: reopen,
            refreshRefs: refreshRefs, waitingOn: waitingOn
        )
    }
    /// Queue lookup, provenance and budget checks share the write transaction.
    func addQueueStep(_ incoming: DeskStep, replacing: MyQueue.Entry? = nil) async throws -> (entry: MyQueue.Entry, change: MyQueue.Change) {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            var state = Self.compact(base: feed.base, feed.ops)
            // Interrupted imports reuse job identity; pending work cannot archive before migration commits.
            if replacing == nil, let id = incoming.scheduledJobID,
               let item = state.items.first(where: { $0.step?.scheduledJobID == id }), let step = item.step {
                if !item.status.isTerminal,
                   step.words != incoming.words || step.when != incoming.when || step.rhythm != incoming.rhythm
                    || step.until != incoming.until || step.say != incoming.say || step.clockStart != incoming.clockStart
                    || step.status != incoming.status {
                    throw ToolFailureError("""
                        Scheduled intention \(id) changed before its migration committed. Reconcile its Desk step and source job before \
                        relaunching; no scheduler work was retired.
                        """, effects: .none)
                }
                return (MyQueue.Entry(item: item, step: step), .reused)
            }
            let open = MyQueue.entries(state)
            let words = Self.equivalentDeskText(incoming.words)
            let same: MyQueue.Entry?
            if let replacing {
                guard let current = open.first(where: { $0.item.handle == replacing.item.handle }),
                      current.item.updatedAt == replacing.item.updatedAt else { throw MyQueue.Superseded() }
                same = current
            } else { same = incoming.scheduledJobID == nil
                ? open.first { Self.equivalentDeskText($0.step.words) == words } : nil }
            var step = incoming
            step.lifeID = try DataRootLife.current(in: dataRoot)
            if let same {
                if incoming.source != nil, replacing == nil { step = same.step }
                step.peers = incoming.peers
                step.elevated = incoming.elevated
                step.preserveOrigin(of: same.step)
                if incoming.source == nil, replacing == nil, case .userWrites? = MyQueue.When(step.when, card: step.card) {
                    step.filedAt = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
                }
                if step == same.step { return (same, .reused) }
                if step.when != same.step.when || step.card != same.step.card || step.rhythm != same.step.rhythm {
                    step.filedAt = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
                }
            } else {
                if step.source != nil, open.filter({ $0.step.source != nil }).count >= MyQueue.inferredCap {
                    throw MyQueue.Full()
                }
                step.filedAt = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            }
            let title = step.peers.isEmpty && step.elevated.isEmpty
                ? String(step.words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                : "A step from \((step.peers + step.elevated).joined(separator: ", "))'s turn"
            let handle = same?.item.handle ?? DeskClock.newHandle()
            var bodies: [DeskOpBody] = []
            if same == nil {
                let alias = try Self.nextAlias(parentHandle: nil, parentAlias: nil, base: feed.base, ops: feed.ops)
                bodies.append(.createItem(alias: alias, kind: .plan, project: MyQueue.project, title: title,
                    parent: nil, summary: nil, assignee: nil, laneOf: nil, origin: .agent, pursuit: nil))
            }
            bodies.append(.addRef(ref: DeskRef(kind: .step(step))))
            if step.action != same?.step.action {
                let note = try step.action.map { "Habit bound: " + (try $0.serialize(pretty: false)) } ?? "Habit dropped."
                bodies.append(.appendNote(text: note, author: "agent"))
            }
            if let same, same.item.title != title { bodies.append(.updateTitle(title: title, summary: nil)) }
            if same == nil {
                bodies.append(.setStatus(status: .todo, blockedReason: nil, waitingOn: nil,
                    progress: nil, assignee: nil, laneOf: nil))
            }
            try DeskOp.requireComplete(bodies.map { DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: $0) })
            for body in bodies {
                let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: body)
                try Self.validateHierarchyTransition(op, in: state)
                try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
                (state, feed) = try await appendAndRecompactUnlocked(op, feed: feed)
            }
            guard let entry = state.items.first(where: { $0.handle == handle }).flatMap(MyQueue.entry) else {
                throw DeskError.unknownHandle(handle)
            }
            return (entry, same == nil ? .added : .updated)
        }
    }
    private func createItemTransaction(
        kind: DeskKind,
        project: String,
        title: String,
        parent: String?,
        summary: String?,
        assignee: String?,
        laneOf: String?,
        reuseEquivalent: Bool,
        origin: DeskOrigin = .owner,
        keyNote: String? = nil,
        findingKey: String? = nil,
        refs: [DeskRef] = [],
        reopenKeyed: Bool = false,
        refreshRefs: Bool = false,
        waitingOn: String? = nil
    ) async throws -> CreateResult {
        guard Self.equivalentDeskText(project) != MyQueue.project else {
            throw DeskError.queueCreationRequiresQueuePath
        }
        let refs = try refs.map(beginStep)
        return try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let priorState = Self.compact(base: feed.base, feed.ops)
            // Validate live parent state so a child cannot become orphaned under an archived parent.
            var parentAlias: String?
            if let parent {
                guard let live = priorState.items.first(where: { $0.handle == parent }) else {
                    throw DeskError.unknownHandle(parent)
                }
                guard !live.status.isTerminal else {
                    throw DeskError.childRefusedTerminalParent(parentHandle: parent)
                }
                parentAlias = live.alias
            }
            if reuseEquivalent,
               let existing = priorState.items.first(where: {
                   !$0.status.isTerminal
                       && $0.kind == kind
                       && $0.parent == parent
                       && $0.laneOf == laneOf
                       && Self.equivalentDeskText($0.assignee) == Self.equivalentDeskText(assignee)
                       && Self.equivalentDeskText($0.project) == Self.equivalentDeskText(project)
                       && Self.equivalentDeskText($0.title) == Self.equivalentDeskText(title)
               }) {
                return CreateResult(item: existing, reusedEquivalent: true)
            }
            let keyed = findingKey.map { key in
                priorState.items.filter { $0.project == project && $0.findingKey == key }
            } ?? []
            if !reopenKeyed, keyed.isEmpty, let findingKey,
               let archived = try await self.archivedRecords().first(where: { $0.project == project && $0.findingKey == findingKey }) {
                throw DeskError.findingArchived(handle: archived.handle)
            }
            if !reopenKeyed, let existing = keyed.first,
               existing.status.isTerminal || existing.assignee == "owner" || existing.waitingOn == "owner" {
                return CreateResult(item: existing, reusedEquivalent: true)
            }
            if let existing = keyed.first(where: { !$0.status.isTerminal }) ?? keyed.first {
                var bodies: [DeskOpBody] = []
                if existing.status.isTerminal {
                    bodies.append(.setStatus(status: .watch, blockedReason: nil, waitingOn: nil,
                        progress: nil, assignee: nil, laneOf: nil))
                }
                var incomingRefs = refs
                if let index = incomingRefs.lastIndex(where: { $0.kind.token == "step" }),
                   case .step(var step) = incomingRefs[index].kind {
                    if let previous = existing.step {
                        step.preserveOrigin(of: previous)
                        step.lifeID = previous.lifeID
                    }
                    incomingRefs[index].kind = .step(step)
                    if !refreshRefs && step != existing.step {
                        bodies.append(.addRef(ref: DeskRef(kind: .step(step))))
                    }
                }
                let nextTitle = existing.title != title ? title : nil
                let nextSummary = summary?.isEmpty == false && existing.summary != summary ? summary : nil
                let nextRefs = refreshRefs && existing.refs.map(\.kind) != incomingRefs.map(\.kind) ? incomingRefs : nil
                // Only changed fields append an op, keeping refile observers quiet.
                if nextTitle != nil || nextSummary != nil || nextRefs != nil {
                    bodies.append(.updateTitle(title: nextTitle, summary: nextSummary, refs: nextRefs))
                }
                var (state, committedFeed) = (priorState, feed)
                try DeskOp.requireComplete(bodies.map { DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: existing.handle, body: $0) })
                for body in bodies {
                    let op = DeskOp(ts: DeskClock.commitStamp(notBefore: committedFeed.maxCommittedTs),
                        handle: existing.handle, body: body)
                    try Self.validateHierarchyTransition(op, in: state)
                    (state, committedFeed) = try await appendAndRecompactUnlocked(op, feed: committedFeed)
                }
                guard let item = state.items.first(where: { $0.handle == existing.handle }) else {
                    throw DeskError.unknownHandle(existing.handle)
                }
                return CreateResult(item: item, reusedEquivalent: true)
            }
            let alias = try Self.nextAlias(parentHandle: parent, parentAlias: parentAlias, base: feed.base, ops: feed.ops)
            let handle = DeskClock.newHandle()
            // Dedicated creation paths own pursuit evidence, queue provenance and system origin.
            let create = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: .createItem(
                alias: alias, kind: kind, project: project, title: title, parent: parent, summary: summary,
                assignee: assignee, laneOf: laneOf,
                origin: origin, pursuit: nil, findingKey: findingKey
            ))
            try Self.validateHierarchyTransition(create, in: priorState)
            try Self.validatePursuitInvariants(create, in: priorState, viaGenericPath: true)
            try DeskOp.requireComplete([create] + ((keyNote.map { [DeskOpBody.appendNote(text: $0)] } ?? []) + refs.map({ .addRef(ref: $0) }))
                .map { DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: $0) })
            var (committedState, committedFeed) = try await appendAndRecompactUnlocked(create, feed: feed)
            // Assign ownership before another caller can close or reassign the new item.
            if let waitingOn, let created = committedState.items.first(where: { $0.handle == handle }) {
                let op = DeskOp(ts: DeskClock.commitStamp(notBefore: committedFeed.maxCommittedTs), handle: handle,
                    body: .setStatus(status: created.status, blockedReason: nil, waitingOn: waitingOn,
                        progress: nil, assignee: assignee, laneOf: laneOf))
                (committedState, committedFeed) = try await appendAndRecompactUnlocked(op, feed: committedFeed)
            }
            for body in (keyNote.map { [DeskOpBody.appendNote(text: $0)] } ?? []) + refs.map({ .addRef(ref: $0) }) {
                let op = DeskOp(ts: DeskClock.commitStamp(notBefore: committedFeed.maxCommittedTs), handle: handle, body: body)
                (committedState, committedFeed) = try await appendAndRecompactUnlocked(op, feed: committedFeed)
            }
            guard let created = committedState.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            return CreateResult(item: created, reusedEquivalent: false)
        }
    }
    public static func equivalentDeskText(_ value: String?) -> String {
        let folded = (value ?? "")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let wordsOnly = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return wordsOnly
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
    /// Validate pursuit evidence and capacity under the same flock as creation.
    @discardableResult
    public func openPursuit(
        project: String,
        title: String,
        pursuit: Pursuit,
        summary: String? = nil,
        notify: NotifyPolicy = NotifyPolicy()
    ) async throws -> DeskItem {
        return try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let alias = try Self.nextAlias(parentHandle: nil, parentAlias: nil, base: feed.base, ops: feed.ops)
            let handle = DeskClock.newHandle()
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .openPursuit(
                    alias: alias, project: project, title: title,
                    summary: summary, pursuit: pursuit, notify: notify
                )
            )
            let state = Self.compact(base: feed.base, feed.ops)
            try Self.validateHierarchyTransition(op, in: state)
            // Dedicated creation still enforces required fields, evidence and the open-pursuit cap.
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            let after = try await appendAndRecompactUnlocked(op, feed: feed).state
            guard let created = after.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            return created
        }
    }
    @discardableResult
    public func reserveWorkAttempt(
        _ handle: String,
        lane: DeskWorkAttempt.Lane,
        day: String,
        slot: String
    ) async throws -> String {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.status.isTerminal, item.isPursuit == (lane == .pursuit) else {
                throw DeskError.notAPursuit(handle: handle)
            }
            let attemptId = DeskClock.workAttemptId(handle: handle, lane: lane, day: day, slot: slot)
            if state.hasWorkSlot(handle: handle, id: attemptId) { return attemptId }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .reserveWorkAttempt(attemptId: attemptId, lane: lane, day: day, slot: slot)
            )
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return attemptId
        }
    }
    @discardableResult
    public func handOffWorkReceipt(_ handle: String, reservationId: String) async throws -> DeskOp? {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            let handedOff = item.workAttempts.first(where: { $0.attemptId == reservationId })?.receiptHandedOff
            if handedOff == true { return nil }
            if handedOff == nil, state.hasWorkSlot(handle: handle, id: reservationId) { return nil }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .handOffWorkReceipt(reservationId: reservationId)
            )
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }
    /// Select receipt or note by item kind under one lock; failure cannot select another tool.
    @discardableResult
    public func appendWorkReceipt(_ handle: String, receipt: String) async throws -> DeskOp {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: item.isPursuit ? .workLog(receipt: receipt) : .appendNote(text: receipt, author: "agent")
            )
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }
    @discardableResult
    public func setStatus(
        _ handle: String,
        status: DeskStatus,
        blockedReason: String? = nil,
        waitingOn: String? = nil,
        progress: DeskProgress? = nil,
        assignee: String? = nil,
        laneOf: String? = nil
    ) async throws -> DeskOp {
        func normalized(_ value: String?, field: String) throws -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DeskError.liveActivityMetadataEmpty(field: field)
            }
            return trimmed
        }
        let normalizedAssignee = try normalized(assignee, field: "assignee")
        let normalizedLaneOf = try normalized(laneOf, field: "laneOf")
        return try await appendValidated(DeskOp(
            handle: handle,
            body: .setStatus(
                status: status,
                blockedReason: blockedReason,
                waitingOn: waitingOn,
                progress: progress,
                assignee: normalizedAssignee,
                laneOf: normalizedLaneOf
            )
        ))
    }
    @discardableResult
    /// Match the caller's open revision; commit any note under the same lock and revision stamp.
    public func setStatusIfUnchanged(
        _ handle: String,
        expectedUpdatedAt: String,
        status: DeskStatus,
        blockedReason: String? = nil,
        note: String? = nil
    ) async throws -> DeskOp? {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.status.isTerminal, item.updatedAt == expectedUpdatedAt else { return nil }
            let op = try await setStatus(handle, status: status, blockedReason: blockedReason)
            if let note, let noted = try? await appendNote(handle, text: note) { return noted }
            return op
        }
    }
    @discardableResult
    public func updateTitle(_ handle: String, title: String? = nil, summary: String? = nil) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .updateTitle(title: title, summary: summary)))
    }
    @discardableResult
    public func addRef(_ handle: String, ref: DeskRef) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .addRef(ref: beginStep(ref))))
    }
    private func beginStep(_ incoming: DeskRef) throws -> DeskRef {
        var ref = incoming
        if case .step(var step) = ref.kind, step.lifeID == nil {
            step.lifeID = try DataRootLife.current(in: dataRoot)
            ref.kind = .step(step)
        }
        return ref
    }
    @discardableResult
    public func appendNote(_ handle: String, text: String, author: String = "system") async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .appendNote(text: text, author: author)))
    }
    /// Settle waits under the flock so earlier closes or new blockers win.
    /// Write notes once so partial commits heal without duplicate history; invalid hierarchy stays for explicit repair.
    @discardableResult
    public func settleWaits(
        _ settlement: @escaping @Sendable (DeskItem) -> (note: String, status: DeskStatus, blockedReason: String?)?
    ) async throws -> [DeskOp] {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            var state = Self.compact(base: feed.base, feed.ops)
            var settled: [DeskOp] = []
            for item in state.items where !item.status.isTerminal {
                guard let answer = settlement(item) else { continue }
                let status = DeskOp(handle: item.handle, body: .setStatus(
                    status: answer.status, blockedReason: answer.blockedReason, waitingOn: nil,
                    progress: nil, assignee: nil, laneOf: nil))
                guard (try? Self.validateHierarchyTransition(status, in: state)) != nil else { continue }
                let note = DeskOp(handle: item.handle, body: .appendNote(text: answer.note))
                for var op in item.notes.contains(where: { $0.text == answer.note }) ? [status] : [note, status] {
                    op.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
                    (state, feed) = try await appendAndRecompactUnlocked(op, feed: feed)
                    settled.append(op)
                }
            }
            return settled
        }
    }
    /// Check and append markers under one flock so concurrent wakes cannot duplicate receipts.
    /// Bound deduplication to the delivery snapshot so later occurrences retain their own note.
    @discardableResult
    public func appendNoteIfAbsent(
        _ handle: String,
        marker: String,
        text: String,
        author: String = "system",
        after: String? = nil
    ) async throws -> DeskOp? {
        let normalizedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMarker.isEmpty, normalizedText.hasPrefix(normalizedMarker) else {
            throw DeskError.liveActivityMetadataEmpty(field: "idempotent note marker/text")
        }
        let cutoff = after.flatMap(DeskClock.parseISO)
        guard after == nil || cutoff != nil else {
            throw DeskError.liveActivityMetadataEmpty(field: "idempotent note boundary")
        }
        return try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.notes.contains(where: { note in
                guard note.text.hasPrefix(normalizedMarker) else { return false }
                // Identical daily content is a new occurrence; only notes after this snapshot can settle it.
                if let cutoff { return DeskClock.parseISO(note.ts).map { $0 > cutoff } ?? false }
                return true
            }) else {
                return nil
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .appendNote(text: normalizedText, author: author)
            )
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }
    /// Commit veto, terminal state and rationale in one op so relaunch cannot expose a partial decision.
    /// Completed vetoes remain durable no-ops.
    @discardableResult
    public func vetoPursuit(_ handle: String, note: String) async throws -> DeskOp? {
        let rationale = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rationale.isEmpty else {
            throw DeskError.pursuitFieldMissing(reason: "veto rationale is empty")
        }
        return try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit else { throw DeskError.notAPursuit(handle: handle) }
            if item.status == .canceled,
               item.notes.contains(where: { $0.text == rationale }) {
                return nil
            }
            guard !item.status.isTerminal || item.status == .canceled else {
                throw DeskError.vetoRefusedTerminal(handle: handle, status: item.status)
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .vetoPursuit(note: rationale)
            )
            try Self.validateHierarchyTransition(op, in: state)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }
    @discardableResult
    public func setCadence(_ handle: String, cadence: Cadence) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setCadence(cadence: cadence)))
    }
    @discardableResult
    public func setNotify(_ handle: String, policy: NotifyPolicy) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setNotify(policy: policy)))
    }
}
