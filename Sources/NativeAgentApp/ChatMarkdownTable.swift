import NativeAgentShared
import SwiftUI

// Blueprint: | `ChatMarkdownTable.swift` | `ChatMarkdownTableView`: a parsed transcript table (`ChatMarkdownTable`, NativeAgentShared) as a Grid |

/// Size Grid columns from content so prose wraps without adding a competing transcript scroller; use the same sanitized inline Markdown as prose.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable
    let cells: [[AttributedString]]

    var body: some View {
        let columns = Array(0..<(cells.first?.count ?? 0))
        Grid(alignment: .topLeading, horizontalSpacing: NativeAgentSpacing.sm, verticalSpacing: 0) {
            GridRow {
                ForEach(columns, id: \.self) { column in
                    cellText(cells[0][column], column: column)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.vertical, NativeAgentSpacing.xs)
                }
            }
            Divider().opacity(0.4).gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(columns, id: \.self) { column in
                        cellText(cells[row + 1][column], column: column)
                            .padding(.vertical, NativeAgentSpacing.xs)
                    }
                }
                if row < table.rows.count - 1 {
                    Divider().opacity(0.15).gridCellUnsizedAxes(.horizontal)
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
