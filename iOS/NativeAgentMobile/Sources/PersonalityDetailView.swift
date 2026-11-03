import SwiftUI
import NativeAgentShared
import Combine
import Foundation
import CryptoKit
import Darwin
import AppIntents
import Observation
import UIKit
import os
// Blueprint: | `PersonalityDetailView.swift` | Personality destination, snapshot freshness and trait presentation read the shared sync projection through SettingsStore |

enum PersonalitySnapshotPresentation {
    static func detail(for state: StatusConnectionPresentation.SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale:
            return "Traits may be out of date until a newer Mac personality snapshot arrives."
        case .neverSynced:
            return "Personality snapshot freshness is unknown; these traits may be out of date."
        case .clockMismatch:
            return "Personality snapshot time cannot be compared with this phone; these traits may be out of date."
        }
    }
}

struct PersonalityDetailView: View {
    @StateObject private var store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        AlivePage(title: "Personality", line: "How I think and sound.") {
            if let p = store.sync.personality {
                let snapshotState = StatusConnectionPresentation.syncState(
                    lastSyncedAt: store.sync.transportDeliveryAt(screenGroup: "personality")
                )
                AliveSection("Identity") {
                    if store.hasCompletedRefresh, !store.availableFields.contains(.personality) {
                        AliveNote("Personality could not be refreshed. Showing the last known profile.")
                        AliveDivider()
                    }
                    AliveValueRow(label: "Name", value: p.name)
                    AliveDivider()
                    AliveValueRow(label: "Kind", value: p.personaKind)
                    AliveDivider()
                    AliveValueRow(label: "Snapshot", value: StatusConnectionPresentation.cardValue(for: snapshotState),
                                 emphasized: StatusConnectionPresentation.needsAttention(snapshotState))
                    if let detail = PersonalitySnapshotPresentation.detail(for: snapshotState) {
                        AliveNote(detail)
                    }
                }
                AliveSection("Traits", footer: "Mirrored from the Mac. Edit in the Mac app's Personality view.") {
                    let traits: [(String, Double)] = [
                        ("Warmth", p.traits.warmth), ("Directness", p.traits.directness),
                        ("Humor", p.traits.humor), ("Proactivity", p.traits.proactivity),
                        ("Rigor", p.traits.rigor), ("Autonomy", p.traits.autonomy),
                        ("Creativity", p.traits.creativity), ("Brevity", p.traits.brevity),
                    ]
                    VStack(spacing: 14) {
                        ForEach(traits, id: \.0) { trait in
                            TraitRow(label: trait.0, value: trait.1)
                        }
                    }
                    .aliveRow()
                }
            } else if store.isLoading || !store.hasCompletedRefresh {
                ProgressView("Loading Personality…")
                    .tint(AlivePalette.secondary)
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                AliveCalmState(
                    title: "Not here yet",
                    line: "My personality comes over from the Mac. Keep the Mac app open and try again.",
                    actionTitle: "Try again",
                    action: { Task { await store.refresh() } }
                )
            }
        }
        .task { if MobileDesignSamples.screen == nil { await store.refresh() } }
        .refreshable { await store.refresh() }
    }
}

struct TraitValuePresentation: Equatable {
    let normalizedValue: Double?
    let percentageText: String
    let warningText: String?

    static func project(_ rawValue: Double) -> TraitValuePresentation {
        guard rawValue.isFinite, (0...1).contains(rawValue) else {
            return .init(
                normalizedValue: nil,
                percentageText: "Unavailable",
                warningText: "The Mac reported \(rawValue); traits require a finite value from 0 to 1. Repair this trait in the Mac profile, then refresh."
            )
        }

        return .init(
            normalizedValue: rawValue,
            percentageText: String(format: "%.0f%%", rawValue * 100),
            warningText: nil
        )
    }
}

struct TraitRow: View {
    let label: String
    let value: Double

    var body: some View {
        let projection = TraitValuePresentation.project(value)
        VStack(alignment: .leading, spacing: 6) {
            MobileAdaptiveRow(spacing: 12) {
                Text(label)
                    .foregroundStyle(AlivePalette.text)
                    .frame(minWidth: 96, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Neutral ink presents trait values without implying a health warning.
                if let normalizedValue = projection.normalizedValue {
                    Capsule()
                        .fill(AlivePalette.divider)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(AlivePalette.secondary)
                                    .frame(width: geo.size.width * normalizedValue)
                            }
                        }
                }
                Text(projection.percentageText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: true)
            }
            if let warning = projection.warningText { AliveNote(warning) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label): \(projection.percentageText)"
                + (projection.warningText.map { " — \($0)" } ?? "")
        )
    }
}
