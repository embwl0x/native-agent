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
// Blueprint: | `SecretRedactor.swift` | Exact-secret insertion and whole/stream redaction formats shared by one admitted execution |

/// Her text with each named placeholder replaced by its value; `url` percent-encodes the value for a URL.
func insertingSecrets(_ text: String, _ values: [String: String], url: Bool = false) -> String {
    values.reduce(text) { text, entry in
        text.replacingOccurrences(of: "{{secret:\(entry.key)}}",
            with: url ? entry.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? entry.value : entry.value)
    }
}

/// What she reads back, with every value inserted in this run replaced by `[secret:<name>]` in each form an insertion writes it: as written, URL-encoded, escaped inside a JSON string (ASCII or UTF-8, slashes escaped or not) and base64; in
/// a header name, in any case. A program granted a value can still re-encode it some other way; its grant is the fence.
struct SecretRedactor: Sendable {
    private(set) var values: [(name: String, bytes: Data)] = []
    init() {}

    mutating func add(_ values: [String: String]) {
        for (name, value) in values {
            let quoted = (try? JSONValue.string(value).serializedData(pretty: false)).map { String(decoding: $0.dropFirst().dropLast(), as: UTF8.self) } ?? value
            // The UTF-8 JSON string most services write: only quote, backslash and control characters escaped.
            let utf8 = value.unicodeScalars.map { scalar -> String in
                switch scalar {
                case "\"": "\\\""
                case "\\": "\\\\"
                case "\n": "\\n"
                case "\r": "\\r"
                case "\t": "\\t"
                case _ where scalar.value < 0x20: String(format: "\\u%04x", scalar.value)
                default: String(scalar)
                }
            }.joined()
            let forms = [value, value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value,
                         quoted, quoted.replacingOccurrences(of: "/", with: "\\/"), quoted.replacingOccurrences(of: "\\/", with: "/"), utf8,
                         Data(value.utf8).base64EncodedString()]
            for form in Set(forms) where !self.values.contains(where: { $0.bytes == Data(form.utf8) }) {
                self.values.append((name, Data(form.utf8)))
            }
        }
    }

    func callAsFunction(_ text: String) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: String(decoding: $1.bytes, as: UTF8.self), with: "[secret:\($1.name)]") }
    }

    func callAsFunction(_ value: JSONValue) -> JSONValue { values.isEmpty ? value : value.mapStrings { self($0) } }

    /// A header name, which HTTP does not case: lowercased, each value matched lowercased too.
    func name(_ text: String) -> String {
        values.reduce(text.lowercased()) { $0.replacingOccurrences(of: String(decoding: $1.bytes, as: UTF8.self).lowercased(), with: "[secret:\($1.name)]") }
    }

    func whole(_ data: Data) -> Data {
        values.reduce(data) { data, secret in
            var out = Data(), rest = data[...]
            while let found = rest.range(of: secret.bytes) {
                out += rest[..<found.lowerBound] + Data("[secret:\(secret.name)]".utf8); rest = rest[found.upperBound...]
            }
            return out + rest
        }
    }
}

/// Stream redaction holds secret prefixes of four or more bytes for the next piece. Up to three leading bytes may go out; their remainder is redacted.
struct SecretStream: Sendable {
    private var held = Data()
    private var begun: [Data: Int] = [:]
    public init() {}

    mutating func pass(_ piece: Data, end: Bool, _ redactor: SecretRedactor) -> Data {
        var data = held + piece
        held = Data()
        for (bytes, count) in begun {
            let rest = bytes.dropFirst(count)
            if data.starts(with: rest), let name = redactor.values.first(where: { $0.bytes == bytes })?.name {
                data = Data("[secret:\(name)]".utf8) + data.dropFirst(rest.count)
            } else if !end, rest.starts(with: data) {
                held = data
                return Data()
            }
        }
        begun = [:]
        data = redactor.whole(data)
        guard !end else { return data }
        var hold = 0
        for secret in redactor.values {
            guard let count = (1..<max(secret.bytes.count, 1)).reversed().first(where: { data.suffix($0) == secret.bytes.prefix($0) }) else { continue }
            if count >= 4 { hold = max(hold, count) } else { begun[secret.bytes] = count }
        }
        if hold > 0 { begun = [:]; held = data.suffix(hold) }
        return data.dropLast(hold)
    }

    /// The same pass, with a UTF-8 character split across pieces held whole: only the start of a character that text before it can still complete; bytes that cannot become UTF-8 go out at once. A value the shown text began stays begun by
    /// what of it went out.
    mutating func characters(_ piece: Data, end: Bool, _ redactor: SecretRedactor) -> Data {
        var data = pass(piece, end: end, redactor)
        if !end, let lead = data.suffix(4).lastIndex(where: { $0 & 0xC0 != 0x80 }), (0xC2...0xF4).contains(data[lead]) {
            let width = data[lead] >= 0xF0 ? 4 : data[lead] >= 0xE0 ? 3 : 2
            if data.endIndex - lead < width, String(data: data[..<lead], encoding: .utf8) != nil {
                let moved = data.endIndex - lead
                begun = begun.compactMapValues { $0 > moved ? $0 - moved : nil }
                held = data[lead...] + held
                data = data[..<lead]
            }
        }
        return data
    }
}
