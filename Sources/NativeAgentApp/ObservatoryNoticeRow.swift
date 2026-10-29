import SwiftUI

// Blueprint: | `ObservatoryNoticeRow.swift` | `ObservatoryNoticeRow`: one compact tinted notice presentation shared by Observatory panels |

/// Shared compact notice row for observatory panels.
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
        .houseInset(in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
    }
}
