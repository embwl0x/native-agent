import NativeAgentShared
import Foundation

// Blueprint: | `CausalTransitionEvidence.swift` | `CausalTransitionEvidence.opaqueIdentity`: SHA-256 identities for outcome evidence |

public enum CausalTransitionEvidence {
    public static func opaqueIdentity(_ raw: String) -> String {
        SHA256Hex.of(utf8: raw)
    }
}
