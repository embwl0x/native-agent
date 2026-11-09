import SwiftUI
// Blueprint: | `KnowledgeGraphRows.swift` | Graph canvas colors for the shared entity-kind vocabulary |

enum KGGraphPalette {
    static func color(_ kind: String) -> Color {
        switch kind {
        case "person": .blue
        case "organization": .indigo
        case "project": .orange
        case "concept": .purple
        case "place": .green
        case "event": .red
        case "tool": .gray
        case "fact": .teal
        default: .secondary
        }
    }
}
