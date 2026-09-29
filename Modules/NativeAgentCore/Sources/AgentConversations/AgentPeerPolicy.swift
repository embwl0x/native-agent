import AgentLinkTransport
import Foundation
import PersistenceCore
import ProviderRouting

package enum AgentPeerPolicy {
    package static func peerFailure(_ failure: ProviderFailure.Report, into envelope: inout [String: JSONValue]) {
        envelope["status"] = .string("failed")
        envelope["completed"] = .bool(false)
        envelope["detail"] = .string(failure.errorDescription!)
        envelope["work"] = .string(failure.work.rawValue)
        if let data = try? JSONEncoder().encode(failure) {
            envelope["provider_failure"] = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    package static func peerAuthorizeInterface(_ interface: AgentA2AWire.Interface, cardURL: URL, hasCredential: Bool) throws {
        try AgentPeerHTTP.validateURL(cardURL)
        try AgentPeerHTTP.validateURL(interface.endpoint)
        var candidate = AgentPeerContact(name: "Peer endpoint", endpoint: interface.endpoint, transport: .a2a)
        candidate.credentialKey = nil
        try AgentPeerStore.validate(candidate)
        func origin(_ url: URL) -> String {
            "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
        }
        // HTTP/2 may listen beside the card's HTTP listener. The card may
        // authorize a gRPC port on the same host with the same TLS policy,
        // never a different host or a downgrade from HTTPS to plaintext.
        let sameGRPCHost = interface.binding == "GRPC"
            && interface.endpoint.host?.lowercased() == cardURL.host?.lowercased()
            && interface.endpoint.scheme?.lowercased() == cardURL.scheme?.lowercased()
        guard origin(interface.endpoint) == origin(cardURL) || sameGRPCHost else { throw AgentCommunicationError.invalid("cross-origin peer interface requires its own configured contact") }
        guard case .array(let alternatives) = interface.securityRequirements,
              case .object(let schemes) = interface.securitySchemes else { throw AgentCommunicationError.invalid("security requirements") }
        if alternatives.isEmpty { return }
        for requirement in alternatives {
            guard case .object(let rawEntries) = requirement else { continue }
            let entries: [String: JSONValue]
            if interface.version == "1.0" {
                guard case .object(let values)? = rawEntries["schemes"] else { continue }
                entries = values
            } else { entries = rawEntries }
            if entries.isEmpty { return }
            guard hasCredential else { continue }
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
            if supported { return }
        }
        throw AgentCommunicationError.invalid("peer requires unsupported authentication or a configured bearer credential")
    }
}

package enum AgentCommunicationError: Error, LocalizedError {
    case invalid(String)
    package var errorDescription: String? {
        switch self { case .invalid(let detail): return "Agent communication: \(detail)." }
    }
}
