import Foundation

struct ResearchTextDecoding {
    let text: String?
    let declaredCharset: String?
    let encoding: String?
    let source: String
    let discardedTerminalBytes: Int
    let error: String?

    static func decode(_ body: Data, contentType: String?, mime: String, truncated: Bool) -> Self {
        let declaration = charset(contentType ?? "")
        func failed(_ reason: String, source: String = "http_charset") -> Self {
            Self(text: nil, declaredCharset: declaration.value, encoding: nil, source: source,
                discardedTerminalBytes: 0, error: reason)
        }
        if let error = declaration.error { return failed(error) }
        let json = mime == "application/json" || mime.hasSuffix("+json")
        let xml = mime == "application/xml" || mime == "text/xml" || mime.hasSuffix("+xml")
        let chosen = json ? "utf-8" : declaration.value.map(canonical) ?? "utf-8"
        let source = json ? "json_utf8" : (declaration.value == nil ? "default_utf8" : "http_charset")
        if body.starts(with: [0xFF, 0xFE]) || body.starts(with: [0xFE, 0xFF]) || body.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return failed("unsupported_utf16_or_utf32_bom", source: "bom")
        }
        let utf8BOM = body.starts(with: [0xEF, 0xBB, 0xBF])
        if utf8BOM && chosen != "utf-8" { return failed("charset_bom_conflict", source: "conflict") }
        if xml && chosen != "utf-8" { return failed("unsupported_xml_charset") }
        let foundation: String.Encoding
        switch chosen {
        case "utf-8": foundation = .utf8
        case "us-ascii": foundation = .ascii
        case "iso-8859-1": foundation = .isoLatin1
        case "windows-1252": foundation = .windowsCP1252
        default: return failed("unsupported_declared_charset")
        }
        let bytes = utf8BOM ? Data(body.dropFirst(3)) : body
        if chosen == "us-ascii" && bytes.contains(where: { $0 > 0x7F }) {
            return failed("invalid_bytes_for_encoding", source: source)
        }
        var text = String(data: bytes, encoding: foundation)
        var discarded = 0
        if text == nil && truncated && chosen == "utf-8", let count = incompleteUTF8Suffix(bytes) {
            text = String(data: bytes.dropLast(count), encoding: .utf8)
            if text != nil { discarded = count }
        }
        guard let text else { return failed("invalid_bytes_for_encoding", source: source) }
        return Self(text: text, declaredCharset: declaration.value, encoding: chosen,
            source: utf8BOM ? "utf8_bom" : source, discardedTerminalBytes: discarded, error: nil)
    }

    private static func canonical(_ label: String) -> String {
        switch label.lowercased() {
        case "utf8", "utf-8": return "utf-8"
        case "ascii", "us-ascii": return "us-ascii"
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1": return "iso-8859-1"
        case "windows-1252", "cp1252": return "windows-1252"
        default: return label.lowercased()
        }
    }

    /// Split parameters only outside quoted strings; a filename containing
    /// ';charset=...' must never choose the response's text encoding.
    private static func charset(_ header: String) -> (value: String?, error: String?) {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped { current.append(character); escaped = false; continue }
            if quoted && character == "\\" { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle(); current.append(character); continue }
            if character == ";" && !quoted { pieces.append(current); current = "" }
            else { current.append(character) }
        }
        pieces.append(current)
        guard !quoted && !escaped else { return (nil, "invalid_charset_declaration") }
        var values: [String] = []
        for piece in pieces.dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first,
                  key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "charset" else { continue }
            guard pair.count == 2 else { return (nil, "invalid_charset_declaration") }
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") {
                guard value.hasSuffix("\""), value.count >= 2 else { return (nil, "invalid_charset_declaration") }
                var unquoted = ""
                var escape = false
                for c in value.dropFirst().dropLast() {
                    if escape { unquoted.append(c); escape = false }
                    else if c == "\\" { escape = true }
                    else if c == "\"" { return (nil, "invalid_charset_declaration") }
                    else { unquoted.append(c) }
                }
                guard !escape else { return (nil, "invalid_charset_declaration") }
                value = unquoted
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { return (nil, "invalid_charset_declaration") }
            values.append(value)
        }
        guard Set(values.map(canonical)).count <= 1 else {
            return (values.joined(separator: ", "), "conflicting_charset_declarations")
        }
        return (values.first, nil)
    }

    /// Accept only an actually incomplete terminal scalar. Dropping arbitrary
    /// trailing bytes could otherwise hide an invalid interior byte.
    private static func incompleteUTF8Suffix(_ data: Data) -> Int? {
        let suffix = Array(data.suffix(3))
        for index in suffix.indices {
            let lead = suffix[index]
            let expected: Int
            switch lead {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: continue
            }
            let count = suffix.count - index
            guard count < expected else { continue }
            let rest = Array(suffix.dropFirst(index + 1))
            guard rest.allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
            if let second = rest.first {
                if lead == 0xE0 && second < 0xA0 { continue }
                if lead == 0xED && second > 0x9F { continue }
                if lead == 0xF0 && second < 0x90 { continue }
                if lead == 0xF4 && second > 0x8F { continue }
            }
            return count
        }
        return nil
    }
}
