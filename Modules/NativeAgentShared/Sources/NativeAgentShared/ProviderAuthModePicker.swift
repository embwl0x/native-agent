import Foundation
// Blueprint: | `ProviderAuthModePicker.swift` | Canonical advertised authentication choices and unresolved saved-mode presentation |

public struct ProviderAuthModePicker: Equatable, Sendable {
    public let supportedModes: [String]
    public let selectedMode: String
    public let unresolvedSavedMode: String?
    public var canSave: Bool { supportedModes.contains(selectedMode) }

    public init(advertisedModes: [String], savedMode: String?) {
        var seen = Set<String>()
        supportedModes = advertisedModes.compactMap { raw in
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["api_key", "oauth"].contains(mode) && seen.insert(mode).inserted ? mode : nil
        }
        let saved = savedMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let saved, supportedModes.contains(saved) {
            selectedMode = saved
            unresolvedSavedMode = nil
        } else {
            selectedMode = ""
            unresolvedSavedMode = saved?.isEmpty == false ? saved : nil
        }
    }
}
