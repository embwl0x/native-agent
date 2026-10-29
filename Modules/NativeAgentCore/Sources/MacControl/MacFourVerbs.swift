import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs.swift` | `MacFourVerbs` struct |

// MARK: - Four verbs — screen · act · go · wait
// Resolve names against fresh perception and return results in words through the existing dispatch and safety owners.
// Workspace screens may carry exact control bindings; the workspace owns their tokens and fresh selections after refusal.
// Screen text retains compiler redaction through `MacScreenRender` and `MacScreenText`.
// Withheld labels cannot be named; resolution uses display text only, and typed text is never echoed.
//
// THE PHYSICAL TIER IS INTERNAL. `act` can move, hover, hold, drag, press keys,
// and aim at regions discovered by the fused screen. Coordinates, view ids, and
// mark ids remain private implementation details; uncertain vision rows stay
// visible but are deliberately not promoted to actionable targets.

// MARK: - The four verbs

public struct MacFourVerbs: Sendable {
    let host: any MacControlClient
    let flowRoot: URL?
    let flowSession: String?
    let clock = SystemMacFourVerbsClock()
    let supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)?
    let namedLocationRoots: [URL]
    /// AUTHORITY, explicitly: subscribing is not perception. Nothing is
    /// installed until the first `sight()` has SUCCEEDED, and that sight goes
    /// through `host.dispatch("look")`, which runs the full gate pre-flight
    /// (accessibility category + an active Full Mac window). A refused look
    /// returns blind before a single observer exists.
    let effectObserverSource: any MacAXEffectObserverSource
    let appActivationSource: any MacAppActivationObserverSource
    /// Her-screen 09-24 — the last app window this verb saw, for her home's
    /// "my windows". Nil unless the caller asks.
    public var sightRecorder: MacSightRecorder?

    public init(
        host: any MacControlClient,
        supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)? = nil,
        namedLocationRoots: [URL]? = nil,
        effectObserverSource: any MacAXEffectObserverSource = defaultMacAXEffectObserverSource(),
        appActivationSource: any MacAppActivationObserverSource = defaultMacAppActivationObserverSource(),
        flowRoot: URL? = nil, flowSession: String? = nil
    ) {
        self.host = host
        self.flowRoot = flowRoot; self.flowSession = flowSession
        self.supplementalSource = supplementalSource
        self.namedLocationRoots = namedLocationRoots ?? Self.commonHomeLocationRoots()
        self.effectObserverSource = effectObserverSource
        self.appActivationSource = appActivationSource
    }

}

/// The last window one verb call saw: its app, its kind (AX role/subrole,
/// never a title) and its top readout as the look redacted it.
public final class MacSightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: (app: String, kind: String?, readouts: [String], before: [String])?
    public init() {}
    /// Every readout the look let through, ranked; `before` is the same app's
    /// readouts one look earlier in this call (an act's pre-action look), so
    /// the one the act changed can be told apart.
    func record(app: String, kind: String?, readouts: [String]) {
        lock.withLock { seen = (app, kind, readouts, seen?.app == app ? seen?.readouts ?? [] : []) }
    }
    public var last: (app: String, kind: String?, readouts: [String], before: [String])? { lock.withLock { seen } }
}
