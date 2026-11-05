import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs.swift` | `MacFourVerbs` struct |

// MARK: - Four verbs — screen · act · go · wait
// Workspace bindings retain their owner’s identity and admission; image points grant no authority. Withheld labels cannot be named, compiler
// redaction survives rendering, and typed text is never echoed.

// MARK: - The four verbs

public struct MacFourVerbs: Sendable {
    let host: any MacControlClient
    let flowRoot: URL?
    let flowSession: String?
    let clock = SystemMacFourVerbsClock()
    let supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)?
    let namedLocationRoots: [URL]
    /// Subscribe only after `sight()` passes the dispatch permission gates; a refused look must leave no observer installed.
    let effectObserverSource: any MacAXEffectObserverSource
    let appActivationSource: any MacAppActivationObserverSource
    /// Home’s window reporting is opt-in; unrequested observations remain nil.
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

/// Window identity uses role/subrole rather than a potentially sensitive title; readouts retain look redaction.
public final class MacSightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: (app: String, kind: String?, readouts: [String], before: [String])?
    public init() {}
    /// Compare ranked readouts against the same app’s pre-action look to identify what the act changed.
    func record(app: String, kind: String?, readouts: [String]) {
        lock.withLock { seen = (app, kind, readouts, seen?.app == app ? seen?.readouts ?? [] : []) }
    }
    public var last: (app: String, kind: String?, readouts: [String], before: [String])? { lock.withLock { seen } }
}
