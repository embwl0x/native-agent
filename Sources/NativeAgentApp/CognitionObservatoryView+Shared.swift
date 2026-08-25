// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

/// The collapsed Observatory header has two materially different no-number
/// states: an explicit empty count and a count that was not available from its
/// producer. Keep that distinction at the presentation boundary so every
/// collapsible panel uses the same honest badge rule.
enum CognitionObservatoryCountBadgePresentation {
    struct Badge: Equatable {
        let count: Int

        var text: String { String(count) }
    }

    /// `nil` is unavailable and intentionally has no badge. Zero is a real
    /// producer result and must remain visible. Negative values are malformed
    /// counts, not evidence of an empty panel, so they also remain absent.
    static func badge(for count: Int?) -> Badge? {
        guard let count, count >= 0 else { return nil }
        return Badge(count: count)
    }
}

struct CognitionObservatoryCountBadge: View {
    let count: Int?
    let tint: Color

    var body: some View {
        if let badge = CognitionObservatoryCountBadgePresentation.badge(for: count) {
            Text(badge.text)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.15)))
                .foregroundStyle(tint)
                .accessibilityIdentifier("cognition-observatory-count-badge")
        }
    }
}

extension CognitionObservatoryView {

    func labeledValue(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.2f", value))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
