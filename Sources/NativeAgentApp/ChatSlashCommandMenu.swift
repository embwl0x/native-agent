import Dispatcher
import SwiftUI
// Blueprint: | `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |

struct SlashCommandMenu: View {
    @State private var hoveredCommand: String?
    var filter: String
    var selectedCommand: String?
    var onSelect: (String) -> Void
    // Escape dismisses the popover.
    var onDismiss: (() -> Void)? = nil

    @MainActor
    static func commands(filter: String) -> [ChatSlashCommandDescriptor] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let commands = ChatSlashCommandRegistry.all
        return q.isEmpty ? commands : commands.filter { $0.command.hasPrefix(q) }
    }

    private var filtered: [ChatSlashCommandDescriptor] { Self.commands(filter: filter) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { cmd in
                    Button {
                        onSelect(cmd.selection)
                    } label: {
                        HStack(spacing: 8) {
                            Text(cmd.displayedInvocation)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(NativeAgentShell.text)
                            Text(cmd.description)
                                .font(.caption)
                                .foregroundStyle(NativeAgentShell.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            if hoveredCommand == cmd.id || selectedCommand == cmd.id {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(NativeAgentShell.softFill)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(NativeAgentShell.text, lineWidth: selectedCommand == cmd.id ? 2 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    // Plain, not borderless: borderless drew the rows dim on glass.
                    .buttonStyle(.plain)
                    .id(cmd.id)
                    .accessibilityAddTraits(selectedCommand == cmd.id ? [.isSelected] : [])
                    .onHover { hoveredCommand = $0 ? cmd.id : (hoveredCommand == cmd.id ? nil : hoveredCommand) }
                }
            }
        }
        .frame(minWidth: 320, maxHeight: 280)
        .padding(.vertical, 4)
        .onChange(of: selectedCommand, initial: true) { _, command in
            if let command { proxy.scrollTo(command) }
        }
        // A hidden Escape button closes the slash-command popover.
        .background(
            Button("") { onDismiss?() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        }
    }
}
