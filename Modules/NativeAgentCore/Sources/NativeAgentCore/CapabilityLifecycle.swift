import Foundation
import NativeAgentShared
import os

// Blueprint: | `CapabilityLifecycle.swift` | `CapabilityLifecycle`: shared lifecycle and keep authority |

/// Current, previous and proposed bytes share one lifecycle. Use or enabling renews age; dropping preserves history. Only a throwing turn program may recover
/// its previous version.
public enum CapabilityLifecycle {
    public enum Action: Sendable { case change, enable, restore, drop }

    public enum Store: String, CaseIterable, Sendable {
        case skills, tools, senses

        public func directory(in root: URL) -> URL { root.appendingPathComponent(rawValue, isDirectory: true) }
    }
    public static let protectedStores = Store.allCases.map(\.rawValue) + ["abilities", "trust", "security", "catalog", "persona", "workflows/approvals",
                                                                       "paired_phones.json", "telegram", "slack"]

    /// Capture the turn's provenance; the returned check reads current trust. Storage stays below chat; no turn means no peer steering.
    public static var turnWriteCheck: @Sendable (Turn?) -> (@Sendable () -> ToolFailureError?) {
        get { authority.withLock { $0.provenance } }
        set { authority.withLock { $0.provenance = newValue } }
    }

    public static var ownerTrusts: @Sendable (String) -> Bool {
        get { authority.withLock { $0.peerTrust } }
        set { authority.withLock { $0.peerTrust = newValue } }
    }

    /// The engine binds the checked Trust reader; publication supplies its own root.
    public static var keepAuthority: @Sendable (URL) -> Bool {
        get { authority.withLock { $0.keepTrust } }
        set { authority.withLock { $0.keepTrust = newValue } }
    }
    private struct Authority {
        var provenance: @Sendable (Turn?) -> (@Sendable () -> ToolFailureError?) = { _ in { nil } }
        var peerTrust: @Sendable (String) -> Bool = { _ in false }
        var keepTrust: @Sendable (URL) -> Bool = { _ in false }
    }
    private static let authority = OSAllocatedUnfairLock(initialState: Authority())

    public static func writeRefusal(turn: Turn?) -> String? { turnWriteCheck(turn)()?.message }

    public static func peerRefusal(_ who: String, tap: String?) -> ToolFailureError {
        ToolFailureError("\(who) is an untrusted source, so it cannot change senses, abilities or skills on this run. "
            + (tap.map { "The owner can trust this source at \($0) to authorize future runs." }
               ?? """
                   The saved steer has no authenticated contact binding. It cannot be elevated by renaming it; obtain a new request through an authenticated \
                   connected agent, or let the work go.
                   """),
            effects: .none, owner: "peer \(who) (not elevated)", tap: tap, personDecides: true)
    }

    public static func requireWrite(turn: Turn?) throws {
        if let refusal = turnWriteCheck(turn)() { throw refusal }
    }

    /// Admission of code is separate from the owner's off-switch.
    public static func requireKeep(ownerAuthorized: Bool) throws {
        guard ownerAuthorized else {
            throw NSError(domain: "CapabilityLifecycle", code: 403, userInfo: [NSLocalizedDescriptionKey:
                "Below Full Mac, keeping an ability is the owner's"])
        }
    }

    /// Attribute off-switches to the person, the agent or an untrusted peer; trusted-agent turns carry the agent attribution.
    public static let offActors: Set<String> = ["owner", "hers", "peer", "agent"]

    public static func requiresOwnerToEnable(isOff: Bool, disabledBy: String?) -> Bool {
        // Unattributed off-switches belong to the person; only the person may lift them.
        !["hers", "peer", "agent"].contains(disabledBy ?? "") && (isOff || disabledBy != nil)
    }

    public static func nextVersion(_ versions: [Int], requested: Int = 1) throws -> Int {
        let newest = versions.max() ?? 0
        guard newest < Int.max else {
            throw NSError(domain: "CapabilityLifecycle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capability version overflow."])
        }
        return max(newest + 1, requested)
    }

    /// Only world stops an upgrade can fix count; decision and person-only hand-backs do not.
    public static let worldStops: Set<String> = ["state_changed", "stale_version"]

    /// `reason@step` when the same world stop at the same step ended 2 of the last 3 runs (`runs` oldest first, each `reason@step`).
    public static func repeatedStop(_ runs: [String]) -> String? {
        let last = runs.suffix(3).filter { worldStops.contains(String($0.split(separator: "@").first ?? "")) }
        return Dictionary(grouping: last, by: { $0 }).first { $0.value.count >= 2 }?.key
    }

    public static let inputLimit = 10

    public static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(text)
    }
}
