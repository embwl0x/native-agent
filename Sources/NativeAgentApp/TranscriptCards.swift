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

// Blueprint: | `TranscriptCards.swift` | Mounted transcript cards; action environment reaches the interaction owner |

// MARK: - The transcript host

/// Anchor cards to their turn and animate only insertion so updates never move the reader.
struct ChatInlineCardHost: View {
    let cards: [InlineCardModel]
    let action: @MainActor (InlineCardModel, InlineCardAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(cards) { card in
                    InlineCardView(model: card) { taken in action(card, taken) }
                        // Key by request so re-observation updates the existing card instead of stacking another.
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

/// Default to no action so an unbound card cannot mutate state.
struct InlineCardActionKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor (InlineCardModel, InlineCardAction) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var inlineCardAction: @Sendable @MainActor (InlineCardModel, InlineCardAction) -> Void {
        get { self[InlineCardActionKey.self] }
        set { self[InlineCardActionKey.self] = newValue }
    }
}
