import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatInboxStrip.swift` | `InboxStripContainer`: Inbox projection; reads do not resolve |

struct InboxStripContainer<Header: View>: View {
    /// Let the host place unread notes; every ask's card draws in the person's conversation as its matter's row, never here.
    @ViewBuilder let header: (InboxNotesCapsule) -> Header
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var noteIDs: [String] {
        appModel.countPart("inbox.noteIDs") { $0?.inbox.noteIDs ?? [] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        header(InboxNotesCapsule(
            ids: noteIDs,
            onAction: { id, actionID in
                try await appModel.inboxAction(id, action: actionID)

            }
        ))
        if let loadError = appModel.countPart("inbox.issue", { $0?.inbox.unread.issue }) {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help("The unread-inbox read failed; items shown may be stale. The strip retries when the inbox changes.")
                .accessibilityIdentifier("inbox-strip-load-error")
        }
        if appModel.countPart("inbox.waitingForFirstRead", { $0?.inbox.unread.value == nil && $0?.inbox.unread.issue == nil }) {
            Text("Reading updates…").font(.caption).foregroundStyle(.secondary)
        }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            do { _ = try await appModel.checkedFaceAct(.refresh(.page("inbox"))) }
            catch { appModel.setFailureStatus(error, action: "read updates") }
        }
    }
}
