import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatShellPresentation.swift` | `ChatShellStatus`, `ChatShellCopy`; waiting/failure status and composer/greeting copy |

// Shell presentation must not cause storage or network effects.

/// Use one status line and reserve teal for waiting on the user.
enum ChatShellStatus: Equatable, Sendable {
    enum ConversationRead: Equatable, Sendable {
        case missing
        case waiting(String)
        case unavailable
        case trouble
        case ready
    }

    /// Keep the header quiet when nothing needs attention.
    case settled
    /// Only pending approval may spend teal here.
    case waitingOnYou
    case approvalStatus(String)
    case conversationStatus(String, failed: Bool)
    case trouble

    static func make(
        pendingApprovals: Int?,
        approvalError: String?,
        conversation: ConversationRead
    ) -> Self {
        if let approvalError { return .approvalStatus(approvalError) }
        guard let pendingApprovals else { return .approvalStatus("Checking approvals…") }
        if pendingApprovals > 0 { return .waitingOnYou }
        switch conversation {
        case .ready: return .settled
        case .missing: return .conversationStatus("Reading conversation…", failed: false)
        case .waiting(let on): return .conversationStatus("Waiting on \(on)…", failed: false)
        case .unavailable: return .conversationStatus("Conversation unavailable", failed: true)
        case .trouble: return .trouble
        }
    }

    var opensTrust: Bool {
        switch self {
        case .waitingOnYou, .approvalStatus: true
        case .settled, .conversationStatus, .trouble: false
        }
    }

    var text: String {
        switch self {
        case .settled: ""
        case .waitingOnYou: "Waiting on you"
        case .approvalStatus(let status): status
        case .conversationStatus(let status, _): status
        // Report the known failure without implying a retry.
        case .trouble: "That turn didn't finish"
        }
    }

    var color: Color {
        switch self {
        case .settled: NativeAgentShell.calm
        case .waitingOnYou: NativeAgentShell.needsYou
        case .approvalStatus: NativeAgentShell.secondary
        case .conversationStatus(_, let failed): failed ? NativeAgentShell.trouble : NativeAgentShell.secondary
        case .trouble: NativeAgentShell.trouble
        }
    }
}

enum ChatShellCopy {
    /// Use the agent's name or an explicit unnamed label so the composer never substitutes a pronoun.
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

    static func workingRowTitle(agentName: String) -> String { agentName + " with agents" }
    static let conversationsTitle = "Chats"
    static let briefsRowTitle = "Morning briefs"
}
