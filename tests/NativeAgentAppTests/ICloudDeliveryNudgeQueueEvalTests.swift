import Foundation
import Testing
@testable import NativeAgentApp

private actor RecordingDeliveryNudgeKVS {
    private var messageIDs: [String] = []

    func setAndSynchronize(messageID: String) -> Bool {
        messageIDs.append(messageID)
        return true
    }

    func sentMessageIDs() -> [String] { messageIDs }
}

@Suite("iCloud delivery nudge queue", .serialized)
struct ICloudDeliveryNudgeQueueEvalTests {
    // Coverage ledger: app.bridges / icloud.deliveryNudges
    @Test("each outbound message issues every declared KVS nudge and accounts for an unavailable bridge")
    func deliveryNudgesWriteOrRecordTheirSuppression() async {
        let kvs = RecordingDeliveryNudgeKVS()
        let healthy = ICloudDeliveryNudgeQueue(
            automaticallyRun: false,
            isAvailable: { true },
            sendNudge: { messageID in
                await kvs.setAndSynchronize(messageID: messageID)
            }
        )

        await healthy.schedule(for: "message-1")
        let planned = await healthy.snapshot()
        #expect(planned.plannedCount == ICloudDeliveryNudgePlan.delaysNanoseconds.count)
        #expect(planned.pendingCount == ICloudDeliveryNudgePlan.delaysNanoseconds.count)

        await healthy.drainImmediatelyForTesting()
        let delivered = await healthy.snapshot()
        #expect(delivered.synchronizedCount == ICloudDeliveryNudgePlan.delaysNanoseconds.count)
        #expect(delivered.unavailableCount == 0)
        #expect(delivered.failedCount == 0)
        #expect(await kvs.sentMessageIDs() == Array(
            repeating: "message-1",
            count: ICloudDeliveryNudgePlan.delaysNanoseconds.count
        ))

        let unavailableKVS = RecordingDeliveryNudgeKVS()
        let unavailable = ICloudDeliveryNudgeQueue(
            automaticallyRun: false,
            isAvailable: { false },
            sendNudge: { messageID in
                await unavailableKVS.setAndSynchronize(messageID: messageID)
            }
        )
        await unavailable.schedule(for: "message-2")
        await unavailable.drainImmediatelyForTesting()
        let suppressed = await unavailable.snapshot()
        #expect(suppressed.unavailableCount == ICloudDeliveryNudgePlan.delaysNanoseconds.count)
        #expect(suppressed.synchronizedCount == 0)
        #expect((await unavailableKVS.sentMessageIDs()).isEmpty)

        let failed = ICloudDeliveryNudgeQueue(
            automaticallyRun: false,
            isAvailable: { true },
            sendNudge: { _ in false }
        )
        await failed.schedule(for: "message-3")
        await failed.drainImmediatelyForTesting()
        let failure = await failed.snapshot()
        #expect(failure.failedCount == ICloudDeliveryNudgePlan.delaysNanoseconds.count)
        #expect(failure.synchronizedCount == 0)
    }

    @Test("an outbound burst retains every planned nudge behind one worker")
    func deliveryNudgeBurstDoesNotCreateUnboundedSleepingTasks() async {
        let queue = ICloudDeliveryNudgeQueue(
            delaysNanoseconds: [60_000_000_000, 120_000_000_000],
            isAvailable: { true },
            sendNudge: { _ in true }
        )

        for index in 0..<80 {
            await queue.schedule(for: "burst-\(index)")
        }
        let scheduled = await queue.snapshot()
        #expect(scheduled.plannedCount == 160)
        #expect(scheduled.pendingCount == 160)
        #expect(scheduled.activeWorkerCount == 1)
        #expect(scheduled.workerStartCount == 1)

        await queue.cancelAll()
        #expect((await queue.snapshot()).pendingCount == 0)
    }
}
