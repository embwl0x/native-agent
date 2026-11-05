import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+Notices.swift` | One condition-bound banner lane for chat, sync and voice notices |

extension ChatView {
    /// Sync failures share the banner lane without triggering another read.
    var chatBanners: [MobileChatBanner] {
        var banners: [MobileChatBanner] = []
        if let offline = bridgeClient.offlineBannerMessage {
            banners.append(MobileChatBanner(id: "offline", message: offline, systemImage: "wifi.slash", tint: .orange))
        }
        if let syncError = MacSyncErrorBannerPresentation.visibleMessage(
            syncError: sync.syncError, dismissedMessage: dismissedSyncError
        ) {
            banners.append(MobileChatBanner(
                id: "sync", message: syncError, systemImage: "exclamationmark.icloud", tint: .orange,
                dismissLabel: "Dismiss sync warning",
                action: ("Connection", { showsSyncConnection = true }),
                onDismiss: { dismissedSyncError = syncError }
            ))
        }
        if let error = store.errorBanner {
            banners.append(MobileChatBanner(
                id: "chat", message: error, systemImage: "exclamationmark.triangle.fill", tint: .red,
                dismissLabel: "Dismiss chat error",
                onDismiss: { store.dismissErrorBanner() }
            ))
        }
        if let voiceErr = voiceInput.error {
            banners.append(MobileChatBanner(
                id: "voice", message: voiceErr, systemImage: "mic.slash.fill", tint: .orange,
                dismissLabel: "Dismiss voice input error",
                action: voiceErr.localizedCaseInsensitiveContains("permission")
                    || voiceErr.localizedCaseInsensitiveContains("settings")
                    ? ("Open Settings", { voiceInput.openSettings() })
                    : nil,
                onDismiss: { voiceInput.error = nil }
            ))
        }
        if let speechErr = voiceOutput.error {
            banners.append(MobileChatBanner(
                id: "speech", message: speechErr, systemImage: "speaker.slash.fill", tint: .orange,
                dismissLabel: "Dismiss spoken reply error",
                onDismiss: { voiceOutput.error = nil }
            ))
        }
        return banners
    }
}

struct MobileChatBanner: Identifiable {
    let id: String
    let message: String
    let systemImage: String
    let tint: Color
    /// Nil leaves a condition-bound notice visible until its condition ends.
    var dismissLabel: String? = nil
    var action: (title: String, handler: () -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    /// Changed text in the same slot must be treated as a new notice.
    var key: String { id + "\u{1F}" + message }
}

struct MobileChatBannerLane: View {
    let banners: [MobileChatBanner]
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var order: [String] = []

    private var shown: MobileChatBanner? {
        banners.first { $0.key == order.last } ?? banners.last
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let shown {
                MobileChatIssueBanner(banner: shown, moreCount: banners.count - 1) {
                    order.removeAll { $0 == shown.key }
                    order.insert(shown.key, at: 0)
                }
                .id(shown.key)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown?.key)
        .onChange(of: banners.map(\.key), initial: true) { _, keys in
            order = order.filter(keys.contains) + keys.filter { !order.contains($0) }
        }
    }
}

/// Give error actions their own row so long guidance fits compact phones and large text; keep the close target accessible and outcome-specific.
private struct MobileChatIssueBanner: View {
    let banner: MobileChatBanner
    let moreCount: Int
    let onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: banner.systemImage)
                    .foregroundStyle(banner.tint)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                Text(banner.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, banner.onDismiss == nil ? 6 : 0)
                if let onDismiss = banner.onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(banner.dismissLabel ?? "Dismiss")
                }
            }

            if banner.action != nil || moreCount > 0 {
                HStack(spacing: 16) {
                    if let action = banner.action {
                        Button(action.title, action: action.handler)
                            .font(.callout.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    if moreCount > 0 {
                        Button("\(moreCount) more", action: onMore)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityHint("Shows the next notice")
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(banner.tint.opacity(0.14))
        .accessibilityElement(children: .contain)
    }
}
