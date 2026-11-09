import NativeAgentShared
import SwiftUI

// Blueprint: | `ChatMarkdownTable.swift` | `ChatMarkdownTableView`: a parsed transcript table (`ChatMarkdownTable`, NativeAgentShared) as a Grid |

/// Size Grid columns from content so prose wraps without adding a competing transcript scroller; use the same sanitized inline Markdown as prose.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable
    let cells: [[AttributedString]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: NativeAgentSpacing.sm, verticalSpacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { row, values in
                GridRow {
                    ForEach(Array(values.enumerated()), id: \.offset) { column, value in
                        cellText(value, column: column)
                            .font(row == 0 ? NativeAgentFont.tag : ShellType.body)
                            .foregroundStyle(row == 0 ? .secondary : .primary)
                            .textCase(row == 0 ? .uppercase : nil)
                            .padding(.vertical, NativeAgentSpacing.xs)
                    }
                }
                if row < cells.count - 1 {
                    Divider().opacity(row == 0 ? 0.4 : 0.15).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, NativeAgentSpacing.xs)
        .houseInset(in: RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cellText(_ text: AttributedString, column: Int) -> some View {
        let aligned: Alignment = switch table.align(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        Text(text)
        .multilineTextAlignment(table.align(column) == .trailing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: aligned)
        .gridColumnAlignment(table.align(column) == .trailing ? .trailing : .leading)
    }
}
