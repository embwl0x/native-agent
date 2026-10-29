import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import StandingBots
import ApprovalInbox
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `MessageAttachments.swift` | Transcript-owned local image previews and attachment chips |

enum ChatAttachmentPresentation {
    static func partition(_ attachments: [PersistedAttachment]) -> (localImages: [PersistedAttachment], chips: [PersistedAttachment]) {
        let localImages = attachments.filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        let chips = attachments.filter { attachment in
            !(attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false))
        }
        return (localImages, chips)
    }
}

/// The unavailable label for an image projected by the transcript owner.
enum ChatLocalImageAttachmentPresentation {
    static func unavailableDetail(for attachment: PersistedAttachment) -> String {
        let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return "Image attachment"
    }
}

/// Attachments that cannot render inline remain visible as file chips.
struct MessageAttachmentChipView: View {
    let attachment: PersistedAttachment

    private var displayName: String {
        let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return "Attachment"
    }

    private var sizeText: String? {
        guard let byteSize = attachment.byteSize, byteSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    private var symbol: String {
        let mime = (attachment.mime ?? "application/octet-stream").lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("csv") { return "doc.plaintext" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(NativeAgentFont.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if let sizeText {
                Text(sizeText)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .houseInset(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(attachment.path ?? displayName)
        .contextMenu {
            if let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                Button {
                    ChatClipboard.copy(path)
                } label: { Label("Copy file path", systemImage: "doc.on.doc") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
    }
}

struct MessageLocalImageAttachmentView: View {
    let attachment: PersistedAttachment

    private var imagePath: String? {
        guard let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    @ViewBuilder
    var body: some View {
        if let png = attachment.preview?.png, let image = NSImage(data: png) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
                .contextMenu {
                    if let path = imagePath {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        } label: {
                            Label("Copy image path", systemImage: "doc.on.doc")
                        }
                    }
                }
        } else if attachment.preview == nil {
            Color.clear
                .frame(width: 160, height: 120)
                .overlay { ProgressView().controlSize(.small) }
                .houseInset(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("Image unavailable")
                    .font(NativeAgentFont.label.weight(.medium))
                Text(ChatLocalImageAttachmentPresentation.unavailableDetail(for: attachment))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 160, height: 120)
            .houseInset(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Image attachment unavailable: "
                    + ChatLocalImageAttachmentPresentation.unavailableDetail(for: attachment)
            )
        }
    }

}
