import Foundation
import ApprovalInbox
import BackgroundLoops
import ChatTurnRuntime
import ChatToolRuntime
import AgentConversations
import CognitiveSubstrate
import Context
import ContextFlow
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Desk
import Experiences
import DreamREMCycle
import ProviderRouting
import AuthoredCapabilities
import NativeAgentShared
import Studio
import Transcripts
import TurnTrace
// Blueprint: | `NativeCognitionRuntime+RecentLife.swift` | `NativeCognitionRuntime` moment-to-care migration retained while the old memory rows remain |

extension NativeCognitionRuntime {
    /// Once: the retired moment lane's moments become the care movements they
    /// were (`AdaptiveMemoryPromoter.moveMomentsIntoCaresOnce`).
    func moveMomentsIntoCaresOnce() async {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else { return }
        await AdaptiveMemoryPromoter.moveMomentsIntoCaresOnce(
            memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot), dataRoot: dataRoot
        ) { [substrate] note, moved, felt, provenance in
            try await substrate.keepMomentInCares(note, moved: moved, felt: felt, provenance: provenance)
        }
    }

}
