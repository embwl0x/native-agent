import Foundation
import NativeAgentShared
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
        NSLog("[ck-landmine] \(label) timed out after \(formatCKTimeoutSeconds(seconds)); cloudd unhealthy?")
        return nil
    case .cancelled:
        return nil
    }
}

private func formatCKTimeoutSeconds(_ seconds: TimeInterval) -> String {
    if seconds.rounded() == seconds {
        return "\(Int(seconds))s"
    }
    return String(format: "%.1fs", seconds)
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
