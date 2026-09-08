import SwiftUI

// PATCH-2026-05-08: wave2-chat-ux — slash command menu popover
// PATCH-Phase6b: extraTools — dynamic tool entries from CapabilitiesStore appended after hardcoded ones.
struct SlashCommandMenu: View {
    var filter: String
    var onSelect: (String) -> Void
    // S.8: called when user presses Escape to dismiss the popover
    var onDismiss: (() -> Void)? = nil
    // PATCH-Phase6b: read-only tools to show as dynamic slash-command entries
    var extraTools: [ToolCapability] = []
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false

    private struct SlashCmd: Identifiable {
        var id: String { command }
        var command: String
        var description: String
        var placeholder: String
        var isToolEntry: Bool = false
    }

    private var hardcodedCommands: [SlashCmd] {
        ChatSlashCommandRegistry.visible(
            showDeveloperSurfaces: NativeAgentShellPreference.developerSurfacesShown(showDeveloperSurfaces)
        ).map {
            SlashCmd(command: $0.command, description: $0.description, placeholder: $0.placeholder)
        }
    }

    // All commands: hardcoded entries + dynamic tool entries (tools not already covered by hardcoded names)
    private var allCommands: [SlashCmd] {
        let hardcodedNames = Set(hardcodedCommands.map { $0.command })
        let dynamic = extraTools
            .filter { !hardcodedNames.contains($0.name) }
            .map { SlashCmd(command: $0.name, description: $0.description, placeholder: "", isToolEntry: true) }
        return hardcodedCommands + dynamic
    }

    private var filtered: [SlashCmd] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter { $0.command.hasPrefix(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { cmd in
                    Button {
                        let text = cmd.placeholder.isEmpty ? cmd.command : cmd.command + " "
                        onSelect(text)
                    } label: {
                        HStack(spacing: 8) {
                            Text("/" + (cmd.placeholder.isEmpty ? cmd.command : cmd.placeholder))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(cmd.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(minWidth: 320, maxHeight: 280)
        .padding(.vertical, 4)
        // S.8: hidden Escape button closes the slash-command popover
        .background(
            Button("") { onDismiss?() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
    }
}
