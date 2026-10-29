import Foundation
// Blueprint: | `DetachedCloudKitTimeoutRace.swift` | Detached CloudKit race and diagnostic `withCKTimeout` optional-result policy |

/// Diagnostic calls return no value on invalid duration, failure, timeout or cancellation.
public func withCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let message: String
    if seconds.isFinite, seconds >= 0,
       let nanoseconds = UInt64(exactly: (seconds * 1_000_000_000).rounded(.towardZero)) {
        let state = ContinuationOnce<Result<T, Error>?>()
        let workTask = Task<Void, Never>.detached(priority: .utility) {
            do {
                state.resume(.success(try await work()))
            } catch {
                state.resume(.failure(error))
            }
        }
        switch await state.cloudKitRace(workTask: workTask, timeoutNanoseconds: nanoseconds) {
        case .success(let value): return value
        case .failure(let error): message = "[ck-landmine] \(label) failed: \(error)"
        case .timedOut:
            #if os(iOS)
            let duration = "\(seconds)s"
            #else
            let duration = formatCKTimeoutSeconds(seconds)
            #endif
            message = "[ck-landmine] \(label) timed out after \(duration); cloudd unhealthy?"
        case .cancelled: return nil
        }
    } else {
        #if os(iOS)
        message = "[ck-landmine] \(label) has an invalid timeout: \(seconds)"
        #else
        message = "[ck-landmine] \(label) rejected an invalid timeout: \(seconds)"
        #endif
    }
    #if os(iOS)
    NSLog("%@", message)
    #else
    nativeLog(message)
    #endif
    return nil
}

func formatCKTimeoutSeconds(_ seconds: TimeInterval) -> String {
    if seconds.rounded() == seconds { return "\(Int(seconds))s" }
    return String(format: "%.1fs", seconds)
}
