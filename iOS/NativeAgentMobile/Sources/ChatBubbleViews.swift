// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

// MARK: - Bubble

struct BubbleView: View {
    let message: ChatMessage
    var streamingHint: String = "Typing"
    // Set when this assistant bubble timed out locally. The accessory resumes
    // observation of the same signed event; it never queues a second turn.
    var isTimedOut: Bool = false
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Collapsed "N tools used" / "N skills used" summary above the
                // reply once the turn is done (assistant turns only).
                if message.role == .assistant, !message.isStreaming, !message.toolEvents.isEmpty {
                    ToolActivityView(events: message.toolEvents, isLive: false)
                        .padding(.leading, 4)
                }
                if message.isStreaming {
                    if !message.toolEvents.isEmpty, message.text.isEmpty {
                        // She's working through tools — flip through them in one box.
                        ToolActivityView(events: message.toolEvents, isLive: true)
                    } else {
                        HStack(spacing: 8) {
                            PulsingDot(color: NativeAgentPalette.agentAccent, size: 7)
                            Text(message.text.isEmpty ? streamingHint : message.text)
                                .font(AppFont.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 12)
                        .frame(minWidth: 150, maxWidth: 260, minHeight: 40, maxHeight: 40, alignment: .leading)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(NativeAgentPalette.agentAccent.opacity(0.18), lineWidth: 0.8)
                        }
                    }
                } else {
                    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                        ForEach(imageAttachments) { attachment in
                            AttachmentImagePreview(summary: attachment)
                        }
                        if attachmentCountWithoutPreview > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.fill")
                                Text(attachmentCountWithoutPreview == 1 ? "1 attachment" : "\(attachmentCountWithoutPreview) attachments")
                            }
                            .font(AppFont.tag)
                            .foregroundStyle(message.role == .user ? .white.opacity(0.92) : .secondary)
                        }
                        if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachments.isEmpty {
                            Text(message.text.isEmpty ? " " : message.text)
                                .font(AppFont.body)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(
                        message.role == .user
                            ? AnyShapeStyle(NativeAgentPalette.agentGradient)
                            : AnyShapeStyle(Color(.systemGray5)),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(message.role == .user ? .white : .primary)
                }
                // A reply timeout is not proof that the Mac failed. Keep the
                // original correlation alive and let the user resume waiting.
                if isTimedOut, let onRetry {
                    Button(action: onRetry) {
                        Label("Keep waiting", systemImage: "clock.arrow.circlepath")
                            .font(AppFont.tag.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(NativeAgentPalette.agentAccent)
                    .padding(.leading, 4)
                    .accessibilityLabel("Keep waiting for this reply")
                }
            }
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var imageAttachments: [ChatAttachmentSummary] {
        message.attachments.filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.base64?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    private var attachmentCountWithoutPreview: Int {
        max(0, message.attachments.count - imageAttachments.count)
    }
}

private struct AttachmentImagePreview: View {
    let summary: ChatAttachmentSummary

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
                .accessibilityLabel(summary.name)
        }
    }

    private var image: UIImage? {
        guard let raw = summary.base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = Data(base64Encoded: raw) else {
            return nil
        }
        return UIImage(data: data)
    }
}

// MARK: - Tool / skill activity (flip-box + collapsed summary)

/// iOS counterpart to the Mac `ToolCallGroup`. While she's working, `isLive`
/// shows ONE box that flips through tools as they fire. When done, it collapses
/// to "N tools used" / "N skills used" rows, each tappable to expand the names.
struct ToolActivityView: View {
    let events: [ToolEvent]
    let isLive: Bool
    @State private var toolsExpanded = false
    @State private var skillsExpanded = false

    // Skill use shows up as these tool calls — split into a separate
    // "N skills used" box, matching the Mac chat.
    private static let skillToolNames: Set<String> = ["read_skill", "list_skills"]
    private func isSkill(_ e: ToolEvent) -> Bool { Self.skillToolNames.contains(e.name) }

    private var ordered: [ToolEvent] { events.sorted { $0.seq < $1.seq } }
    private var skills: [ToolEvent] { ordered.filter(isSkill) }
    private var tools: [ToolEvent] { ordered.filter { !isSkill($0) } }
    private var latest: ToolEvent? { events.max(by: { $0.seq < $1.seq }) }

    var body: some View {
        if isLive { liveBox } else { collapsed }
    }

    private var liveBox: some View {
        HStack(spacing: 8) {
            PulsingDot(color: NativeAgentPalette.agentAccent, size: 7)
            Group {
                if let latest {
                    Text(latest.name)
                        .id(latest.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .font(AppFont.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 150, maxWidth: 260, minHeight: 40, maxHeight: 40, alignment: .leading)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(NativeAgentPalette.agentAccent.opacity(0.18), lineWidth: 0.8)
        }
        .animation(.easeOut(duration: 0.22), value: latest?.id)
    }

    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !tools.isEmpty {
                summaryRow(items: tools, noun: "tool",
                           icon: "wrench.and.screwdriver", expanded: $toolsExpanded)
            }
            if !skills.isEmpty {
                summaryRow(items: skills, noun: "skill",
                           icon: "text.book.closed", expanded: $skillsExpanded)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(items: [ToolEvent], noun: String, icon: String,
                            expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                    Text("\(items.count) \(noun)\(items.count == 1 ? "" : "s") used")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue {
                ForEach(items) { e in
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.caption2).foregroundStyle(.tertiary)
                        Text(e.name).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }
}
