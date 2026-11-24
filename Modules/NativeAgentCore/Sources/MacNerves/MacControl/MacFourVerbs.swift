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
    package var sawWindow: (@Sendable (String, String?, [String]) -> Void)?

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
