import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Provider.swift` | `Turn` part ProviderRouting owns: the per-turn provider/model choice |

private enum ProviderChoicePart: TurnPart { static let unset: ProviderTurnChoice? = nil }

extension Turn {
    /// The per-turn provider/model/effort/Fast choice; admission resolves it once.
    public var providerChoice: ProviderTurnChoice? {
        get { self[ProviderChoicePart.self] }
        set { self[ProviderChoicePart.self] = newValue }
    }
}
