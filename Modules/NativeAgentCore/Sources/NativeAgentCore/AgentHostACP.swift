import Foundation

// Blueprint: | `AgentHostACP.swift` | `AgentHostACP`: stdio contracts and version admission |

/// Use documented stdio contracts, not prompt templates: https://agentclientprotocol.com/protocol/v1/transports
public struct AgentHostACP: Sendable, Equatable, Codable {
    public let executable: String
    public let arguments: [String]
    public let documentation: String
    /// Explicit ask mode, never the host's saved auto-approval setting.
    public let permissionMode: String
    /// Registry pins bound compatibility; arbitrary installed releases are unverified.
    public let referenceVersion: String
    public var environment: [String: String] = [:]
    /// Retain verified ACP version, session modes and reopen support. A send must honor the advertised modes; nil means unverified.
    public var protocolVersion: Int? = nil
    public var modes: [String]? = nil
    public var supportsLoad: Bool? = nil
    public var supportsResume: Bool? = nil

    package init(executable: String, arguments: [String], documentation: String,
                 permissionMode: String, referenceVersion: String, environment: [String: String] = [:],
                 protocolVersion: Int? = nil, modes: [String]? = nil,
                 supportsLoad: Bool? = nil, supportsResume: Bool? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.documentation = documentation
        self.permissionMode = permissionMode
        self.referenceVersion = referenceVersion
        self.environment = environment
        self.protocolVersion = protocolVersion
        self.modes = modes
        self.supportsLoad = supportsLoad
        self.supportsResume = supportsResume
    }

    /// Exact installed version whose sandbox launcher was inspected. Do not infer compatibility for neighbouring releases or bypass its sandbox.
    /// https://github.com/google-gemini/gemini-cli/issues/23959
    public func startupBlocker(installedVersion: String?) -> String? {
        guard executable == "gemini", arguments.contains("--acp"), arguments.contains("--sandbox"),
              let version = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              version == "0.46.0" || version == "v0.46.0" else { return nil }
        return """
            Gemini CLI 0.46.0 cannot start this sandboxed ACP connection: its launcher consumes the protocol input before starting ACP (upstream issue \
            #23959). Nothing ran and the message was not sent. Use a Gemini release with verified sandboxed ACP support, then reconnect. No fixed version has \
            been verified here; do not disable sandboxing or retry this message automatically.
            """
    }

    public func versionNote(_ reported: String?) -> String {
        guard let reported else { return "Untested version: the program did not report a version. Written against \(referenceVersion) (ACP registry pin)." }
        let tokens = reported.split { !$0.isNumber && $0 != "." && $0 != "-" && !$0.isLetter }
        let matches = tokens.contains { $0 == referenceVersion || $0 == "v" + referenceVersion }
        return matches ? "Written against \(referenceVersion) (ACP registry pin); installed version matches."
            : "Untested version: installed \(reported); written against \(referenceVersion) (ACP registry pin)."
    }
}
