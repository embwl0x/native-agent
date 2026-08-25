import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / icloud.sendKVSChatProgress
@MainActor
@Suite("iCloud KVS chat-progress quota admission")
struct ICloudKVSChatProgressQuotaEvalTests {
    private let progressKey = "chat_progress_latest"

    private func keys(_ count: Int, prefix: String = "other_") -> Set<String> {
        Set((0..<count).map { "\(prefix)\($0)" })
    }

    @Test("a new progress key preserves the KVS headroom below the hard quota")
    func newProgressKeyStopsAtTheHeadroomCeiling() {
        let justBelowCeiling = ICloudKVSProgressWriteAdmission.assess(
            keys: keys(ICloudKVSProgressWriteAdmission.totalKeyCeiling - 1),
            progressKey: progressKey
        )
        #expect(justBelowCeiling.isAllowed)
        #expect(justBelowCeiling.snapshot.totalKeyCount + 1 == ICloudKVSProgressWriteAdmission.totalKeyCeiling)

        let atCeiling = ICloudKVSProgressWriteAdmission.assess(
            keys: keys(ICloudKVSProgressWriteAdmission.totalKeyCeiling),
            progressKey: progressKey
        )
        #expect(atCeiling == .keyspaceAtHeadroomLimit(atCeiling.snapshot))
        #expect(!atCeiling.isAllowed)
        #expect(ICloudKVSProgressWriteAdmission.totalKeyCeiling < ICloudKVSProgressWriteAdmission.hardKeyQuota)
    }

    @Test("an overwrite remains safe but an over-ceiling response sweep is visible")
    func overwriteAndResponseSweepCapacityAreDistinguished() {
        var overwriteKeys = keys(ICloudKVSProgressWriteAdmission.totalKeyCeiling - 1)
        overwriteKeys.insert(progressKey)
        let overwrite = ICloudKVSProgressWriteAdmission.assess(keys: overwriteKeys, progressKey: progressKey)
        #expect(overwrite.isAllowed)
        #expect(overwrite.snapshot.totalKeyCount == ICloudKVSProgressWriteAdmission.totalKeyCeiling)

        var overloadedResponses = keys(5)
        for index in 0...ICloudKVSProgressWriteAdmission.inboxResponseKeyCeiling {
            overloadedResponses.insert("inbox_response_\(index)")
        }
        let responseOverflow = ICloudKVSProgressWriteAdmission.assess(
            keys: overloadedResponses,
            progressKey: progressKey
        )
        #expect(responseOverflow.snapshot.inboxResponseKeyCount == ICloudKVSProgressWriteAdmission.inboxResponseKeyCeiling + 1)
        #expect(responseOverflow == .responseSweepOverCeiling(responseOverflow.snapshot))
        #expect(responseOverflow.failureDescription?.contains("800") == true)
        #expect(MacSyncEngine.shared.inboxResponseKeyPrefix == ICloudKVSProgressWriteAdmission.inboxResponseKeyPrefix)
        #expect(MacSyncEngine.shared.inboxResponseKeyMaxCount == ICloudKVSProgressWriteAdmission.inboxResponseKeyCeiling)
    }
}
