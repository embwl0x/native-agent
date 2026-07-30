import Foundation
import NativeAgentShared

func canonicalAgentDisplayName(_ rawValue: String?, fallback: String = "NativeAgent") -> String {
    NativeAgentIdentity.displayName(rawValue, fallback: fallback)
}

func storedChatAgentDisplayName(fallback: String = "NativeAgent") -> String {
    canonicalAgentDisplayName(UserDefaults.standard.string(forKey: "chatPersona"), fallback: fallback)
}
