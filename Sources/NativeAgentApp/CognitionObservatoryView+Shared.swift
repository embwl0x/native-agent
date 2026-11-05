import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

// Blueprint: | `CognitionObservatoryView+Shared.swift` | Count badges preserve zero and withhold unavailable evidence |

/// Distinguish explicit empty counts from unavailable reads at the shared badge boundary.
enum CognitionObservatoryCountBadgePresentation {
    struct Badge: Equatable {
        let count: Int

        var text: String { String(count) }
    }

    /// Show measured zero; nil and malformed negative counts cannot prove emptiness and receive no badge.
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
