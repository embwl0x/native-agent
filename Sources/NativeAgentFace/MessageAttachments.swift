import Foundation
import SwiftUI
import AppKit
import NativeAgentShared

// Blueprint: | `MessageAttachments.swift` | Granted transcript resources: image previews, file chips and off-main bookmark resolution |

/// The grant is the only route to an attachment's file; stale or unreadable grants retain their cause.
enum TranscriptResource {
    @concurrent nonisolated static func url(_ resource: ResourceGrant) async throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: resource.bookmark, options: [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else {
            throw WireFailure(code: "stale_attachment_grant", message: "The attachment's resource grant is stale.",
                              cause: "Ask the body for a fresh attachment reading.", effects: .none)
        }
        return url
    }

    @concurrent nonisolated static func bytes(_ resource: ResourceGrant) async throws -> Data {
        let url = try await url(resource)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

struct MessageAttachmentChipView: View {
    let attachment: FaceResolvedAttachment
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard let resource = attachment.resource else { issue = "Waiting on the attachment's resource grant."; return }
                Task {
                    do { NSWorkspace.shared.activateFileViewerSelecting([try await TranscriptResource.url(resource)]) }
                    catch { issue = error.localizedDescription }
                }
            } label: {
                Label(attachment.title, systemImage: "doc")
                    .font(NativeAgentFont.label).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .houseInset(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct MessageLocalImageAttachmentView: View {
    let attachment: FaceResolvedAttachment
    @Environment(\.quietCaptureSession) private var capture

    /// Drawn at once from its saved preview, as the original window drew it, so the row has its size before the chat lands.
    var body: some View {
        if let image = capture.map({ $0.attachmentImages[attachment.id] }) ?? attachment.preview?.png.flatMap(NSImage.init(data:)) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: 360, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text("Image unavailable").font(NativeAgentFont.label.weight(.medium))
                Text(attachment.title).font(NativeAgentFont.tag).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 160, height: 120)
            .houseInset(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Image attachment unavailable: " + attachment.title)
        }
    }
}
