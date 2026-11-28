import SwiftUI
import NativeAgentShared
import Foundation
import Observation
// Blueprint: | `InboxItemDetailSheet.swift` | Shared capsule-note rows/documents and retained actions; the typed Inbox owner settles every outcome |

extension InboxItemRecord {
    var sourceIcon: String { presentation?.icon ?? "bell.fill" }
    var sourceBadgeLabel: String { presentation?.badge ?? "SOURCE UNKNOWN" }

    var sourceWord: String {
        let label = sourceBadgeLabel
        guard label != "REM" else { return label }
        let words = label.replacingOccurrences(of: "-", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var detailEyebrow: String {
        let level = severity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !level.isEmpty, level.lowercased() != "info" else { return sourceWord }
        return "\(sourceWord) · \(AdvancedStatusWords.label(level))"
    }
}

struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    let actionFlight: InboxRowActionFlight
    let onClose: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()

    private var snapshot: PartFaceSnapshot? {
        appModel.face.slot(.page("inbox")).value(as: PartFaceSnapshot.self)
    }

    var body: some View {
        let snapshot = self.snapshot
        let row = snapshot?.drawnFace?.allRows.first { $0.id == item.id }
        let detail = row?.detail.map(TurnSecretRedactor.redactText)
        let door = self.door(detail: detail)
        VStack(alignment: .leading, spacing: 0) {
            List {
                FaceView(face: page(row: row, detail: detail, snapshot: snapshot), door: door, session: session)
            }
            .faceList()
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .macFaceStyle()
            Divider()
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 320, idealHeight: 480)
        .modifier(FaceObservation(demand: .key(.page("inbox"))))
        .onChange(of: row?.id, initial: true) { _, _ in
            guard let row, session.operation(for: item.id) == nil,
                  let read = row.actions?.first(where: { $0.id == "read" }), read.runs(from: "mac") else { return }
            session.submit(.init(section: "face:note", row: item.id), row: item.id, action: "read", value: nil,
                           call: read.call, door: door, expectedPageRevision: row.pageRevision)
        }
    }

    private var detailKey: String { "inbox-detail:" + item.id }

    private func page(row: PartFace.Row?, detail: String?, snapshot: PartFaceSnapshot?) -> PartFace {
        let heading: PartFace.Row
        if let row {
            let actions = row.actions?.filter { !["read", "view", "reply"].contains($0.id) }.map { action in
                PartFace.Action(id: action.id, label: TurnSecretRedactor.redactText(action.label), role: action.role,
                    doors: action.doors, call: action.call, open: action.open, unavailable: action.unavailable, aside: action.aside)
            }
            heading = .init(id: row.id, title: TurnSecretRedactor.redactText(row.title), at: row.at, symbol: row.symbol,
                            tone: row.tone, actions: actions, pageRevision: row.pageRevision)
        } else {
            heading = .init(id: item.id, title: item.title,
                            detail: snapshot?.error?.message ?? (snapshot == nil ? "Reading this note…" : "This note is absent from the current Inbox."))
        }
        var sections: [PartFace.Section] = [
            .init(id: "note", title: item.detailEyebrow, rows: [heading]),
        ]
        if let detail, !detail.isEmpty {
            sections.append(.init(id: detailKey, rows: [], block: .init(key: detailKey,
                text: detail.utf8.count <= PartFace.Block.inlineByteLimit ? detail : nil, revision: SHA256Hex.of(utf8: detail))))
        }
        return PartFace(sections: sections)
    }

    private func door(detail: String?) -> ClosureFaceDoor {
        let owner = appModel.pageDoor(page: "inbox", open: { _ in })
        return ClosureFaceDoor(open: { _ in }, waitingOn: owner.waitingOn, read: { request in
            guard let detail, request.key == detailKey, request.revision == SHA256Hex.of(utf8: detail) else {
                throw PartCallError(code: "inbox_detail_changed", message: "The selected note's detail changed. Open it again.")
            }
            return detail
        }, perform: { submission in
            let outcome = await actionFlight.perform { await owner.act(submission) }
            if submission.action != "read", outcome.accepted, outcome.failure == nil, outcome.effects != .unknown { onClose() }
            return outcome
        })
    }

}

/// One action flight prevents duplicate writes and preserves the terminal outcome.
@MainActor @Observable
final class InboxRowActionFlight {
    private(set) var isInFlight = false

    func perform(operation: @MainActor () async -> FaceActOutcome) async -> FaceActOutcome {
        guard !isInFlight else {
            return .interrupted(WireFailure(code: "inbox_action_pending", message: "Another note action is still waiting on its owner.",
                                            cause: nil, effects: .none))
        }
        isInFlight = true
        defer { isInFlight = false }
        return await operation()
    }
}
