import Foundation

/// One lifecycle for every capability she has, her senses, skills and the tools she
/// wrote. One folder holds current, previous and proposed files.
/// - Use: a skill's run or `skill.read` (a recall pointer's one act is that
///   read), a tool's call. Turning one on restarts the clock.
/// - Drop removes an ability; rollback swaps current and previous.
public enum CapabilityLifecycle {
    public enum Action: Sendable { case change, enable, restore, rollback, drop }

    public enum Store: String, CaseIterable, Sendable {
        case skills, tools, senses

        public func directory(in root: URL) -> URL { root.appendingPathComponent(rawValue, isDirectory: true) }
    }
    public static let protectedStores = Store.allCases.map(\.rawValue) + ["abilities", "trust", "security", "catalog", "persona", "workflows/approvals",
                                                                       "approvals", "paired_phones.json", "telegram", "slack"]

    /// Capture existing turn provenance; the returned check reads current trust.
    /// Storage stays below chat; no bound turn means no peer steering.
    public static var turnWriteCheck: @Sendable () -> (@Sendable () -> String?) {
        get { provenanceLock.withLock { provenance } }
        set { provenanceLock.withLock { provenance = newValue } }
    }
    private static let provenanceLock = NSLock()
    nonisolated(unsafe) private static var provenance: @Sendable () -> (@Sendable () -> String?) = { { nil } }

    public static var ownerTrusts: @Sendable (String) -> Bool {
        get { provenanceLock.withLock { peerTrust } }
        set { provenanceLock.withLock { peerTrust = newValue } }
    }
    nonisolated(unsafe) private static var peerTrust: @Sendable (String) -> Bool = { _ in false }

    /// The engine binds the checked Trust reader; publication supplies its own root.
    public static var keepAuthority: @Sendable (URL) -> Bool {
        get { provenanceLock.withLock { keepTrust } }
        set { provenanceLock.withLock { keepTrust = newValue } }
    }
    nonisolated(unsafe) private static var keepTrust: @Sendable (URL) -> Bool = { _ in false }

    public static var writeRefusal: String? { turnWriteCheck()() }

    public static func peerRefusal(_ who: String) -> String {
        "This turn was steered by \(who), so it cannot change senses, tools or skills or capture material for growth. Ask the person to start a fresh turn and read the source again for this change."
    }

    public static func requireWrite() throws {
        if let refusal = writeRefusal {
            throw NSError(domain: "CapabilityLifecycle", code: 403, userInfo: [NSLocalizedDescriptionKey: refusal])
        }
    }

    /// Admission of code is separate from the owner's off-switch.
    public static func requireKeep(ownerAuthorized: Bool) throws {
        guard ownerAuthorized else {
            throw NSError(domain: "CapabilityLifecycle", code: 403, userInfo: [NSLocalizedDescriptionKey:
                "Below Full Mac, keeping a part is the owner's"])
        }
    }

    public static func requiresOwnerToEnable(isOff: Bool, disabledBy: String?) -> Bool {
        disabledBy != "agent" && (isOff || disabledBy != nil)
    }

    public static func nextVersion(_ versions: [Int], requested: Int = 1) throws -> Int {
        let newest = versions.max() ?? 0
        guard newest < Int.max else {
            throw NSError(domain: "CapabilityLifecycle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capability version overflow."])
        }
        return max(newest + 1, requested)
    }

    /// World stops an upgrade could fix. A decide and a floor hand-back
    /// (would_card, irreversible, users_step) never count.
    public static let worldStops: Set<String> = ["state_changed", "stale_version"]

    /// `reason@step` when the same world stop at the same step ended 2 of the
    /// last 3 runs (`runs` oldest first, each `reason@step`).
    public static func repeatedStop(_ runs: [String]) -> String? {
        let last = runs.suffix(3).filter { worldStops.contains(String($0.split(separator: "@").first ?? "")) }
        return Dictionary(grouping: last, by: { $0 }).first { $0.value.count >= 2 }?.key
    }

    /// The ladder's distinct inputs a row keeps.
    public static let inputLimit = 10

    /// ISO-8601, with or without fractional seconds.
    public static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(text)
    }
}
