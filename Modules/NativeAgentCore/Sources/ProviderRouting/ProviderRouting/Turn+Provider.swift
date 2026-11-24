import NativeAgentShared
import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Provider.swift` | `Turn` part ProviderRouting owns: the per-turn provider/model choice |

private enum ProviderChoicePart: TurnPart { static let unset: ProviderTurnChoice? = nil }
private enum ProviderRecoveryPart: TurnPart { static let unset: ProviderRecovery? = nil }

extension Turn {
    /// One reconnect allowance and server-paced wait across this turn's model rounds.
    public var providerRecovery: ProviderRecovery? {
        get { self[ProviderRecoveryPart.self] }
        set { self[ProviderRecoveryPart.self] = newValue }
    }
    /// The per-turn provider/model/effort/Fast choice; admission resolves it once.
    public var providerChoice: ProviderTurnChoice? {
        get { self[ProviderChoicePart.self] }
        set { self[ProviderChoicePart.self] = newValue }
    }
}
