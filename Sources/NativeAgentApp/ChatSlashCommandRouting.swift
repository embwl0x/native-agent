import Foundation

// D2 (2026-08-28): the main chat window intercepted `/model gpt-5.5` and
// dispatched it; a detached chat panel had no prefix check at all, so the same
// text was shipped to the LLM as an ordinary message and echoed back. Both
// surfaces now ask THIS type what to do with a draft. The seam is the routing
// DECISION only — each surface still owns its own dispatch and its own toast.
enum ChatSlashCommandRouting {
    enum Decision: Equatable, Sendable {
        /// Not a command (plain text, or `/tmp/foo` and other non-command
        /// slash text, which must reach the agent unchanged).
        case sendAsMessage
        /// A recognized command. The payload is the command line with the
        /// leading slash already dropped, matching `handleSlashCommand`.
        case dispatch(String)
        /// A recognized command on a surface that cannot run it. The payload
        /// is the bare command name, for the toast.
        case unsupportedHere(String)
    }

    /// `dynamicToolNames` carries the capability tools a surface can dispatch
    /// (empty on surfaces with no capabilities store). `supportsDispatch` is
    /// the surface's own answer to "can I run a slash command at all?".
    static func decide(
        text: String,
        dynamicToolNames: Set<String> = [],
        supportsDispatch: Bool
    ) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .sendAsMessage }
        let body = String(trimmed.dropFirst())
        let name = (body.components(separatedBy: .whitespacesAndNewlines).first ?? "")
            .lowercased()
        guard ChatSlashCommandRegistry.commandNames.contains(name)
            || dynamicToolNames.contains(name)
        else {
            return .sendAsMessage
        }
        return supportsDispatch ? .dispatch(body) : .unsupportedHere(name)
    }

    /// Consumer-readable, and it names where the command DOES work rather than
    /// just refusing.
    static func unsupportedMessage(command: String) -> String {
        "/\(command) only works in the main chat window."
    }
}
