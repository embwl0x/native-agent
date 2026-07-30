import Foundation
#if canImport(Security)
import Security
#endif

// 2026-06-07 task #88 follow-up: the old wording ("unavailable — provisioning
// profile lacks CloudKit capability") made it look like all of iCloud sync
// was broken. In practice the CloudKit *database* path is hard-disabled by
// design (the launch landmine), but KVS sync and iCloud Drive document
// containers run on independent entitlements that DO work. Be honest about
// what's off without alarming the user about iCloud sync as a whole.
let nativeAgentCloudKitDisabledStatus = "DB sync off (KVS sync active)"

func nativeAgentCloudKitAccountProbeEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hasCloudKitEntitlement: @Sendable () -> Bool = nativeAgentHasCloudKitServiceEntitlement
) -> Bool {
    let raw = (environment["NATIVE_AGENT_ENABLE_CLOUDKIT"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard raw == "1" || raw == "true" || raw == "yes" else { return false }
    return hasCloudKitEntitlement()
}

func nativeAgentHasCloudKitServiceEntitlement() -> Bool {
    #if canImport(Security)
    guard let task = SecTaskCreateFromSelf(nil),
          let raw = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
          ) else {
        return false
    }
    if let services = raw as? [String] {
        return services.contains { $0.caseInsensitiveCompare("CloudKit") == .orderedSame }
    }
    if let service = raw as? String {
        return service.caseInsensitiveCompare("CloudKit") == .orderedSame
    }
    return false
    #else
    return false
    #endif
}

private enum CKTimeoutRace<T: Sendable>: Sendable {
    case success(T)
    case failure(String)
    // gpt-5.5 review fix: typed-Error variant lets the throwing wrapper
    // re-throw the original CK error (conflict / quota / unauthorized)
    // instead of collapsing into a generic timeout.
    case failureError(Error)
    case timedOut
    case cancelled
}

private actor CKTimeoutState<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>?, Never>?

    func wait() async -> Result<T, Error>? {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancelWaiter() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

func withCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let state = CKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)

    let workTask = Task.detached(priority: .utility) {
        do {
            await state.finish(.success(try await work()))
        } catch {
            await state.finish(.failure(error))
        }
    }

    return await withTaskGroup(of: CKTimeoutRace<T>.self, returning: T?.self) { group in
        group.addTask {
            guard let result = await state.wait() else {
                return .cancelled
            }
            switch result {
            case .success(let value):
                return .success(value)
            case .failure(let error):
                return .failure(String(describing: error))
            }
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            } catch {
                return .cancelled
            }
        }

        guard let first = await group.next() else {
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return nil
        }

        switch first {
        case .success(let value):
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return value
        case .failure(let error):
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            NSLog("[ck-landmine] \(label) failed: \(error)")
            return nil
        case .failureError(let error):
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            NSLog("[ck-landmine] \(label) failed: \(error)")
            return nil
        case .timedOut:
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            NSLog("[ck-landmine] \(label) timed out after \(formatCKTimeoutSeconds(seconds)); cloudd unhealthy?")
            return nil
        case .cancelled:
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return nil
        }
    }
}

private func formatCKTimeoutSeconds(_ seconds: TimeInterval) -> String {
    if seconds.rounded() == seconds {
        return "\(Int(seconds))s"
    }
    return String(format: "%.1fs", seconds)
}

/// Throwing variant — propagates the work's thrown error instead of masking it
/// to nil. Use this when the caller wants to distinguish a real CloudKit error
/// (conflict, quota, unauthorized) from a "cloudd unhealthy" timeout, so the
/// existing conflict / retry paths still run. On timeout, throws
/// `CKLandmineTimeout`. On work failure, rethrows the original error.
struct CKLandmineTimeout: LocalizedError, Sendable {
    let label: String
    let seconds: TimeInterval
    var errorDescription: String? {
        "CK call \(label) timed out after \(seconds)s; cloudd unhealthy?"
    }
}

func withCKTimeoutThrowing<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    let state = CKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)

    let workTask = Task.detached(priority: .utility) {
        do {
            await state.finish(.success(try await work()))
        } catch {
            await state.finish(.failure(error))
        }
    }

    // Reuse the existing module-private CKTimeoutRace<T> enum (nested generic
    // type declarations aren't allowed inside generic functions). The
    // .failureError case carries the typed Error so we can re-throw intact.
    return try await withThrowingTaskGroup(of: CKTimeoutRace<T>.self, returning: T.self) { group in
        group.addTask {
            guard let r = await state.wait() else {
                return .cancelled
            }
            switch r {
            case .success(let v): return .success(v)
            case .failure(let e): return .failureError(e)
            }
        }
        group.addTask {
            _ = try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return .timedOut
        }
        guard let first = try await group.next() else {
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            throw CKLandmineTimeout(label: label, seconds: seconds)
        }
        group.cancelAll()
        workTask.cancel()
        await state.cancelWaiter()
        switch first {
        case .success(let v): return v
        case .failureError(let e): throw e
        case .failure(let msg):
            throw CKLandmineWorkError(message: msg)
        case .timedOut:
            NSLog("[ck-landmine] \(label) timed out after \(formatCKTimeoutSeconds(seconds)); cloudd unhealthy?")
            throw CKLandmineTimeout(label: label, seconds: seconds)
        case .cancelled:
            throw CancellationError()
        }
    }
}

/// Fallback error wrapper for the string-only race path. Real CK errors flow
/// through .failureError(Error) and re-throw intact.
struct CKLandmineWorkError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

actor CloudKitHealth {
    static let shared = CloudKitHealth()

    private var cachedResult: (checkedAt: Date, healthy: Bool)?

    func likelyHealthy() async -> Bool {
        if let cachedResult, Date().timeIntervalSince(cachedResult.checkedAt) < 30 {
            return cachedResult.healthy
        }

        let probe = await withCKTimeout("CloudKitHealth.KVS.synchronize", seconds: 1) {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        let healthy = probe != nil
        cachedResult = (Date(), healthy)
        return healthy
    }
}
