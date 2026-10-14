import EngineRuntime
import AppToolRuntime
import Foundation
import ToolRegistry
import SwiftUI
import ChatOrchestration
import ChatSessionWork
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter

// ui-simplify 2026-09-02 (Lane A): value-only presentation rules for the new
// shell. Everything here is a pure projection of state the app already owns —
// no new stores, no new settings, no network.

/// The one place a trust posture becomes a sentence a person can read.
///
/// Full Mac reads the same saved grant as Trust. It has no timer
/// (2026-09-10): it is on until the person turns it off.
enum ChatShellTrustPhrase: Equatable, Sendable {
    /// One of the four preset cards is exactly in force: the header reads its
    /// name, so it can never disagree with the composer's trust chip
    /// (User, 2026-09-17: a fresh install read "Approval required" up top and
    /// "Work mode" below, for the same posture).
    case preset(TrustPolicyPreset)
    case strict
    case balanced
    case wideOpenWithReceipts
    case fullMac
    case unknown

    static func make(policy: TrustPolicy?, now: Date = Date()) -> Self {
        guard let policy else { return .unknown }
        if TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy) { return .fullMac }
        if let preset = TrustPolicyPreset.matching(
            policy: policy, accessMode: TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)) {
            return .preset(preset)
        }
        switch policy.permissionLevel {
        case "strict": return .strict
        case "balanced": return .balanced
        case "wide_open_receipts": return .wideOpenWithReceipts
        case "full_mac_os": return .balanced
        default: return .unknown
        }
    }

    /// Plain language, one line, no jargon and no raw policy token.
    var text: String {
        switch self {
        case .preset(let preset): preset.title
        case .strict, .balanced: "Approval required"
        case .wideOpenWithReceipts: "Limited Mac access"
        case .fullMac: "Full Mac access"
        case .unknown: "Permissions unavailable"
        }
    }
}

/// What the single status dot says right now. Exactly one dot, one line, and
/// the teal is spent only on "waiting on you".
enum ChatShellStatus: Equatable, Sendable {
    /// Nothing is wrong; the line is her trust posture.
    case settled(ChatShellTrustPhrase)
    /// An approval is pending. This is the only place the teal is spent.
    case waitingOnYou
    /// The last turn failed or the runtime is unreachable.
    case trouble

    static func make(
        policy: TrustPolicy?,
        hasPendingApproval: Bool,
        hasTrouble: Bool
    ) -> Self {
        if hasPendingApproval { return .waitingOnYou }
        if hasTrouble { return .trouble }
        return .settled(.make(policy: policy))
    }

    var text: String {
        switch self {
        case .settled(let phrase): phrase.text
        case .waitingOnYou: "Waiting on you"
        // 2026-09-06: nothing here knows about retries, and nothing was
        // retrying. The dot says what is actually known.
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

/// Copy for the room's three named states. Kept out of the views so the words
/// Agent and User agreed on live in one readable place.
enum ChatShellCopy {
    // 2026-09-06: the offline variant ("Keep typing. I'll send it when I'm
    // back.") promised a send that no queue state backed. One placeholder.
    static let composerPlaceholder = "Say anything"

    /// The composer speaks to the agent BY NAME once it has one.
    ///
    /// 2026-09-15: naming the agent in the first conversation makes a small,
    /// immediately-checkable promise — "the name at the top of this window" —
    /// and the composer is the other place the person is already looking. Until
    /// then it is "the agent", lower-case, because that is a common noun
    /// mid-sentence (house copy: the name, or "the agent", never a pronoun).
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

    // The card's line says what the failed turn provably did — see
    // `ChatTurnFailure.line`. "I didn't finish that one." said nothing about
    // whether Retry was safe (Agent, fluid-glass review).
    static let errorStuckLink = "Still stuck? Settings"

    static let workingRowTitle = "Working"
    static let conversationsTitle = "Conversations"
    /// Sessions she opened herself and no person ever answered.
    static let briefsRowTitle = "Morning briefs"
}

/// Tool traffic in plain words. The room shows ONE quiet row per turn; opening
/// it shows what she actually touched. Raw JSON never renders here — it stays
/// available in Diagnostics, where a developer is looking for it.
