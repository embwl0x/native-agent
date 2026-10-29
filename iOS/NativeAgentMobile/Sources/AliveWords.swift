import Foundation
import NativeAgentShared
import SwiftUI
import UIKit
// Blueprint: | `AliveWords.swift` | Count, identifier and timestamp wording for phone screens |

// MARK: - Words

/// Plain words the way the Mac pages say them.
enum AliveWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six",
                               "seven", "eight", "nine", "ten"]

    /// "Three", not "3", up to ten; digits after.
    static func spelled(_ n: Int, capitalized: Bool = true) -> String {
        guard ones.indices.contains(n) else { return "\(n)" }
        let word = ones[n]
        return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

    /// The one pluralizer for every count on screen: "1 tool", "2 tools",
    /// "3 replies", "2 thinking". `spelled` says "Two tools" up to ten.
    static func count(_ n: Int, _ noun: String, plural: String? = nil, spelled: Bool = false) -> String {
        let number = spelled ? self.spelled(n, capitalized: false) : n.formatted()
        return "\(number) \(n == 1 ? noun : plural ?? pluralized(noun))"
    }

    private static func pluralized(_ noun: String) -> String {
        if noun.hasSuffix("ing") || noun.hasSuffix("s") { return noun }
        if noun.hasSuffix("y"), let before = noun.dropLast().last, !"aeiou".contains(before) {
            return noun.dropLast() + "ies"
        }
        return noun + "s"
    }

    /// Snake-, kebab- and dot-case ids read as words: "calendar_read" → "Calendar read".
    static func humanized(_ raw: String) -> String {
        guard raw.contains(where: { $0 == "_" || $0 == "." || $0 == "-" }) || raw == raw.lowercased() else {
            return raw
        }
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return raw }
        return first.uppercased() + spaced.dropFirst()
    }

    /// An ISO stamp said like a person would: "20 min. ago".
    static func relative(_ iso: String?) -> String? {
        guard let iso, let date = UserDisplayFormatters.parseISOTimestamp(iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func readable(_ iso: String) -> String {
        UserDisplayFormatters.parseISOTimestamp(iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
}
