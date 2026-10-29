import AgentLinkTransport
import Foundation
import PersistenceCore
import ProviderRouting
import NativeAgentCore
// Blueprint: | `AgentPeerPolicy.swift` | `AgentPeerPolicy`: shared A2A origin normalization, `peerFailure`, `peerAuthorizeInterface`; discovery retains its separate card-to-contact check |

package enum AgentPeerPolicy {
    package static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
    }

    package static func peerFailure(_ failure: ProviderFailure.Report, into envelope: inout [String: JSONValue]) {
        envelope["status"] = .string("failed")
        envelope["completed"] = .bool(false)
        envelope["detail"] = .string(failure.errorDescription!)
        envelope["work"] = .string(failure.work.rawValue)
        if let value = try? JSONValue.fromEncodable(failure) {
            envelope["provider_failure"] = value
        }
    }

    package static func peerAuthorizeInterface(_ interface: AgentA2AWire.Interface, cardURL: URL, hasCredential: Bool) throws {
        try AgentPeerHTTP.validateURL(cardURL)
        try AgentPeerHTTP.validateURL(interface.endpoint)
        var candidate = AgentPeerContact(name: "Peer endpoint", endpoint: interface.endpoint, transport: .a2a)
        candidate.credentialKey = nil
        try AgentPeerStore.validate(candidate)
        // HTTP/2 may listen beside the card's HTTP listener. The card may
        // authorize a gRPC port on the same host with the same TLS policy,
        // never a different host or a downgrade from HTTPS to plaintext.
        let sameGRPCHost = interface.binding == "GRPC"
            && interface.endpoint.host?.lowercased() == cardURL.host?.lowercased()
            && interface.endpoint.scheme?.lowercased() == cardURL.scheme?.lowercased()
        guard origin(interface.endpoint) == origin(cardURL) || sameGRPCHost else {
            throw ToolFailureError("The agent interface is on a different origin from its card.", effects: .none,
                owner: interface.endpoint.absoluteString,
                nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]),
                code: "agent_interface_origin_mismatch", status: .refused,
                instruction: "Read contacts, then configure that origin under its own contact name; do not forward this contact's credential.", recovery: .inspect)
        }
        guard case .array(let alternatives) = interface.securityRequirements,
              case .object(let schemes) = interface.securitySchemes else {
            throw ToolFailureError("The agent card's securityRequirements or securitySchemes has the wrong shape.", effects: .none,
                owner: cardURL.absoluteString, tap: "\(cardURL.absoluteString) → securityRequirements / securitySchemes",
                code: "agent_security_requirements_invalid", status: .refused,
                instruction: "Have the agent's owner correct the card's security requirements and scheme definitions.")
        }
        if alternatives.isEmpty { return }
        var bearerSupported = false
        for requirement in alternatives {
            guard case .object(let rawEntries) = requirement else { continue }
            let entries: [String: JSONValue]
            if interface.version == "1.0" {
                guard case .object(let values)? = rawEntries["schemes"] else { continue }
                entries = values
            } else { entries = rawEntries }
            if entries.isEmpty { return }
            let supported = entries.allSatisfy { name, scopes in
                let scopeList: JSONValue
                if interface.version == "1.0", case .object(let value) = scopes { scopeList = value["list"] ?? .array([]) }
                else { scopeList = scopes }
                guard case .array(let values) = scopeList, values.isEmpty,
                      case .object(let raw)? = schemes[name] else { return false }
                let scheme: [String: JSONValue]
                if case .object(let http)? = raw["httpAuthSecurityScheme"] { scheme = http }
                else { guard raw["type"] == .string("http") else { return false }; scheme = raw }
                guard case .string(let kind)? = scheme["scheme"] else { return false }
                return kind.lowercased() == "bearer"
            }
            if supported {
                bearerSupported = true
                if hasCredential { return }
            }
        }
        if bearerSupported {
            throw ToolFailureError("This agent requires a bearer credential; none is configured.", effects: .none,
                owner: cardURL.absoluteString,
                nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]),
                code: "agent_credential_required", status: .refused,
                instruction: "Read contacts and obtain the owner's real token. Configure the authenticated connection with name, endpoint, transport:a2a and bearer_token in agent.connect.", recovery: .inspect)
        }
        throw ToolFailureError("No advertised authentication alternative is supported; this connection supports HTTP bearer authentication without scopes.",
            effects: .none, owner: cardURL.absoluteString, tap: "\(cardURL.absoluteString) → securityRequirements / securitySchemes",
            code: "agent_authentication_unsupported", status: .refused,
            instruction: "Have the agent's owner advertise a supported authentication alternative; a token alone cannot fix an unsupported scheme.")
    }
}

package enum AgentCommunicationError: Error, LocalizedError {
    case invalid(String)
    package var errorDescription: String? {
        switch self { case .invalid(let detail): return "Agent communication: \(detail)." }
    }
}
