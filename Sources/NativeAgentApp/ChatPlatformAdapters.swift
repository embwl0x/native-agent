import SwiftUI
import EngineRuntime
import AppKit
import CoreGraphics
import ScreenVision
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
import ProviderRouting
import TelegramBot

// Blueprint: | `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops with mounted-page visibility; Telegram allowlist presentation |

/// Accept attachments across the room with a stationary outline so Reduce Motion remains quiet.
struct ChatAttachmentDropTarget: ViewModifier {
    var isEnabled = true
    var contentTypes = ChatAttachmentTypeResolver.attachmentContentTypes
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

struct TelegramAllowlistPresentation: Equatable {
    let chatIDs: Set<String>
    let userIDs: Set<String>
    let invalidTokens: [String]

    var acceptedCount: Int { chatIDs.union(userIDs).count }

    var isValidAndConfigured: Bool { acceptedCount > 0 && invalidTokens.isEmpty }
    var statusLabel: String {
        isValidAndConfigured ? "Allowlist configured" : "Add valid Telegram IDs before using this bot"
    }
}

func telegramAllowlistPresentation(chats: String, users: String) -> TelegramAllowlistPresentation {
    let chat = parseTelegramNumericIDs(chats)
    let user = parseTelegramNumericIDs(users)
    return TelegramAllowlistPresentation(
        chatIDs: Set(chat.canonicalIDs),
        userIDs: Set(user.canonicalIDs),
        invalidTokens: chat.invalidTokens + user.invalidTokens
    )
}

func telegramAuthorizationHasUnsavedChanges(
    enabled: Bool,
    requireMention: Bool,
    allowlist: TelegramAllowlistPresentation,
    savedEnabled: Bool?,
    savedRequireMention: Bool?,
    savedChatIDs: [String]?,
    savedUserIDs: [String]?
) -> Bool {
    guard let savedEnabled, let savedRequireMention, let savedChatIDs, let savedUserIDs else { return true }
    let saved = telegramAllowlistPresentation(chats: savedChatIDs.joined(separator: ","), users: savedUserIDs.joined(separator: ","))
    return enabled != savedEnabled
        || requireMention != savedRequireMention
        || allowlist.chatIDs != saved.chatIDs
        || allowlist.userIDs != saved.userIDs
        || !saved.invalidTokens.isEmpty
        || !allowlist.invalidTokens.isEmpty
}

func telegramReasoningEffortMismatch(
    from catalog: ModelCatalogResponse?,
    providers: [ProviderInfo],
    providerID: String,
    model: String,
    selected: String
) -> String? {
    let normalized = ProvidersFacade.normalizedReasoningEffort(from: catalog, providers: providers,
        providerID: providerID, model: model, selected: selected)
    guard normalized != selected else { return nil }
    return "Saved think level '\(selected)' is unsupported for \(model). Save to use \(normalized)."
}
