import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+SettingsFeed.swift` | Native settings readers select only their finished settings group |

extension AppModel {
    var settingsPersonaDisplayName: String {
        face.slot(.settings).select("persona.displayName", as: SettingsFace.self) { $0?.persona.displayName ?? "" }
    }
}
