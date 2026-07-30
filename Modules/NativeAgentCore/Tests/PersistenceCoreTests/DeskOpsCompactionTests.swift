import Foundation
import Testing
@testable import PersistenceCore

/// Desk op-log snapshot+tail compaction (retrofit of the GitHubCommandStore
/// pattern, audit round 2 F1). These tests pin: semantic equivalence with an
/// uncompacted twin driven through an identical rich lifecycle, feed
/// boundedness, survival of the ledgers that live in RAW op history (alias
/// monotonicity, reservation idempotency/caps, notify CAS, the reconcile
/// repair's last-non-terminal target), the base-write/truncate crash window,
/// continued operation (second compaction), and fail-loud on a corrupt base.
@Suite("Desk ops compaction", .serialized)
struct DeskOpsCompactionTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func store(_ root: URL, threshold: Int) -> SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: root, changeBus: StoreChangeBus(), opsCompactionThreshold: threshold)
    }

    private func pursuitPayload() -> Pursuit {
        Pursuit(
            why: "curiosity about the thing",
            evidence: PromotionDossier(citations: [
                .standingView(id: "sv-1"),
                .feltSalience(dates: ["2026-07-01", "2026-07-02"]),
            ]),
            doneLooksLike: "a findings note exists",
            abandonCondition: "two sessions with nothing new"
        )
    }

    private func opsLineCount(_ store: SwiftNativeDeskStore) -> Int {
        (try? String(contentsOf: store.opsPath, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
    }

    /// Deterministic semantic fingerprint over the FULL serialized item — the
    /// only values normalized away are the ones that legitimately differ
    /// between twin stores: handles (mapped to the item's alias, equal by
    /// construction when both stores run the same logical sequence) and
    /// wall-clock stamps (reduced to presence markers). Everything else —
    /// every ref payload, notify policy field, cadence field, pursuit
    /// dossier/bounds, reservation row — participates, so ANY base
    /// round-trip loss shows up here. Item ORDER is part of the semantics
    /// (alias render order) — not sorted.
    private func fingerprint(_ state: DeskState) -> [String] {
        let aliasByHandle = Dictionary(uniqueKeysWithValues: state.items.map { ($0.handle, $0.alias) })
        let timestampKeys: Set<String> = [
            "openedAt", "updatedAt", "closedAt", "ts", "at", "reservedAt",
            "completedAt", "lastNotifiedAt", "lastWorkedAt",
            "nextRefreshAt", "lastRefreshAt",
        ]
        func normalize(_ value: JSONValue, key: String?) -> JSONValue {
            if let key, timestampKeys.contains(key), case .string = value {
                return .string("<ts>")
            }
            if key == "handle" || key == "parent", case .string(let handle) = value {
                return .string("item@" + (aliasByHandle[handle] ?? handle))
            }
            // Reservation ids embed the (per-store) handle; day+slot already
            // participate as their own fields.
            if key == "reservationId", case .string = value {
                return .string("<resid>")
            }
            switch value {
            case .object(let obj):
                var out: [String: JSONValue] = [:]
                for (k, v) in obj { out[k] = normalize(v, key: k) }
                return .object(out)
            case .array(let arr):
                return .array(arr.map { normalize($0, key: key) })
            default:
                return value
            }
        }
        return state.items.map { item in
            (try? normalize(item.toJSON(), key: nil).serialize(pretty: false)) ?? "<unserializable>"
        }
    }

    /// Drives one identical logical sequence through a store. Rich enough to
    /// exercise every ledger the base must carry: hierarchy, refs (with a
    /// deterministic refId for update_ref), cadence/notify, close+archive
    /// (retiring an alias), a pursuit with reservations, and — after the
    /// compacted twin's threshold has certainly been crossed — mutations that
    /// target base-carried items plus creates whose aliases must stay
    /// monotonic over the truncated history.
    private func drive(_ store: SwiftNativeDeskStore) async throws {
        let a = try await store.createItem(kind: .project, project: "atrium", title: "alpha")
        let a1 = try await store.addChild(parentHandle: a.handle, title: "alpha-child")
        let b = try await store.createItem(kind: .watch, project: "atrium", title: "beta")
        _ = try await store.setStatus(a.handle, status: .now)
        _ = try await store.appendNote(a.handle, text: "note-1")
        let ref = DeskRef(refId: "deskref_fixed_1", kind: .ghPr(repo: "o/r", number: 7, title: "pr", status: "open", checks: nil))
        _ = try await store.addRef(a.handle, ref: ref)
        _ = try await store.updateRef(a.handle, refId: "deskref_fixed_1", cachedFields: ["checks": .string("green")])
        _ = try await store.setCadence(a.handle, cadence: Cadence(mode: .daily))
        _ = try await store.setNotify(a.handle, policy: NotifyPolicy(level: .direct, on: ["state_change"]))

        // Pursuit draws alias 4 from the SAME top-level sequence as creates.
        let p = try await store.openPursuit(project: "workshop", title: "pursuit", pursuit: pursuitPayload())
        let res1 = try await store.reserveWorkSession(p.handle, day: "2026-07-15", slot: "morning")
        _ = try await store.completeWorkSession(p.handle, reservationId: res1, receipt: "did the thing")
        _ = try await store.appendWorkReceipt(p.handle, receipt: "extra receipt")

        // Retire beta's alias entirely: close + archive (leaves live state,
        // its create op is later compacted away — the alias must stay burned).
        _ = try await store.closeItem(b.handle, outcomeSummary: "beta done")
        _ = try await store.archiveItem(b.handle)

        // Churn well past the compacted twin's threshold (8).
        for n in 1...6 {
            let churn = try await store.createItem(kind: .watch, project: "churn", title: "churn-\(n)")
            _ = try await store.closeItem(churn.handle, outcomeSummary: "churn-\(n) done")
            _ = try await store.archiveItem(churn.handle)
        }

        // POST-COMPACTION phase (for the low-threshold twin): mutate items the
        // base carries, continue the alias sequence, exercise the CAS.
        let d = try await store.createItem(kind: .plan, project: "atrium", title: "delta")
        _ = try await store.setStatus(a.handle, status: .blocked, blockedReason: "waiting on CI", waitingOn: "owner")
        _ = try await store.appendNote(a1.handle, text: "child-note")
        _ = try await store.updateTitle(d.handle, title: "delta-renamed", summary: "delta summary")
        _ = try await store.markNotified(a.handle)

        // Reservation idempotency: same (handle, day, slot) → same id, no new
        // charge; a second slot fills the per-day cap; a third refuses.
        let resAgain = try await store.reserveWorkSession(p.handle, day: "2026-07-15", slot: "morning")
        #expect(resAgain == res1)
        _ = try await store.reserveWorkSession(p.handle, day: "2026-07-15", slot: "evening")
        do {
            _ = try await store.reserveWorkSession(p.handle, day: "2026-07-15", slot: "third")
            Issue.record("third same-day reservation must hit the per-pursuit cap")
        } catch let error as DeskError {
            guard case .workSessionCapReached = error else {
                throw error
            }
        }

        // markNotifiedIfUnchanged CAS: a stale expectation refuses, the
        // current one stamps.
        let liveA = try #require(try await store.liveState().items.first { $0.handle == a.handle })
        #expect(try await store.markNotifiedIfUnchanged(a.handle, expectedUpdatedAt: "stale") == false)
        #expect(try await store.markNotifiedIfUnchanged(a.handle, expectedUpdatedAt: liveA.updatedAt) == true)

        // Close the family (children first — hierarchy guards still apply on
        // base-carried items).
        _ = try await store.closeItem(a1.handle, outcomeSummary: "child done")
        _ = try await store.closeItem(a.handle, outcomeSummary: "alpha done")
    }

    @Test("compacted store is semantically identical to an uncompacted twin")
    func compactionPreservesSemantics() async throws {
        let rootA = try root(); defer { try? FileManager.default.removeItem(at: rootA) }
        let rootB = try root(); defer { try? FileManager.default.removeItem(at: rootB) }
        let uncompacted = store(rootA, threshold: 1_000_000)
        let compacted = store(rootB, threshold: 8)

        try await drive(uncompacted)
        try await drive(compacted)

        let stateA = try await uncompacted.liveState()
        let stateB = try await compacted.liveState()
        #expect(fingerprint(stateA) == fingerprint(stateB))
        #expect(!stateB.items.isEmpty)

        // The compacted feed is actually bounded and the base exists.
        #expect(opsLineCount(compacted) < 8)
        #expect(FileManager.default.fileExists(atPath: compacted.basePath.path))
        #expect(opsLineCount(uncompacted) > 8)
        #expect(!FileManager.default.fileExists(atPath: uncompacted.basePath.path))
    }

    @Test("alias monotonicity survives compaction — retired aliases never reused")
    func aliasLedgerSurvivesCompaction() async throws {
        let rootA = try root(); defer { try? FileManager.default.removeItem(at: rootA) }
        let rootB = try root(); defer { try? FileManager.default.removeItem(at: rootB) }
        let uncompacted = store(rootA, threshold: 1_000_000)
        let compacted = store(rootB, threshold: 4)

        for s in [uncompacted, compacted] {
            // Aliases 1...5 created; all closed+archived, so their create ops
            // are the ONLY memory of the burned aliases — and compaction
            // removes those ops from the low-threshold store's file.
            for n in 1...5 {
                let item = try await s.createItem(kind: .watch, project: "p", title: "old-\(n)")
                #expect(item.alias == "\(n)")
                _ = try await s.closeItem(item.handle, outcomeSummary: "done")
                _ = try await s.archiveItem(item.handle)
            }
            let fresh = try await s.createItem(kind: .watch, project: "p", title: "fresh")
            #expect(fresh.alias == "6", "alias must continue past every alias ever assigned, got \(fresh.alias)")
        }
        #expect(FileManager.default.fileExists(atPath: compacted.basePath.path))
        #expect(opsLineCount(compacted) < 5)
    }

    @Test("child alias sequence survives compaction under a live parent")
    func childAliasLedgerSurvives() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 6)
        let parent = try await s.createItem(kind: .project, project: "p", title: "parent")
        let c1 = try await s.addChild(parentHandle: parent.handle, title: "c1")
        let c2 = try await s.addChild(parentHandle: parent.handle, title: "c2")
        #expect(c1.alias == "1.1"); #expect(c2.alias == "1.2")
        _ = try await s.closeItem(c2.handle, outcomeSummary: "done")
        _ = try await s.archiveItem(c2.handle)
        // Churn to force compaction (child-2's create op leaves the file).
        for n in 1...4 {
            let churn = try await s.createItem(kind: .watch, project: "churn", title: "x-\(n)")
            _ = try await s.closeItem(churn.handle, outcomeSummary: "d")
            _ = try await s.archiveItem(churn.handle)
        }
        #expect(FileManager.default.fileExists(atPath: s.basePath.path))
        let c3 = try await s.addChild(parentHandle: parent.handle, title: "c3")
        #expect(c3.alias == "1.3", "archived child alias 1.2 must stay burned, got \(c3.alias)")
    }

    @Test("open_pursuit aliases count against the top-level sequence (collision fix)")
    func pursuitAliasNotReused() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 1_000_000)
        let p = try await s.openPursuit(project: "w", title: "pursuit", pursuit: pursuitPayload())
        #expect(p.alias == "1")
        let item = try await s.createItem(kind: .watch, project: "p", title: "after-pursuit")
        #expect(item.alias == "2", "createItem must not reuse the pursuit's alias, got \(item.alias)")
    }

    @Test("reconcile repair reopens to the pre-terminal status recorded before compaction")
    func lastNonTerminalSurvivesCompaction() async throws {
        let rootA = try root(); defer { try? FileManager.default.removeItem(at: rootA) }
        let rootB = try root(); defer { try? FileManager.default.removeItem(at: rootB) }

        for (dataRoot, threshold) in [(rootA, 1_000_000), (rootB, 6)] {
            let s = store(dataRoot, threshold: threshold)
            let parent = try await s.createItem(kind: .project, project: "p", title: "parent")
            _ = try await s.setStatus(parent.handle, status: .now)
            let child = try await s.addChild(parentHandle: parent.handle, title: "child")
            _ = child
            // Corrupt the feed the way a legacy writer could: a RAW terminal
            // close on the parent, bypassing the store's hierarchy guard.
            let persistence = SwiftNativePersistenceCore()
            let rawClose = DeskOp(handle: parent.handle, body: .closeItem(outcomeSummary: "wrongly closed", status: .done))
            try await persistence.appendJSONL(rawClose.toJSON(), to: s.opsPath)
            // Churn through the store so the low-threshold twin compacts with
            // the contradiction (and the parent's `.now` history) in the base.
            for n in 1...4 {
                let churn = try await s.createItem(kind: .watch, project: "churn", title: "x-\(n)")
                _ = try await s.closeItem(churn.handle, outcomeSummary: "d")
                _ = try await s.archiveItem(churn.handle)
            }
            if threshold < 100 {
                #expect(FileManager.default.fileExists(atPath: s.basePath.path))
            }
            let repairs = try await s.reconcileTerminalParentsWithNonTerminalDescendants()
            #expect(repairs.count == 1)
            let live = try #require(try await s.liveState().items.first { $0.handle == parent.handle })
            #expect(live.status == .now, "repair must reopen to the recorded pre-terminal status, got \(live.status.rawValue)")
        }
    }

    @Test("crash window between base write and truncate heals via prefix drop")
    func crashWindowHeals() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        // No compaction: build history, then hand-write a base covering ALL of
        // it while leaving the full op-log in place — exactly the state a crash
        // between base-write and truncate leaves behind.
        let s = store(root, threshold: 1_000_000)
        let a = try await s.createItem(kind: .project, project: "p", title: "alpha")
        _ = try await s.setStatus(a.handle, status: .now)
        let b = try await s.createItem(kind: .watch, project: "p", title: "beta")
        _ = try await s.appendNote(b.handle, text: "note")
        let before = try await s.liveState()

        let feed = try await s.readFeedUnlocked()
        let lastOp = try #require(feed.ops.last)
        let base = DeskCompactionBase(
            state: before,
            aliasHighWater: SwiftNativeDeskStore.foldAliasHighWater(seed: [:], ops: feed.ops),
            lastNonTerminal: SwiftNativeDeskStore.foldLastNonTerminal(seed: [:], ops: feed.ops),
            lastCompactedOpId: lastOp.opId,
            compactedAt: DeskClock.nowISO(),
            compactedOpCount: feed.fileOpCount
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.writeJSON(base.toJSON(), to: s.basePath)

        // Full stale op-log + covering base: replay must NOT double-apply.
        let healed = try await s.liveState()
        #expect(fingerprint(healed) == fingerprint(before))
        // And the store keeps working on top of the healed feed.
        let c = try await s.createItem(kind: .watch, project: "p", title: "gamma")
        #expect(c.alias == "3")
        let after = try await s.liveState()
        #expect(after.items.count == before.items.count + 1)
    }

    @Test("second compaction keeps operating on top of the first")
    func secondCompactionWorks() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 6)
        try await drive(s)
        let baseAfterFirst = try Data(contentsOf: s.basePath)

        for n in 1...8 {
            _ = try await s.createItem(kind: .watch, project: "wave2", title: "w2-\(n)")
        }
        let state = try await s.liveState()
        #expect(state.items.filter { $0.project == "wave2" }.count == 8)
        let baseAfterSecond = try Data(contentsOf: s.basePath)
        #expect(baseAfterFirst != baseAfterSecond)
        #expect(opsLineCount(s) < 6)
    }

    @Test("a base file that exists but does not decode fails loud, never a blank desk")
    func corruptBaseFailsLoud() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 4)
        for n in 1...5 {
            _ = try await s.createItem(kind: .watch, project: "p", title: "item-\(n)")
        }
        #expect(FileManager.default.fileExists(atPath: s.basePath.path))
        try Data("{\"not\": \"a base\"}".utf8).write(to: s.basePath)
        do {
            _ = try await s.liveState()
            Issue.record("liveState over a corrupt base must throw, not silently blank the desk")
        } catch let error as DeskError {
            guard case .compactionBaseCorrupt = error else { throw error }
        }
    }

    @Test("a base item whose nested collection is wrong-typed is corrupt, not empty")
    func wrongTypedNestedCollectionFailsLoud() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 4)
        let item = try await s.createItem(kind: .watch, project: "p", title: "with-ref")
        _ = try await s.addRef(item.handle, ref: DeskRef(refId: "deskref_x", kind: .note(text: "n")))
        for n in 1...4 {
            _ = try await s.createItem(kind: .watch, project: "p", title: "churn-\(n)")
        }
        #expect(FileManager.default.fileExists(atPath: s.basePath.path))
        // Corrupt ONE nested collection in the base: refs becomes a string.
        // Tolerant decode would silently read it as "no refs" and the desk
        // would keep operating on a shrunken item — strict mode must throw.
        var baseJSON = try JSONValue.parse(Data(contentsOf: s.basePath))
        guard case .object(var baseObj) = baseJSON,
              case .object(var stateObj)? = baseObj["state"],
              case .array(var rows)? = stateObj["items"] else {
            Issue.record("base file shape unexpected"); return
        }
        var mangledOne = false
        for (i, row) in rows.enumerated() {
            guard case .object(var itemObj) = row, itemObj["refs"] != nil else { continue }
            itemObj["refs"] = .string("oops")
            rows[i] = .object(itemObj)
            mangledOne = true
            break
        }
        #expect(mangledOne, "test setup must actually hit a refs array in the base")
        stateObj["items"] = .array(rows)
        baseObj["state"] = .object(stateObj)
        baseJSON = .object(baseObj)
        try baseJSON.serializedData(pretty: true).write(to: s.basePath)
        do {
            _ = try await s.liveState()
            Issue.record("wrong-typed refs in the base must throw, not decode as empty")
        } catch let error as DeskError {
            guard case .compactionBaseCorrupt = error else { throw error }
        }
    }

    @Test("round-trip gate catches tolerant-decode loss anywhere in the base tree")
    func roundTripGateCatchesDeepToleratedLoss() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 4)
        let item = try await s.createItem(kind: .watch, project: "p", title: "notify-item")
        _ = try await s.setNotify(item.handle, policy: NotifyPolicy(level: .direct, on: ["state_change"]))
        for n in 1...4 {
            _ = try await s.createItem(kind: .watch, project: "p", title: "churn-\(n)")
        }
        #expect(FileManager.default.fileExists(atPath: s.basePath.path))
        // Corrupt a field the per-collection strict checks DON'T cover:
        // notify.on becomes a wrong-typed value. jsonStringArray tolerantly
        // decodes it to [] — only the round-trip re-encode mismatch can
        // detect it. The desk must fail loud, not silently lose the policy.
        var baseJSON = try JSONValue.parse(Data(contentsOf: s.basePath))
        guard case .object(var baseObj) = baseJSON,
              case .object(var stateObj)? = baseObj["state"],
              case .array(var rows)? = stateObj["items"] else {
            Issue.record("base file shape unexpected"); return
        }
        var mangledOne = false
        for (i, row) in rows.enumerated() {
            guard case .object(var itemObj) = row,
                  case .object(var notifyObj)? = itemObj["notify"],
                  notifyObj["on"] != nil else { continue }
            notifyObj["on"] = .string("oops")
            itemObj["notify"] = .object(notifyObj)
            rows[i] = .object(itemObj)
            mangledOne = true
            break
        }
        #expect(mangledOne, "test setup must actually hit a notify.on array in the base")
        stateObj["items"] = .array(rows)
        baseObj["state"] = .object(stateObj)
        baseJSON = .object(baseObj)
        try baseJSON.serializedData(pretty: true).write(to: s.basePath)
        do {
            _ = try await s.liveState()
            Issue.record("wrong-typed notify.on in the base must throw, not decode as empty")
        } catch let error as DeskError {
            guard case .compactionBaseCorrupt = error else { throw error }
        }
    }

    @Test("commit-stamp Lamport floor includes the base once the tail is empty")
    func maxCommittedTsFloorsOnBase() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 4)
        for n in 1...5 {
            _ = try await s.createItem(kind: .watch, project: "p", title: "item-\(n)")
        }
        let feed = try await s.readFeedUnlocked()
        let base = try #require(feed.base)
        // Whatever tail remains, the floor can never be older than the base.
        let floor = try #require(feed.maxCommittedTs)
        #expect(floor >= base.state.generatedTs)
        let emptyTail = DeskFeed(base: base, ops: [], fileOpCount: 0)
        #expect(emptyTail.maxCommittedTs == base.state.generatedTs)
    }

    @Test("closeItemIfUnchanged closes only the exact planned version")
    func closeItemIfUnchangedIsAtomic() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let s = store(root, threshold: 1_000_000)
        let item = try await s.createItem(kind: .watch, project: "p", title: "sweep-me")
        let planned = try #require(try await s.liveState().items.first { $0.handle == item.handle }?.updatedAt)

        // A stale stamp (the row moved since planning) refuses without an op.
        let staleClose = try await s.closeItemIfUnchanged(
            item.handle, expectedUpdatedAt: planned + "-stale", outcomeSummary: "swept"
        )
        #expect(staleClose == false)
        #expect(try await s.liveState().items.first { $0.handle == item.handle }?.status.isTerminal == false)

        // The exact planned stamp closes.
        let closed = try await s.closeItemIfUnchanged(
            item.handle, expectedUpdatedAt: planned, outcomeSummary: "swept"
        )
        #expect(closed == true)
        let after = try #require(try await s.liveState().items.first { $0.handle == item.handle })
        #expect(after.status == .done)
        #expect(after.summary == "swept")

        // A replay against the now-terminal row refuses too.
        let replay = try await s.closeItemIfUnchanged(
            item.handle, expectedUpdatedAt: planned, outcomeSummary: "swept again"
        )
        #expect(replay == false)
    }
}
