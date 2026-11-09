import SwiftUI
import AppKit
import NativeAgentShared

// Blueprint: | `PageSheetHost.swift` | Shared page sheet framing and the focused Desk research sheet |

/// Reuse page controls instead of duplicating them in focused sheets.
enum DeskPageSheet: String, Identifiable {
    case research

    var id: String { rawValue }
}

struct DeskPageSheetHost: View {
    let sheet: DeskPageSheet
    let onDone: () -> Void

    private var title: String {
        switch sheet {
        case .research: "Look something up"
        }
    }

    var body: some View {
        PageSheetHost(title: title, onDone: onDone) {
            switch sheet {
            case .research: ResearchView()
            }
        }
    }
}

struct PageSheetHost<Content: View>: View {
    let title: String?
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let title { Text(title).font(ShellType.bodySemibold) }
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 700)
    }
}
