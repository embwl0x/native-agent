import Foundation
import NativeAgentShared
import SwiftUI
import UIKit
// Blueprint: | `AliveWords.swift` | Count, identifier and timestamp wording for phone screens |

// MARK: - Words

enum AliveWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six",
                               "seven", "eight", "nine", "ten"]

    static func spelled(_ n: Int, capitalized: Bool = true) -> String {
        guard ones.indices.contains(n) else { return "\(n)" }
        let word = ones[n]
        return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

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

    static func relative(_ iso: String?) -> String? {
        guard let iso, let date = UserDisplayFormatters.parseISOTimestamp(iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func readable(_ iso: String) -> String {
        UserDisplayFormatters.parseISOTimestamp(iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
}
