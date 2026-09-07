import Foundation
import NativeAgentShared

func canonicalAgentDisplayName(_ rawValue: String?, fallback: String = "NativeAgent") -> String {
    NativeAgentIdentity.displayName(rawValue, fallback: fallback)
}
