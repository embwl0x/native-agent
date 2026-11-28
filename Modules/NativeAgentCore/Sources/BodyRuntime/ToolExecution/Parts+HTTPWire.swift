import SenseCore
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import Network
import Security
import ProviderRouting
import CFNetwork
import MacNerves
import CryptoKit
import NativeAgentShared
// Blueprint: | `Parts+HTTPWire.swift` | HTTP request and bounded response wire conversion for the existing resource broker |

extension Parts {
    public static func fetchRequest(_ args: [String: JSONValue]) throws -> URLRequest {
        let fields = JSONValue.object(args).stringFields
        guard let raw = fields["url"], let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host(percentEncoded: false)?.isEmpty == false,
              url.user == nil, url.password == nil, url.fragment == nil,
              args["method"] == nil || fields["method"] != nil else {
            throw ToolPrimitiveBroker.inputFailure("invalid_fetch_url", field: "url/method",
                accepted: "an http(s) URL without credentials or a fragment, and an optional string method")
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
                throw ToolPrimitiveBroker.inputFailure("invalid_http_headers", field: "headers",
                    accepted: "an object of string values without CR/LF; omit Host, Connection, Content-Length and Transfer-Encoding")
            }
            request.allHTTPHeaderFields = headers.stringFields
        }
        guard ["body", "body_base64", "multipart"].filter({ args[$0] != nil }).count <= 1 else {
            throw ToolPrimitiveBroker.inputFailure("invalid_fetch_body", field: "body/body_base64/multipart", accepted: "at most one body form")
        }
        if args["response_encoding"] != nil, args["response_encoding"] != .string("text"), args["response_encoding"] != .string("base64") {
            throw ToolPrimitiveBroker.inputFailure("invalid_response_encoding", field: "response_encoding", accepted: "text or base64")
        }
        if let body = args["body_base64"] {
            request.httpBody = try fetchBinary(body, field: "body_base64")
        } else if let body = args["multipart"] {
            guard case .array(let rows) = body, (1...32).contains(rows.count), request.value(forHTTPHeaderField: "Content-Type") == nil else {
                throw ToolPrimitiveBroker.inputFailure("invalid_multipart", field: "multipart", accepted: "1–32 parts; omit the Content-Type header")
            }
            let boundary = "----NativeAgentForm" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var data = Data()
            for row in rows {
                let part = row.stringFields
                guard case .object(let given) = row, let name = part["name"], !name.isEmpty,
                      ["name", "filename", "content_type"].allSatisfy({ given[$0] == nil || part[$0].map(multipartHeader) == true }),
                      (given["text"] != nil) != (given["base64"] != nil) else {
                    throw ToolPrimitiveBroker.inputFailure("invalid_multipart", field: "multipart", accepted: "parts with name, optional filename/content_type, and exactly one of text or base64")
                }
                var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
                if let filename = part["filename"] { head += "; filename=\"\(filename)\"" }
                if let type = part["content_type"] { head += "\r\nContent-Type: \(type)" }
                data.append(contentsOf: (head + "\r\n\r\n").utf8)
                if let binary = given["base64"] { data.append(try fetchBinary(binary, field: "multipart.base64")) }
                else if let text = part["text"] { data.append(contentsOf: text.utf8) }
                else { throw ToolPrimitiveBroker.inputFailure("invalid_multipart", field: "multipart.text", accepted: "a string") }
                data.append(contentsOf: "\r\n".utf8)
                guard data.count <= 4 * 1024 * 1024 else {
                    throw ToolPrimitiveBroker.inputFailure("fetch_input_limit", field: "multipart", accepted: "at most 4 MiB encoded")
                }
            }
            data.append(contentsOf: "--\(boundary)--\r\n".utf8)
            request.httpBody = data
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        } else if let body = args["body"] {
            if case .string(let text) = body { request.httpBody = Data(text.utf8) }
            else {
                request.httpBody = try body.serializedData(pretty: false)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }
        let argumentLimit = args["body_base64"] != nil || args["multipart"] != nil ? 6 * 1024 * 1024 : 4 * 1024 * 1024
        guard (request.httpBody?.count ?? 0) <= 4 * 1024 * 1024, try JSONValue.object(args).serializedData(pretty: false).count <= argumentLimit else {
            throw ToolPrimitiveBroker.inputFailure("fetch_input_limit", field: "body/arguments",
                accepted: "a body no larger than 4 MiB and complete fetch arguments no larger than \(argumentLimit / (1024 * 1024)) MiB")
        }
        return request
    }

    static func checkFetchSecretFields(_ args: [String: JSONValue]) throws {
        if let binary = args["body_base64"] { _ = try fetchBinary(binary, field: "body_base64") }
        if case .array(let parts)? = args["multipart"] {
            for part in parts {
                guard case .object(let fields) = part,
                      Keyring.names(in: .object(fields.filter { $0.key != "text" })).isEmpty else {
                    throw ToolPrimitiveBroker.inputFailure("invalid_multipart_secret", field: "multipart", accepted: "secret placeholders only in text")
                }
            }
        }
    }
    private static func multipartHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 32 && $0 != 127 && $0 != 34 && $0 != 92 }
    }

    private static func fetchBinary(_ value: JSONValue, field: String) throws -> Data {
        guard let text = value.stringValue, text.utf8.count <= 5_592_408,
              let bytes = Data(base64Encoded: text), bytes.count <= 4 * 1024 * 1024 else {
            throw ToolPrimitiveBroker.inputFailure("invalid_fetch_binary", field: field, accepted: "base64 decoding to at most 4 MiB, without secret placeholders")
        }
        return bytes
    }

    /// The protocol reads names as they came; a name is redacted only as it is shown to the agent.
    public static func fetchReply(status: Int, headers: [String: String], data: Data,
                                  binary: Bool = false, name: (String) -> String = { $0 }, clean: (String) -> String) throws -> JSONValue {
        let safe = headers.reduce(into: [String: JSONValue]()) { result, entry in
            if !["set-cookie", "authorization", "proxy-authenticate"].contains(entry.key.lowercased()) {
                result[name(entry.key)] = .string(clean(entry.value))
            }
        }
        var fields: [String: JSONValue] = [
            "status": .int(Int64(status)), "headers": .object(safe), "data_trust": .string("untrusted_network"),
        ]
        if binary {
            fields["body_base64"] = .string(data.base64EncodedString()); fields["bytes"] = .int(Int64(data.count)); fields["truncated"] = .bool(false)
        } else {
            guard let body = String(data: data, encoding: .utf8) else {
                throw SenseFailure(code: "http_body_encoding", message: "fetch response body is not UTF-8. Use response_encoding:base64; inspect service state before another modifying request.")
            }
            fields["body"] = .string(clean(body))
        }
        let result: JSONValue = .object(fields)
        guard try result.serializedData(pretty: false).count <= (binary ? 6 : 4) * 1024 * 1024 else {
            throw SenseFailure(code: "output_limit",
                message: "The complete fetch result exceeds \(binary ? 6 : 4) MiB. Request a smaller page or range; inspect service state before another modifying request.")
        }
        return result
    }
}
