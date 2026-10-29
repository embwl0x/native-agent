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

// Blueprint: | `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops and scroll event bridges with mounted-page visibility |

/// The whole room accepts attachments, including its scrollback and composer.
/// A neutral, stationary outline is also quiet with Reduce Motion enabled.
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

struct ScrollWheelCatcher: NSViewRepresentable {
    /// Hidden chats keep their monitor installed but do not report scroll events.
    var isActive: Bool = true
    /// A left press inside the view, as its distance from the view's top.
    var onPress: ((CGFloat) -> Void)? = nil
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.onPress = onPress
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onPress = onPress
        nsView.isActive = isActive
    }

    static func dismantleNSView(_ nsView: ScrollWheelNSView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

final class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onPress: ((CGFloat) -> Void)?
    var isActive: Bool = true
    nonisolated(unsafe) private var monitor: Any?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func stopMonitoring() {
        removeMonitor()
        onScroll = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self, self.isActive else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard event.window === self.window, self.bounds.contains(point) else { return event }
            if event.type == .leftMouseDown {
                self.onPress?(self.isFlipped ? point.y : self.bounds.height - point.y)
            } else if abs(event.scrollingDeltaY) > 0.5 || abs(event.scrollingDeltaX) > 0.5 {
                self.onScroll?(event.scrollingDeltaY)
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
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
    model: String,
    selected: String
) -> String? {
    let normalized = ProvidersFacade.normalizedReasoningEffort(from: catalog, model: model, selected: selected)
    guard normalized != selected else { return nil }
    return "Saved think level '\(selected)' is unsupported for \(model). Save to use \(normalized)."
}
