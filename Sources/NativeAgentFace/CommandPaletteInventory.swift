import Foundation
import NativeAgentShared
// Blueprint: | `CommandPaletteInventory.swift` | Local saved navigation and mounted Desk palette callbacks |

enum PaletteSavedDestination: Hashable, Sendable {
    case botReply(botID: UUID, entryID: UUID)
    case dream(String)
    case memory(String)
}

struct DeskPaletteScope {
    let onSelect: (String) -> Void
    let onCommand: (DeskCommandRequest) -> Void
}
