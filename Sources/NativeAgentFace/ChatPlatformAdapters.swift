import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops with mounted-page visibility |

/// Accept attachments across the room with a stationary outline so Reduce Motion remains quiet.
struct ChatAttachmentDropTarget: ViewModifier {
    var isEnabled = true
    var contentTypes = ChatAttachmentTypeResolver.attachmentTypeIdentifiers
    var onDrop: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrop(
                of: isEnabled ? contentTypes : [],
                isTargeted: $isTargeted
            ) { providers in
                guard isEnabled else { return false }
                return onDrop(providers)
            }
            .overlay {
                if isEnabled && isTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(NativeAgentShell.softFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(NativeAgentShell.secondary.opacity(0.45), lineWidth: 1)
                        }
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transaction { $0.animation = nil }
                }
            }
    }
}
