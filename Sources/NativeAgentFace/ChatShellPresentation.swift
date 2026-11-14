import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatShellPresentation.swift` | `ChatShellStatus`, `ChatShellCopy`; waiting/failure status and composer/greeting copy |

// Shell presentation must not cause storage or network effects.

/// Use one status line and reserve teal for waiting on the user.
enum ChatShellStatus: Equatable, Sendable {
    /// Keep the header quiet when nothing needs attention.
    case settled
    /// Only pending approval may spend teal here.
    case waitingOnYou
    case approvalStatus(String)
    case trouble

    static func make(
        pendingApprovals: Int?,
        approvalError: String?,
        hasTrouble: Bool
    ) -> Self {
        if let approvalError { return .approvalStatus(approvalError) }
        guard let pendingApprovals else { return .approvalStatus("Checking approvals…") }
        if pendingApprovals > 0 { return .waitingOnYou }
        if hasTrouble { return .trouble }
        return .settled
    }

    var text: String {
        switch self {
        case .settled: ""
        case .waitingOnYou: "Waiting on you"
        case .approvalStatus(let status): status
        // Report the known failure without implying a retry.
        case .trouble: "That turn didn't finish"
        }
    }

    var color: Color {
        switch self {
        case .settled: NativeAgentShell.calm
        case .waitingOnYou: NativeAgentShell.needsYou
        case .approvalStatus: NativeAgentShell.secondary
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

    static let errorStuckLink = "Still stuck? Settings"

    static func workingRowTitle(agentName: String) -> String { agentName + " with agents" }
    static let conversationsTitle = "Chats"
    static let briefsRowTitle = "Morning briefs"
}

/// Keep raw JSON in Diagnostics; expandable activity sentences let normal chat explain actual tool use.
