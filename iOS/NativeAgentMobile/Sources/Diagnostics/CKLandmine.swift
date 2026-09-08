// Diagnostic optional-result API and iOS timeout wording; Shared owns the race.
import Foundation
import NativeAgentShared

// 2026-09-07: the timeout latch lives in NativeAgentShared (CloudKitTimeoutResultLatch)
// so the cancellation-before-registration fix is one implementation for Mac, device
// transport and iOS.

func withCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)

    switch await detachedCloudKitTimeoutRace(timeoutNanoseconds: timeoutNanoseconds, work) {
    case .success(let value):
        return value
    case .failure(let error):
        NSLog("[ck-landmine] \(label) failed: \(error)")
        return nil
    case .timedOut:
        NSLog("[ck-landmine] \(label) timed out after \(Int(seconds))s; cloudd unhealthy?")
        return nil
    case .cancelled:
        return nil
    }
}
