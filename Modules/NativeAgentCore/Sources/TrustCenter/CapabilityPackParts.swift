import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CapabilityPackParts.swift` | Removal of historical capability-pack parts through AbilityStore; only a matching install receipt owns their removal |

/// Retained pack installs can still remove the parts they own.
public enum CapabilityPackParts {
    public static func remove(_ ids: [String], installID: String, dataRoot: URL) throws {
        let store = AbilityStore(dataRoot: dataRoot)
        for id in ids {
            try AbilityStore.withLock {
                guard let file = try store.read(id: id) ?? store.read(id: id, slot: .next),
                      file.metadata["record"].flatMap({ if case .object(let row) = $0 { row["capabilityPackInstallId"] } else { nil } }) == .string(installID) else { return }
                try store.remove(id: id, ownerAuthorized: true)
            }
        }
    }
}
