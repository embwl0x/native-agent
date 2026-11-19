import SwiftUI
import Foundation
import NativeAgentShared
import AppKit
// Blueprint: | `ProviderCards.swift` | Provider notes |

struct ProviderNote: View {
    let text: String
    var color: Color = NativeAgentShell.secondary

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
