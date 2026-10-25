import MemoryV2
import PersistenceCore
#if canImport(CloudKit)
import CloudKit
#endif
import Foundation
import NativeAgentShared
#if canImport(Security)
import Security
// Blueprint: | `CKLandmine.swift` | CloudKit entitlement probes, guarded account-status projection and `withCKTimeout` |
#endif

// 2026-06-07 task #88 follow-up: the old wording ("unavailable — provisioning
// profile lacks CloudKit capability") made it look like all of iCloud sync
// was broken. In practice the CloudKit *database* path is hard-disabled by
// design (the launch landmine), but KVS sync and iCloud Drive document
// containers run on independent entitlements that DO work. Be honest about
// what's off without alarming the user about iCloud sync as a whole.
public let nativeAgentCloudKitDisabledStatus = "DB sync off (KVS sync active)"

public func nativeAgentCloudKitAccountProbeEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hasCloudKitEntitlement: @Sendable () -> Bool = nativeAgentHasCloudKitServiceEntitlement
) -> Bool {
    let raw = (environment["NATIVE_AGENT_ENABLE_CLOUDKIT"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard raw == "1" || raw == "true" || raw == "yes" else { return false }
    return hasCloudKitEntitlement()
}

public func nativeAgentHasCloudKitServiceEntitlement() -> Bool {
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

public func withCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)

    switch await detachedCloudKitTimeoutRace(timeoutNanoseconds: timeoutNanoseconds, work) {
    case .success(let value):
        return value
    case .failure(let error):
        nativeLog("[ck-landmine] \(label) failed: \(error)")
        return nil
    case .timedOut:
        nativeLog("[ck-landmine] \(label) timed out after \(formatCKTimeoutSeconds(seconds)); cloudd unhealthy?")
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

public func nativeAgentCloudKitAccountStatus(label: String) async -> String {
    guard nativeAgentCloudKitAccountProbeEnabled() else { return nativeAgentCloudKitDisabledStatus }
    #if canImport(CloudKit)
    return await withCKTimeout(label) {
        nativeAgentCloudKitAccountWords(try await CKContainer.default().accountStatus())
    } ?? "iCloud didn't answer in time"
    #else
    return "iCloud isn't available"
    #endif
}

#if canImport(CloudKit)
private func nativeAgentCloudKitAccountWords(_ status: CKAccountStatus) -> String {
    switch status {
    case .available: return "Signed in to iCloud"
    case .noAccount: return "Not signed in to iCloud"
    case .restricted: return "iCloud is restricted on this Mac"
    case .temporarilyUnavailable: return "iCloud needs you to confirm your account"
    case .couldNotDetermine: return "Couldn't check iCloud"
    @unknown default: return "Couldn't check iCloud"
    }
}
#endif

extension MemoryV2NativeStackSnapshot {
    public static func load(dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> Self {
        var snap = await read(dataRoot: dataRoot)
        snap.cloudKitAccountStatus = await nativeAgentCloudKitAccountStatus(label: "MemoryV2NativeStackSnapshot.cloudKitAccount")

        return snap
    }
}
