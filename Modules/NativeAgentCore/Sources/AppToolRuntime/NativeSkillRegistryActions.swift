import Foundation
import PersistenceCore
import Senses
import ToolExecution
import TrustCenter
// Blueprint: | `NativeSkillRegistryActions.swift` | owner-facing enable/disable through `Parts` and capability-pack script-host binding; `enableSkill`, `disableSkill` |

/// The owner's own hand on a part: the Skills page's Install, an approved
/// card, a self-improvement apply. Each goes through the one lifecycle (`Parts`).
public enum NativeSkillRegistryActions {
    public static func installDemoCapabilityPack(dataRoot: URL) async throws -> CapabilityPackInstall {
        let host = AppScriptRunner.Host(call: { _ in .null }, dataRoot: dataRoot)
        return try await OwnedProgramInvocation.$host.withValue(host) {
            try await CapabilityPackInstall.installDemo(dataRoot: dataRoot)
        }
    }

    /// The owner keeps a part, or turns it back on. `reviewedDigest` is the
    /// exact version the owner read (a card's); one changed since keeps nothing.
    public static func enableSkill(name: String, dataRoot: URL, reviewedDigest: String?) async throws {
        let host = AppScriptRunner.Host(call: { _ in .null }, dataRoot: dataRoot)
        let outcome = await OwnedProgramInvocation.$host.withValue(host) {
            await Parts(root: dataRoot).enable(name, version: reviewedDigest, fullMac: false, ownerAuthorized: true)
        }
        guard outcome.ok else { throw PartError.invalid(outcome.text) }
    }

    public static func disableSkill(name: String, dataRoot: URL) async throws {
        let outcome = Parts(root: dataRoot).disable(name, reason: nil, fullMac: false, ownerAuthorized: true)
        guard outcome.ok else { throw PartError.invalid(outcome.text) }
    }
}
