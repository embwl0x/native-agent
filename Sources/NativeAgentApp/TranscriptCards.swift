import ApprovalTransactions
import EngineRuntime
import SwiftUI
import AppKit
import MemoryV2
import Foundation
import Combine
import Cognition
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TranscriptCards.swift` | ChatInlineCardHost draws the page mount's current-message card models; the action environment reaches the interaction owner |

// MARK: - The transcript host

/// Anchors a card to the turn it belongs to, inside the transcript, at the tool
/// row where the interaction lives. It appears in place and settles in place:
/// the entrance animation fires once, on insertion, and Reduce Motion turns it
/// off. Nothing here scrolls the reader anywhere.
struct ChatInlineCardHost: View {
    let cards: [InlineCardModel]
    let action: @MainActor (InlineCardModel, InlineCardAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(cards) { card in
                    InlineCardView(model: card) { taken in action(card, taken) }
                        // Identity is the request, so a re-observation of the
                        // same blocked request updates this card instead of
                        // stacking a second one.
                        .id(card.id)
                        .transition(NativeAgentMotion.fade)
                }
            }
            .animation(NativeAgentMotion.respecting(NativeAgentMotion.standard,
                                                    reduceMotion: reduceMotion),
                       value: cards.map(\.id))
        }
    }
}

/// Where a card's action goes. Default: nowhere.
struct InlineCardActionKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor (InlineCardModel, InlineCardAction) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var inlineCardAction: @Sendable @MainActor (InlineCardModel, InlineCardAction) -> Void {
        get { self[InlineCardActionKey.self] }
        set { self[InlineCardActionKey.self] = newValue }
    }
}
