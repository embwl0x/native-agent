import SwiftUI

// PATCH-2026-05-08: wave2-chat-ux — slash command menu popover
// PATCH-Phase6b: extraTools — dynamic tool entries from CapabilitiesStore appended after hardcoded ones.
struct SlashCommandMenu: View {
    @State private var hoveredCommand: String?
    var filter: String
    var selectedCommand: String?
    var onSelect: (String) -> Void
    // S.8: called when user presses Escape to dismiss the popover
    var onDismiss: (() -> Void)? = nil
    // PATCH-Phase6b: read-only tools to show as dynamic slash-command entries
    var extraTools: [ToolCapability] = []

    struct SlashCmd: Identifiable {
        var id: String { command }
        var command: String
        var description: String
        var placeholder: String
        var isToolEntry: Bool = false
        var selection: String { placeholder.isEmpty ? command : command + " " }
        var displayedInvocation: String { "/" + (placeholder.isEmpty ? command : placeholder) }
        var helpLine: String { "\(displayedInvocation) — \(description)" }
    }

    static func commands(filter: String, extraTools: [ToolCapability]) -> [SlashCmd] {
        let hardcodedCommands = ChatSlashCommandRegistry.all.map {
            SlashCmd(command: $0.command, description: $0.description, placeholder: $0.placeholder)
        }
        let hardcodedNames = Set(hardcodedCommands.map { $0.command })
        let dynamic = extraTools
            .filter { !hardcodedNames.contains($0.name) }
            .map { SlashCmd(command: $0.name, description: $0.description, placeholder: "", isToolEntry: true) }
        let allCommands = hardcodedCommands + dynamic
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter { $0.command.hasPrefix(q) }
    }

    private var filtered: [SlashCmd] { Self.commands(filter: filter, extraTools: extraTools) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
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
                            // PATCH-Phase6b: tool badge for dynamically injected tool entries
                            if cmd.isToolEntry {
                                Text("tool")
                                    .font(.caption2)
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
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
        // S.8: hidden Escape button closes the slash-command popover
        .background(
            Button("") { onDismiss?() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        }
    }
}
