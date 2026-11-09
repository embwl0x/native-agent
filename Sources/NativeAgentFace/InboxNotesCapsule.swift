import SwiftUI
import NativeAgentShared
import Foundation
import CryptoKit
// Blueprint: | `InboxNotesCapsule.swift` | Shared unread-note capsule/list, bounded continuations and checked batch read outcomes |

struct InboxNotesCapsule: View {
    let ids: [String]
    let onAction: @MainActor (String, String) async throws -> Void
    @Environment(AppModel.self) private var appModel

    @State private var showsList = false
    @State private var selectedItem: InboxItemRecord?
    @State private var actionFlight = InboxRowActionFlight()
    @State private var isMarkingAll = false
    @State private var failedReads: [String: String] = [:]
    @State private var session = FacePageSession()

    var body: some View {
        let unread = ids
        ZStack {
            if !unread.isEmpty || !failedReads.isEmpty {
                FaceView(face: PartFace(sections: [
                    .init(id: "capsule", style: .flow, rows: [
                        .init(id: "capsule", title: "", actions: [
                            .init(id: "open", label: failedReads.isEmpty
                                  ? "\(unread.count) \(unread.count == 1 ? "update" : "updates")"
                                  : "\(failedReads.count) updates need review", open: "page:inbox/notes"),
                        ]),
                    ]),
                ]), open: { _ in showsList.toggle() }, act: { _, _, _ in })
                .help("Unread notes")
                .accessibilityLabel(failedReads.isEmpty
                                    ? "\(unread.count) unread \(unread.count == 1 ? "update" : "updates")"
                                    : "\(failedReads.count) updates could not be marked read")
                .accessibilityIdentifier("chat.notes.capsule")
                .transition(NativeAgentMotion.fade)
                .popover(isPresented: $showsList, arrowEdge: .bottom) {
                    list(unread)
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            InboxItemDetailSheet(
                item: item,
                allItems: appModel.countPart("inbox.detailRows") { $0?.inbox.rows ?? [] },
                onAction: { actionID in
                    await actionFlight.perform {
                        try await onAction(item.id, actionID)
                    }
                },
                onClose: { selectedItem = nil }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func list(_ unread: [String]) -> some View {
        List {
            FaceView(face: notesPage(unread, start: 0), door: notesDoor(unread), session: session)
        }
        .environment(\.faceInList, true)
        .listStyle(.plain)
        .macFaceStyle()
        .frame(width: 360, height: (min(CGFloat(unread.count), 8) + 2) * 44)
    }

    private func notesRevision(_ unread: [String]) -> String {
        SHA256.hash(data: Data(unread.map { String($0.utf8.count) + ":" + $0 }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private var failureText: String {
        failedReads.keys.sorted().compactMap { id in failedReads[id].map { id + ": " + $0 } }.joined(separator: "\n\n")
    }

    private func notesPage(_ unread: [String], start: Int) -> PartFace {
        let slice = unread.dropFirst(start).prefix(256)
        let rows: [PartFace.Row] = slice.map { id in
            guard let item = appModel.countPart("inbox.row.\(id)", { $0?.inbox.rows.first { $0.id == id } }) else {
                return .init(id: id, title: "Waiting on this update's reading…", tone: .quiet)
            }
            return .init(id: id, title: item.title, detail: item.summary, at: item.created_at, symbol: item.sourceIcon,
                         tone: item.severity == "actionable" ? .attention : nil, actions: [
                .init(id: "open", label: "Open", open: "page:inbox/" + id,
                      unavailable: isMarkingAll ? "Waiting on the current read operation." : nil),
            ])
        }
        let (next, overflow) = start.addingReportingOverflow(slice.count)
        var sections: [PartFace.Section] = [
            .init(id: "notes", title: "Updates", rows: rows,
                  more: !overflow && next < unread.count ? .init(next: String(next), total: unread.count,
                        revision: notesRevision(unread), read: .init("inbox.notes")) : nil,
                  revision: notesRevision(unread)),
            .init(id: "mark-read", style: .flow, rows: [
                .init(id: "mark-read", title: "", actions: [
                    .init(id: "read", label: "Mark all read", call: batchCall(unread),
                          unavailable: unread.isEmpty ? "No unread notes in this reading."
                            : actionFlight.isInFlight ? "Waiting on the selected note's action." : nil),
                ]),
            ]),
        ]
        if !failedReads.isEmpty {
            sections.append(.init(id: "failed", title: "Read outcomes", rows: [], block: .init(key: "inbox-read-outcomes",
                text: failureText.utf8.count <= PartFace.Block.inlineByteLimit ? failureText : nil,
                revision: notesRevision([failureText]))))
        }
        if overflow {
            sections.append(.init(id: "cursor-failed", rows: [
                .init(id: "cursor-failed", title: "Further notes are unavailable: the collection position exceeds this window's range.", tone: .failed),
            ]))
        }
        return PartFace(sections: sections)
    }

    private func batchCall(_ unread: [String]) -> PartFace.Call {
        .init("inbox.mark_read", ["ids": .array(unread.map(PartFace.Value.string))])
    }

    private func notesDoor(_ unread: [String]) -> ClosureFaceDoor {
        ClosureFaceDoor(open: { link in
            guard !isMarkingAll,
                  let item = appModel.countPart("inbox.open", { $0?.inbox.rows.first { "page:inbox/" + $0.id == link } }) else { return }
            showsList = false
            DispatchQueue.main.async { selectedItem = item }
        }, waitingOn: "the Inbox", read: { request in
            guard request.key == "inbox-read-outcomes", request.revision == notesRevision([failureText]) else {
                throw PartCallError(code: "inbox_read_changed", message: "The note-read outcomes changed. Open updates again.")
            }
            return failureText
        }, pageRead: { request in
            guard request.expectedCall == PartFace.Call("inbox.notes") else {
                throw PartCallError(code: "inbox_read_changed", message: "The notes collection changed. Open updates again.")
            }
            let start: Int
            if request.revision != notesRevision(unread) {
                start = request.anchor.flatMap { unread.firstIndex(of: $0) } ?? 0
            } else if let cursor = request.cursor, let offset = Int(cursor), offset >= 0, offset <= unread.count { start = offset }
            else {
                throw PartCallError(code: "inbox_cursor_invalid", message: "The notes cursor is invalid. Open updates again.")
            }
            return notesPage(unread, start: start)
        }, perform: { submission in
            guard submission.row == "mark-read", submission.action == "read",
                  case .array(let values)? = submission.expectedCall.args["ids"] else {
                return .interrupted(WireFailure(code: "inbox_action_changed", message: "The unread-note operation changed. Open updates again.",
                                                cause: nil, effects: .none))
            }
            if submission.checking {
                return .interrupted(WireFailure(code: "inbox_read_unconfirmed", message: "Read the Inbox to check which notes were marked read.",
                                                cause: nil, effects: .unknown))
            }
            guard submission.expectedCall == batchCall(unread), !isMarkingAll, !actionFlight.isInFlight else {
                return .interrupted(WireFailure(code: "inbox_action_changed", message: "The unread notes changed. Open updates again.",
                                                cause: nil, effects: .none))
            }
            isMarkingAll = true
            defer { isMarkingAll = false }
            var failures: [String: String] = [:]
            var failureEffects = FaceEffects.none
            var completed = false
            for value in values {
                guard case .string(let id) = value else {
                    return .interrupted(WireFailure(code: "inbox_ids_invalid", message: "The read operation contains an invalid note identity.",
                                                    cause: nil, effects: completed ? .known : .none))
                }
                do {
                    try Task.checkCancellation()
                    try await onAction(id, "read")
                    completed = true
                }
                catch {
                    let outcome = FaceActOutcome.interrupted(error)
                    failures[id] = TurnSecretRedactor.redactText(error.localizedDescription)
                    if outcome.effects == .unknown { failureEffects = .unknown }
                    else if outcome.effects == .known, failureEffects != .unknown { failureEffects = .known }
                    if Task.isCancelled { break }
                }
            }
            failedReads = failures
            if failures.isEmpty {
                showsList = false
                return .init(words: "Marked the selected notes read.", effects: completed ? .known : .none, accepted: true)
            }
            let effects: FaceEffects = failureEffects == .unknown ? .unknown : completed ? .known : failureEffects
            return .interrupted(WireFailure(code: "inbox_read_partial", message: "Some notes could not be confirmed read.",
                                            cause: "Read outcomes lists each affected note and its owner's cause.", effects: effects))
        })
    }
}
