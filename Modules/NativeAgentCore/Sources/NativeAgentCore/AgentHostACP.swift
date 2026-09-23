import Foundation

/// Documented stdio entry points, not prompt templates. ACP wire version 1.
/// https://agentclientprotocol.com/protocol/v1/transports
public struct AgentHostACP: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let documentation: String
    /// Explicit ask mode, never the host's saved auto-approval setting.
    public let permissionMode: String
    /// ACP registry pins this integration was written against, not a promise
    /// that arbitrary installed builds have been tested.
    public let referenceVersion: String
    public static let registrySource = "https://github.com/agentclientprotocol/registry"
    public var environment: [String: String] { executable == "goose" ? ["GOOSE_MODE": "chat"] : [:] }

    /// Exact installed version whose sandbox launcher was inspected. Do not
    /// infer compatibility for neighbouring releases or bypass its sandbox.
    /// https://github.com/google-gemini/gemini-cli/issues/23959
    public func startupBlocker(installedVersion: String?) -> String? {
        guard executable == "gemini", arguments.contains("--acp"), arguments.contains("--sandbox"),
              let version = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              version == "0.46.0" || version == "v0.46.0" else { return nil }
        return "Gemini CLI 0.46.0 cannot start this sandboxed ACP connection: its launcher consumes the protocol input before starting ACP (upstream issue #23959). Nothing ran and the message was not sent. Use a Gemini release with verified sandboxed ACP support, then reconnect. No fixed version has been verified here; do not disable sandboxing or retry this message automatically."
    }

    public func versionNote(_ reported: String?) -> String {
        guard let reported else { return "Untested version: the program did not report a version. Written against \(referenceVersion) (ACP registry pin)." }
        let tokens = reported.split { !$0.isNumber && $0 != "." && $0 != "-" && !$0.isLetter }
        let matches = tokens.contains { $0 == referenceVersion || $0 == "v" + referenceVersion }
        return matches ? "Written against \(referenceVersion) (ACP registry pin); installed version matches."
            : "Untested version: installed \(reported); written against \(referenceVersion) (ACP registry pin)."
    }

    public static let byHostID: [String: Self] = [
        "gemini-cli": Self(executable: "gemini", arguments: ["--acp", "--approval-mode=plan", "--sandbox"],
                       documentation: "https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md",
                       permissionMode: "plan", referenceVersion: "0.60.0"),
        "goose": Self(executable: "goose", arguments: ["acp"],
                      documentation: "https://block-goose.mintlify.app/advanced/acp-protocol",
                      permissionMode: "chat", referenceVersion: "1.51.0"),
        "cursor-cli": Self(executable: "cursor-agent", arguments: ["acp", "--mode=ask", "--sandbox=enabled"],
                             documentation: "https://cursor.com/docs/cli/acp",
                             permissionMode: "ask", referenceVersion: "2026.09.15"),
        // Read from the installed agent (0.21.3): `hermes acp` is its stdio entry
        // point; its session modes are default ("Ask before edits"),
        // accept_edits and dont_ask, and "default" is the asking one. It takes
        // its own slash commands (/model, /help, /compress) as ordinary
        // messages, so a model switch is just a message.
        "hermes": Self(executable: "hermes", arguments: ["acp"],
                       documentation: "https://hermes-agent.nousresearch.com/docs/user-guide/features/acp",
                       permissionMode: "default", referenceVersion: "0.21.3")
    ]
}
