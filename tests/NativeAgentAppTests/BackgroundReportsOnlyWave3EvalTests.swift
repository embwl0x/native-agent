import Foundation
import Testing
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private func backgroundWave3Root(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundReportsOnlyWave3-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func backgroundWave3InboxPath(_ root: URL) -> URL {
    root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
}

private func backgroundWave3Files(_ root: URL) throws -> [String: Data] {
    let urls = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        .sorted()
        .map { root.appendingPathComponent($0) }
    return try Dictionary(uniqueKeysWithValues: urls.compactMap { url in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return (url.path.replacingOccurrences(of: root.path + "/", with: ""), try Data(contentsOf: url))
    })
}

private actor BackgroundWave3DeliveryProbe {
    private(set) var macCalls = 0
    private(set) var pairedCalls = 0

    func mac(_ success: Bool) -> Bool {
        macCalls += 1
        return success
    }

    func paired(_ success: Bool) -> Bool {
        pairedCalls += 1
        return success
    }

}

@Suite("app.background reports-only wave 3", .serialized)
struct BackgroundReportsOnlyWave3EvalTests {
    @Test("desk notifications deliver, settle once, and surface a partial delivery failure")
    func deskNotifyLifecycleAndFailure() async throws {
        let inertRoot = try backgroundWave3Root("desk-inert")
        defer { try? FileManager.default.removeItem(at: inertRoot) }
        let inertStore = SwiftNativeDeskStore(dataRoot: inertRoot)
        _ = try await inertStore.createItem(kind: .watch, project: "eval", title: "Ordinary item")
        let beforeInertTick = try backgroundWave3Files(inertRoot)
        let inert = BackgroundLoopsAssembly.makeDeskNotifyLoop(
            dataRoot: inertRoot,
            postMacNotification: { _, _ in Issue.record("ordinary Desk item must not notify"); return false },
            postPairedDeviceNotification: { _, _ in Issue.record("ordinary Desk item must not notify"); return false }
        )
        let inertOutcome = await inert.tickOutcome()
        #expect(inertOutcome == .skipped(reason: "no Desk notification due"))
        #expect(try backgroundWave3Files(inertRoot) == beforeInertTick,
                "a no-delivery ordinary item must not create or mutate any state files")

        let root = try backgroundWave3Root("desk")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .watch, project: "eval", title: "Ship this receipt")
        _ = try await store.setNotify(item.handle, policy: NotifyPolicy(level: .direct))

        let delivered = BackgroundWave3DeliveryProbe()
        let healthyLoop = BackgroundLoopsAssembly.makeDeskNotifyLoop(
            dataRoot: root,
            postMacNotification: { _, _ in await delivered.mac(true) },
            postPairedDeviceNotification: { _, _ in await delivered.paired(true) }
        )
        let first = await healthyLoop.tickOutcome()
        guard case .completed(let result) = first else {
            Issue.record("expected completed delivery, got \(first)")
            return
        }
        #expect(result?.contains("sent 1 Desk notification") == true)
        #expect(await delivered.macCalls == 1)
        #expect(await delivered.pairedCalls == 1)
        #expect((try await store.liveState()).items.first { $0.handle == item.handle }?.notify.lastNotifiedAt != nil)

        let second = await healthyLoop.tickOutcome()
        guard case .skipped(let reason, let healthNeutral) = second else {
            Issue.record("expected idempotent no-op after the durable stamp, got \(second)")
            return
        }
        #expect(reason == "no Desk notification due")
        #expect(!healthNeutral)
        #expect(await delivered.macCalls == 1)

        _ = try await store.setNotify(item.handle, policy: NotifyPolicy(level: .urgent))
        let failed = BackgroundWave3DeliveryProbe()
        let failingLoop = BackgroundLoopsAssembly.makeDeskNotifyLoop(
            dataRoot: root,
            postMacNotification: { _, _ in await failed.mac(false) },
            postPairedDeviceNotification: { _, _ in await failed.paired(true) }
        )
        let failure = await failingLoop.tickOutcome()
        guard case .failed(let error) = failure else {
            Issue.record("a failed banner delivery must fail the loop, got \(failure)")
            return
        }
        #expect(error.contains("Mac banner"))
        #expect(await failed.macCalls == 1)
        #expect(await failed.pairedCalls == 1)
    }

    @Test("granted Speech permission retires only the live card and corrupt inbox bytes fail closed")
    func systemPermissionCardRetirement() async throws {
        let root = try backgroundWave3Root("speech-card")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = backgroundWave3InboxPath(root)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.appendJSONL(.object([
            "id": .string(BackgroundLoopsAssembly.systemPermissionsSpeechCardId),
            "status": .string("unread"),
            "title": .string("Speech Recognition is not approved"),
        ]), to: inbox)
        try await persistence.appendJSONL(.object([
            "id": .string("unrelated"),
            "status": .string("unread"),
        ]), to: inbox)

        await BackgroundLoopsAssembly.retireSystemPermissionCardIfGranted(
            dataRoot: root,
            permissionStatus: { .unknown }
        )
        var rows = try await persistence.readJSONL(inbox)
        guard case .object(let unknownCard)? = rows.first else {
            Issue.record("missing seeded speech card")
            return
        }
        #expect(unknownCard["status"] == .string("unread"))

        await BackgroundLoopsAssembly.retireSystemPermissionCardIfGranted(
            dataRoot: root,
            permissionStatus: { .denied }
        )
        rows = try await persistence.readJSONL(inbox)
        guard case .object(let deniedCard)? = rows.first else {
            Issue.record("missing seeded speech card")
            return
        }
        #expect(deniedCard["status"] == .string("unread"))

        await BackgroundLoopsAssembly.retireSystemPermissionCardIfGranted(
            dataRoot: root,
            permissionStatus: { .granted }
        )
        rows = try await persistence.readJSONL(inbox)
        guard case .object(let grantedCard)? = rows.first,
              case .object(let unrelated)? = rows.dropFirst().first else {
            Issue.record("expected both inbox rows after retirement")
            return
        }
        #expect(grantedCard["status"] == .string("archived"))
        #expect(grantedCard["read_at"] != nil)
        #expect(unrelated["status"] == .string("unread"))

        let corruptRoot = try backgroundWave3Root("speech-corrupt")
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptInbox = backgroundWave3InboxPath(corruptRoot)
        try FileManager.default.createDirectory(at: corruptInbox.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{not-json}\n".utf8)
        try original.write(to: corruptInbox)
        await BackgroundLoopsAssembly.retireSystemPermissionCardIfGranted(
            dataRoot: corruptRoot,
            permissionStatus: { .granted }
        )
        #expect(try Data(contentsOf: corruptInbox) == original,
                "a corrupt authority inbox must be preserved, never replaced with an empty healthy state")
    }

    @Test("dream receipt backfill archives an older receipt and remains restart-idempotent")
    func schedulerDreamReceiptBackfill() async throws {
        let root = try backgroundWave3Root("scheduler")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dateKey = NativeAgentDreamCycleSchedule.dreamEntryDateKey(now)
        let diary = root.appendingPathComponent("dream_diary", isDirectory: true)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        try Data("# Dream\n**A durable test dream**\nThe receipt is visible.\n".utf8)
            .write(to: diary.appendingPathComponent("\(dateKey).md"))

        let runner = SchedulerDueJobRunner(
            root: root,
            cycleNotificationDelivery: { _, _, _, _, _ in
                .object(["delivered": .array([]), "errors": .array([])])
            }
        )
        // The current dream's diary key is yesterday's Central date.  Seed
        // this receipt two calendar days behind `now` so it is eligible for
        // archival without falsely satisfying today's duplicate guard.
        let older = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 2 * 86_400)
        try await SwiftNativePersistenceCore().appendJSONL(.object([
            "id": .string("dream-cycle-old"),
            "created_at": .string(SchedulerDueJobRunner.iso(older)),
            "source": .string("dream_cycle"),
            "severity": .string("important"),
            "title": .string("Older dream"),
            "summary": .string("An older receipt that must retire."),
            "status": .string("unread"),
            "read_at": .null,
            "actions": .array([]),
        ]), to: backgroundWave3InboxPath(root))
        let itemID = try #require(await runner.backfillDreamReceiptIfNeeded(now: now))
        #expect(itemID == "dream-cycle-\(dateKey)-backfill")
        let duplicate = try await runner.backfillDreamReceiptIfNeeded(now: now)
        #expect(duplicate == nil,
                "a restart/retry must not append a duplicate dream receipt")

        let persistence = SwiftNativePersistenceCore()
        let inboxRows = try await persistence.readJSONL(backgroundWave3InboxPath(root))
        #expect(inboxRows.count == 2)
        guard case .object(let inbox)? = inboxRows.first(where: { row in
            guard case .object(let object) = row else { return false }
            return object["id"] == .string(itemID)
        }), case .object(let archivedOlder)? = inboxRows.first(where: { row in
            guard case .object(let object) = row else { return false }
            return object["id"] == .string("dream-cycle-old")
        }) else {
            Issue.record("missing current or archived older dream receipt")
            return
        }
        #expect(inbox["id"] == .string(itemID))
        #expect(inbox["source"] == .string("dream_cycle"))
        #expect(archivedOlder["status"] == .string("archived"),
                "a newly backfilled receipt retires an older visible dream receipt")
    }
}
