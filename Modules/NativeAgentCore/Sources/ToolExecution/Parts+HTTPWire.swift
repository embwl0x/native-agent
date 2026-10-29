import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import Senses
import Network
import Security
import ProviderRouting
import CFNetwork
import MacControl
import CryptoKit
import NativeAgentShared
import PersonaEngine
import Privacy
// Blueprint: | `Parts+HTTPWire.swift` | HTTP request and bounded response wire conversion for the existing resource broker |

extension Parts {
    public static func fetchRequest(_ args: [String: JSONValue]) throws -> URLRequest {
        let fields = JSONValue.object(args).stringFields
        guard let raw = fields["url"], let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              args["method"] == nil || fields["method"] != nil else {
            throw ToolPrimitiveBroker.inputFailure("invalid_fetch_url", field: "url/method", accepted: "an http(s) URL without credentials or a fragment, and an optional string method")
        }
        let method = fields["method"]?.uppercased() ?? "GET"
        guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw ToolPrimitiveBroker.inputFailure("invalid_http_method", field: "method", accepted: "a nonempty HTTP method containing letters A-Z")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let headers = args["headers"] {
            guard case .object(let entries) = headers, entries.count == headers.stringFields.count,
                  entries.keys.allSatisfy({ !["host", "connection", "content-length", "transfer-encoding"].contains($0.lowercased())
                      && !$0.contains("\r") && !$0.contains("\n") }),
                  headers.stringFields.values.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else {
                throw ToolPrimitiveBroker.inputFailure("invalid_http_headers", field: "headers", accepted: "an object of string values without CR/LF; omit Host, Connection, Content-Length and Transfer-Encoding")
            }
            request.allHTTPHeaderFields = headers.stringFields
        }
        if let body = args["body"] {
            if case .string(let text) = body { request.httpBody = Data(text.utf8) }
            else {
                request.httpBody = try body.serializedData(pretty: false)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }
        guard (request.httpBody?.count ?? 0) <= 4 * 1024 * 1024, try JSONValue.object(args).serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
            throw ToolPrimitiveBroker.inputFailure("fetch_input_limit", field: "body/arguments", accepted: "a body and complete fetch arguments each no larger than 4 MiB")
        }
        return request
    }

    /// The protocol reads names as they came; a name is redacted only as it is shown to her.
    public static func fetchReply(status: Int, headers: [String: String], data: Data,
                                  name: (String) -> String = { $0 }, clean: (String) -> String) throws -> JSONValue {
        guard let body = String(data: data, encoding: .utf8) else {
            throw SenseFailure(code: "http_body_encoding", message: "fetch response body is not UTF-8. Request UTF-8 from the service or read binary bytes through network.receive; inspect service state before another modifying request.")
        }
        let safe = headers.reduce(into: [String: JSONValue]()) { result, entry in
            if !["set-cookie", "authorization", "proxy-authenticate"].contains(entry.key.lowercased()) {
                result[name(entry.key)] = .string(clean(entry.value))
            }
        }
        let result: JSONValue = .object(["status": .int(Int64(status)), "headers": .object(safe), "body": .string(clean(body))])
        guard try result.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
            throw SenseFailure(code: "output_limit", message: "The complete fetch result exceeds 4 MiB. Request a smaller page or range; inspect service state before another modifying request.")
        }
        return result
    }
}
