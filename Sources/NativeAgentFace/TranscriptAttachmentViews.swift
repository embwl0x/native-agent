import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `TranscriptAttachmentViews.swift` | Resolved conversation attachments, Inbox acts and contact-thread feed presentation |

struct TranscriptAttachmentRoot: View {
    let box: TranscriptAttachmentBox

    var body: some View {
        if let environment = box.environment {
            TranscriptAttachmentBody(box: box)
                // Every attachment has its own host, including in detached conversations.
                .macFaceStyle()
                .environment(\.self, environment)
        }
    }
}

private struct TranscriptAttachmentBody: View {
    let box: TranscriptAttachmentBox

    var body: some View {
        content.fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in box.resized() }
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        switch box.model {
        case .resolved(let attachment, let ref, let role):
            TranscriptResolvedAttachmentView(attachment: attachment, reference: ref, role: role, retry: box.retry)
        case .table(let table, let cells): ChatMarkdownTableView(table: table, cells: cells).font(ShellType.body)
        case .otherRoom(let exchange): TranscriptOtherRoomAttachment(exchange: exchange, open: box.open)
        case .waiting(let detail): Text(detail).font(ShellType.label).foregroundStyle(.secondary).textSelection(.enabled)
        case .unavailable(let detail): Text(detail).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble).textSelection(.enabled)
        }
    }
}

private struct TranscriptResolvedAttachmentView: View {
    let attachment: FaceResolvedAttachment
    let reference: TranscriptAttachmentRef
    let role: String
    let retry: (String) -> Void
    @Environment(AppModel.self) private var appModel
    @Environment(\.transcriptOpenSettings) private var openSettings
    @State private var feedback: String?
    /// The Inbox row drawn here keeps its pending, failure and undo as the Inbox page keeps them.
    @State private var session = FacePageSession()
    @State private var activityTarget: ActivityTarget?

    private struct ActivityTarget: Identifiable {
        let reference: WorkOverviewReference
        var id: String { reference.kind.rawValue + ":" + reference.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            if let failure = attachment.failure {
                Text(failure.localizedDescription).foregroundStyle(NativeAgentShell.trouble).textSelection(.enabled)
            }
            content
            if let feedback { Text(feedback).font(ShellType.label).textSelection(.enabled) }
        }
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .accessibilityLabel(attachment.title)
        .sheet(item: $activityTarget) { target in
            MacWorkOverviewDetail(reference: target.reference) { activityTarget = nil }
        }
    }

    @ViewBuilder private var content: some View {
        switch reference {
        case .image: MessageLocalImageAttachmentView(attachment: attachment)
        case .voice:
            if let resource = attachment.resource, let transcript = attachment.text {
                VoiceNoteBubble(id: attachment.id, transcript: transcript, isOwn: role == "user", speaker: attachment.title) {
                    try await TranscriptResource.url(resource)
                }
            } else { Text("Waiting on the voice note's resource grant and transcript.").foregroundStyle(.secondary) }
        case .file: MessageAttachmentChipView(attachment: attachment)
        case .card, .approval, .trouble:
            if let face = attachment.card {
                // The Inbox row, pressed through the Inbox page's own door: the same drawn call, confirmation and answer.
                FaceView(face: face, door: appModel.pageDoor(page: "inbox", open: open), session: session)
                    .onAppear { session.notice = { words in feedback = words } }
            } else {
                Text(attachment.text ?? "Waiting on the request's presentation. Its absence does not settle it.")
                    .textSelection(.enabled)
            }
            if case .card = reference, let card = attachment.secureCard {
                ProtectedFaceEntry { CardChrome(card: card) }
            }
            if case .trouble = reference {
                HStack {
                    Button("Retry reply") { retry(attachment.message) }
                    Button("Open Settings", action: openSettings)
                }.buttonStyle(.plain)
            }
        case .envelope:
            Text(attachment.text ?? "Waiting on the message's prepared envelope.").textSelection(.enabled)
        case .table, .otherRoom: EmptyView()
        }
    }

    private func open(_ link: String) {
        feedback = nil
        Task {
            do { _ = try await MacFaceLinks.follow(link, appModel: appModel) { activityTarget = ActivityTarget(reference: $0) } }
            catch { feedback = error.localizedDescription }
        }
    }
}

private struct TranscriptOtherRoomAttachment: View {
    let exchange: OtherRoomExchange
    let open: (OtherRoomExchange) -> Void
    @Environment(AppModel.self) private var appModel

    private var contact: FaceContact? {
        appModel.face.slot(.contacts).select("contact:" + exchange.contactID, as: ContactsFace.self) {
            $0?.contacts.first { $0.id == exchange.contactID }
        }
    }

    var body: some View {
        Button { open(exchange) } label: { OtherRoomExchangePreview(exchange: exchange) }
            .buttonStyle(.plain)
            .help(contact?.label ?? "Open the contact reading; a missing contact does not mean it was removed.")
    }
}

struct TranscriptOpenSettingsKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var transcriptOpenSettings: @Sendable @MainActor () -> Void {
        get { self[TranscriptOpenSettingsKey.self] }
        set { self[TranscriptOpenSettingsKey.self] = newValue }
    }
}

/// Failure replies keep their cause; an unexpected reply never becomes a successful command.
enum TranscriptFaceReply {
    static var unexpected: WireFailure {
        WireFailure(code: "unexpected_transcript_reply", message: "The body returned an unexpected transcript reply.",
                    cause: "Inspect the face act handler and its reply contract.", effects: .unknown)
    }

    static func acknowledged(_ reply: FaceActReply) throws {
        switch reply {
        case .acknowledged: return
        case .failed(let failure), .refused(let failure): throw failure
        default: throw unexpected
        }
    }

    static func success(_ reply: FaceActReply) throws {
        switch reply {
        case .acknowledged, .accepted, .result: return
        case .committed(let committed):
            if let failure = committed.publicationFailure { throw failure }
        case .voice(let voice):
            if case .unavailable(let failure) = voice.state { throw failure }
        case .failed(let failure), .refused(let failure): throw failure
        default: throw unexpected
        }
    }
}
