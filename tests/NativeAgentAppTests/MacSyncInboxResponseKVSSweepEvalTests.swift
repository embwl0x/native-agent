import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / macsync.inboxResponseKVSSweep

@Suite("MacSync inbox response KVS sweep")
struct MacSyncInboxResponseKVSSweepEvalTests {
    @Test("a fake KVS removes expired and orphaned notifications before bounded malformed eviction")
    @MainActor
    func sweepsQuotaPressureWithoutDroppingFreshReadableResponses() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prefix = MacSyncEngine.shared.inboxResponseKeyPrefix
        let ceiling = MacSyncEngine.shared.inboxResponseKeyMaxCount
        let ttl = MacSyncEngine.shared.inboxResponseKeyTTL
        var fakeKVS: [String: String] = [:]
        var entries: [MacSyncInboxResponseSweep.Entry] = []

        for index in 0..<799 {
            let key = "\(prefix)fresh-\(index)"
            fakeKVS[key] = "notification"
            entries.append(.init(key: key, modified: now.addingTimeInterval(-60), exists: true))
        }
        for index in 0..<2 {
            let key = "\(prefix)expired-\(index)"
            fakeKVS[key] = "notification"
            entries.append(.init(key: key, modified: now.addingTimeInterval(-ttl - 1), exists: true))
        }
        for index in 0..<2 {
            let key = "\(prefix)orphan-\(index)"
            fakeKVS[key] = "notification"
            entries.append(.init(key: key, modified: nil, exists: false))
        }
        for index in 0..<2 {
            let key = "\(prefix)unreadable-\(index)"
            fakeKVS[key] = "notification"
            entries.append(.init(key: key, modified: nil, exists: true))
        }

        let plan = MacSyncInboxResponseSweep.plan(entries: entries, now: now, ttl: ttl, cap: ceiling)

        #expect(plan.retainedCount == ceiling)
        #expect(!plan.exceedsCap)
        #expect(Set(plan.keysToRemove) == Set([
            "\(prefix)expired-0",
            "\(prefix)expired-1",
            "\(prefix)orphan-0",
            "\(prefix)orphan-1",
            "\(prefix)unreadable-0",
        ]))

        MacSyncInboxResponseSweep.apply(plan) { key in
            fakeKVS.removeValue(forKey: key)
        }

        #expect(fakeKVS.count == ceiling)
        #expect((0..<799).allSatisfy { fakeKVS["\(prefix)fresh-\($0)"] == "notification" })
        #expect(fakeKVS["\(prefix)unreadable-1"] == "notification")
        #expect(plan.keysToRemove.allSatisfy { fakeKVS[$0] == nil })
    }

    @Test("recent readable pressure is reported without silently discarding a pending notification")
    @MainActor
    func leavesUnsatisfiableFreshOnlyPressureVisibleAndUntouched() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prefix = MacSyncEngine.shared.inboxResponseKeyPrefix
        let ceiling = MacSyncEngine.shared.inboxResponseKeyMaxCount
        var fakeKVS: [String: String] = [:]
        let entries = (0...ceiling).map { index -> MacSyncInboxResponseSweep.Entry in
            let key = "\(prefix)fresh-\(index)"
            fakeKVS[key] = "notification"
            return .init(key: key, modified: now.addingTimeInterval(-60), exists: true)
        }

        let plan = MacSyncInboxResponseSweep.plan(
            entries: entries,
            now: now,
            ttl: MacSyncEngine.shared.inboxResponseKeyTTL,
            cap: ceiling
        )
        MacSyncInboxResponseSweep.apply(plan) { key in
            fakeKVS.removeValue(forKey: key)
        }

        #expect(plan.keysToRemove.isEmpty)
        #expect(plan.exceedsCap)
        #expect(plan.retainedCount == ceiling + 1)
        #expect(fakeKVS.count == ceiling + 1)
    }
}
