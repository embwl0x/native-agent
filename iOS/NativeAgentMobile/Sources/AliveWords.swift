import Foundation
import NativeAgentShared
import SwiftUI
import UIKit
// Blueprint: | `AliveWords.swift` | Count and identifier wording for phone screens |

// MARK: - Words

enum AliveWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six",
                               "seven", "eight", "nine", "ten"]

    static func spelled(_ n: Int) -> String {
        guard ones.indices.contains(n) else { return "\(n)" }
        return ones[n]
    }

    static func count(_ n: Int, _ noun: String, spelled: Bool = false) -> String {
        let number = spelled ? self.spelled(n) : n.formatted()
        return "\(number) \(n == 1 ? noun : pluralized(noun))"
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
}
