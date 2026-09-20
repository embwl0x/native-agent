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
                             permissionMode: "ask", referenceVersion: "2026.09.15")
    ]
}
