import Foundation

/// Shared text rules for rebuildable context projections.
enum NativeContextProjectionText {
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func bounded(_ value: String, to maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum))
    }

    static func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }

    static func triggers(_ text: String) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(token)
            guard value.count >= 2, seen.insert(value).inserted else { continue }
            values.append(bounded(value, to: 64))
            if values.count == 12 { break }
        }
        return values
    }
}
