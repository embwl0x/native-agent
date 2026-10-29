import Foundation
// Blueprint: | `OrganismToken.swift` | `OrganismToken` enum; `canonicalToken` |

// Stable identifier normalization shared by field and prediction records.
enum OrganismToken {
    static func canonicalToken(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasDash = false
        for scalar in lower.unicodeScalars {
            let isLetter = CharacterSet.letters.contains(scalar)
            let isDigit = CharacterSet.decimalDigits.contains(scalar)
            if isLetter || isDigit {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= 48 { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
