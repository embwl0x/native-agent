import Testing
@testable import NativeAgentApp

@Test func latestAsyncRequestGateRejectsOlderSuspendedWork() {
    var gate = LatestAsyncRequestGate()
    let first = gate.begin()
    #expect(gate.accepts(first))

    let second = gate.begin()
    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))
}
