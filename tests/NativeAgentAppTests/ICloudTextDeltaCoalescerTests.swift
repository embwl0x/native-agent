import Testing
@testable import NativeAgentApp

@Test
func textDeltaCoalescerFlushesFirstDeltaImmediately() {
    var coalescer = ICloudTextDeltaCoalescer(
        minIntervalNanoseconds: 1_000,
        minCharactersBetweenFlushes: 10,
        maxCharactersBetweenFlushes: 50
    )

    let flush = coalescer.push(snapshot: "A", nowUptimeNanoseconds: 100)
    #expect(flush?.sequence == 1)
    #expect(flush?.text == "A")
    #expect(flush?.reason == .first)
}

@Test
func textDeltaCoalescerBatchesSmallChunksUntilIntervalAndSizeThresholdsPass() {
    var coalescer = ICloudTextDeltaCoalescer(
        minIntervalNanoseconds: 1_000,
        minCharactersBetweenFlushes: 10,
        maxCharactersBetweenFlushes: 50
    )

    _ = coalescer.push(snapshot: "A", nowUptimeNanoseconds: 100)
    #expect(coalescer.push(snapshot: "ABCDEFGHIJK", nowUptimeNanoseconds: 500) == nil)

    let flush = coalescer.push(snapshot: "ABCDEFGHIJK", nowUptimeNanoseconds: 1_100)
    #expect(flush?.sequence == 2)
    #expect(flush?.text == "ABCDEFGHIJK")
    #expect(flush?.reason == .interval)
}

@Test
func textDeltaCoalescerFlushesLargeSnapshotsWithoutWaitingForInterval() {
    var coalescer = ICloudTextDeltaCoalescer(
        minIntervalNanoseconds: 10_000,
        minCharactersBetweenFlushes: 10,
        maxCharactersBetweenFlushes: 12
    )

    _ = coalescer.push(snapshot: "A", nowUptimeNanoseconds: 100)
    let flush = coalescer.push(snapshot: "ABCDEFGHIJKLM", nowUptimeNanoseconds: 101)
    #expect(flush?.sequence == 2)
    #expect(flush?.reason == .size)
}

@Test
func textDeltaCoalescerForceFlushesPendingTextOnce() {
    var coalescer = ICloudTextDeltaCoalescer(
        minIntervalNanoseconds: 10_000,
        minCharactersBetweenFlushes: 10,
        maxCharactersBetweenFlushes: 50
    )

    _ = coalescer.push(snapshot: "A", nowUptimeNanoseconds: 100)
    #expect(coalescer.push(snapshot: "ABC", nowUptimeNanoseconds: 101) == nil)

    let forced = coalescer.flush(nowUptimeNanoseconds: 102)
    #expect(forced?.sequence == 2)
    #expect(forced?.text == "ABC")
    #expect(forced?.reason == .forced)
    #expect(coalescer.flush(nowUptimeNanoseconds: 103) == nil)
}
