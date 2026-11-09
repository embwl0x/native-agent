import Foundation
import SwiftUI
import AppKit
import EngineRuntime
import AppToolRuntime
import NativeAgentShared
import TrustCenter
import MacControl
import ProviderRouting
import Transcripts
import Desk
import MultimodalTTS
import ChatToolRuntime
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatComposerSettings.swift` | Native composer menus and context receipt: keyboard access and shared routing/actions |

enum ChatComposerCard: String, Hashable, CaseIterable {
    case model, effort = "think", trust, context
}
