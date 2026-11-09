import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `NewDeskTaskSheet.swift` | Typed result of body-owned Desk task creation |

enum NewDeskTaskOutcome {
    case created
    case failed(FaceActOutcome)
}
