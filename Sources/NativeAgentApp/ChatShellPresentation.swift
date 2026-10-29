import EngineRuntime
import AppToolRuntime
import Foundation
import ToolRegistry
import SwiftUI
import ChatTurnRuntime
import ChatSessionWork
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `ChatShellPresentation.swift` | `ChatShellStatus`, `ChatShellCopy`; waiting/failure status and composer/greeting copy |

// Shell presentation projects existing state without storage or network effects.

/// What the single status dot says right now. Exactly one dot, one line, and
/// the teal is spent only on "waiting on you".
enum ChatShellStatus: Equatable, Sendable {
    /// Nothing is wrong; the header stays quiet.
    case settled
    /// An approval is pending. This is the only place the teal is spent.
    case waitingOnYou
    /// The last turn failed or the runtime is unreachable.
    case trouble

    static func make(
        hasPendingApproval: Bool,
        hasTrouble: Bool
    ) -> Self {
        if hasPendingApproval { return .waitingOnYou }
        if hasTrouble { return .trouble }
        return .settled
    }

    var text: String {
        switch self {
        case .settled: ""
        case .waitingOnYou: "Waiting on you"
        // Report the known failure without implying a retry.
        case .trouble: "That turn didn't finish"
        }
    }

    var color: Color {
        switch self {
        case .settled: NativeAgentShell.calm
        case .waitingOnYou: NativeAgentShell.needsYou
        case .trouble: NativeAgentShell.trouble
        }
    }
}

/// Copy for the room's named states.
enum ChatShellCopy {
    /// The composer uses the agent's name, or "the agent" until named, never a pronoun.
    static func composerPlaceholder(agentName: String) -> String {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "the agent" else {
            return "Message the agent"
        }
        return "Message \(trimmed)"
    }

    static func greetingTitle(_ name: String) -> String { "Hi, I'm \(name)." }
    static let greetingDetail =
        "I live on this Mac. Say hello, ask me anything, or hand me something to do."
    static let greetingChips = [
        "What can you do here?",
        "What's on my Mac right now?",
        "Tell me about yourself",
    ]

    // ChatTurnFailure.line states the failed turn's proven effects so Retry can be judged safely.
    static let errorStuckLink = "Still stuck? Settings"

    /// Her conversations with other agents and her helpers, apart from his.
    static func workingRowTitle(agentName: String) -> String { agentName + " with agents" }
    static let conversationsTitle = "Conversations"
    /// Sessions she opened herself and no person ever answered.
    static let briefsRowTitle = "Morning briefs"
}

/// Tool traffic in plain words. The room shows ONE quiet row per turn; opening
/// it shows what she actually touched. Raw JSON never renders here — it stays
/// available in Diagnostics, where a developer is looking for it.
