import MindCore
import PersistenceCore
import CloudKit
import Foundation
import NativeAgentShared
// Blueprint: | `CKLandmine.swift` | CloudKit entitlement probes and guarded account-status projection |

public func nativeAgentCloudKitAccountProbeEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    let raw = (environment["NATIVE_AGENT_ENABLE_CLOUDKIT"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard raw == "1" || raw == "true" || raw == "yes" else { return false }
    return DeviceCloudKitPreflight.hasCloudKitEntitlement()
}

public func nativeAgentCloudKitAccountStatus() async -> String {
    guard nativeAgentCloudKitAccountProbeEnabled() else { return "iCloud account not checked (diagnostic probe disabled)" }
    do {
        return nativeAgentCloudKitAccountWords(try await CKContainer.default().accountStatus())
    } catch {
        return "iCloud account check failed: \(error.localizedDescription)"
    }
}

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

extension MemoryV2NativeStackSnapshot {
    public static func load(dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> Self {
        var snap = await read(dataRoot: dataRoot)
        snap.cloudKitAccountStatus = await nativeAgentCloudKitAccountStatus()

        return snap
    }
}
