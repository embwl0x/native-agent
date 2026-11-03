import Foundation
// Blueprint: | `MobileVoicePreference.swift` | Read-only Mac voice preference carried by the core mobile snapshot |

/// A projection of VoicePreference, never a second editable voice setting.
public struct MobileVoicePreference: Codable, Sendable, Equatable {
    public let name: String
    public let quiet: Bool
    public let nativeIdentifier: String?
    public let nativeName: String?
    public let nativeLanguage: String?
    public init(name: String, quiet: Bool, nativeIdentifier: String?, nativeName: String?, nativeLanguage: String?) {
        self.name = name; self.quiet = quiet
        self.nativeIdentifier = nativeIdentifier; self.nativeName = nativeName; self.nativeLanguage = nativeLanguage
    }
}
