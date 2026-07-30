import SwiftUI

/// Shared compact notice row used by the observatory panels
/// (ContextFlowObservatoryPanel + WorkshopObservatoryPanel). Follows the
/// StalePanelNotice visual idiom (ChatView.swift): a tinted SF Symbol + text
/// over a faint tinted rounded background.
///
/// C10 (tightness-sweep 2026-07-17): both panels had a byte-identical private
/// `noticeRow(icon:tint:title:detail:)`; this is the single owner. The panels
/// keep their thin `noticeRow(...)` wrappers so their call sites are unchanged.
struct ObservatoryNoticeRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
    }
}
