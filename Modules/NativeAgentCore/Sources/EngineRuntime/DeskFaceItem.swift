import AgentConversations
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
import Studio
// Blueprint: | `DeskFaceItem.swift` | The selected Desk item or execution's canonical details, dependencies, pursuit, notes and references as Desk packet facts |

extension NativeAgentEngine {
    /// The selection the Desk face opens on: nothing, an execution, or a Desk item, each found in the current reading or named as missing.
    func deskSelectedFacts(_ snapshot: DeskPageSnapshot, selected: String?, pieces: DeskPieceShelf) -> JSONValue {
        guard let handle = selected else { return .null }
        let now = snapshot.now
        if handle.hasPrefix("execution:") {
            let id = String(handle.dropFirst("execution:".count))
            guard let job = snapshot.agentJobs.items.first(where: { $0.id == id }) else {
                return .object(["kind": .string("execution"), "id": .string(id), "found": .bool(false),
                                "unavailable": faceText(snapshot.agentJobs.unavailableReason)])
            }
            let row = WorkOverviewRead.row(for: job, now: now)
            return .object(["kind": .string("execution"), "id": .string(id), "found": .bool(true), "title": .string(row.title),
                            "text": .string(WorkOverviewRead.text(for: job)), "asking": faceText(job.request?.title),
                            "state": .string(row.stateLabel(at: now)), "at": .string(row.updatedAt)])
        }
        guard let item = snapshot.items.first(where: { $0.handle == handle }) else {
            return .object(["kind": .string("item"), "handle": .string(handle), "found": .bool(false),
                            "unavailable": faceText(snapshot.deskUnavailable)])
        }
        var plan = JSONValue.null
        if let sequenced = snapshot.plan.byHandle[item.handle] {
            let blockers: [JSONValue] = sequenced.effectiveBlockers.map { blocker -> JSONValue in
                let source = snapshot.items.first { $0.handle == blocker }
                return .object(["handle": .string(blocker), "alias": faceText(source?.alias), "title": faceText(source?.title)])
            }
            plan = .object(["done": .int(Int64(sequenced.doneCount)), "total": .int(Int64(sequenced.totalCount)),
                            "blockers": .array(blockers), "cycle": .bool(sequenced.blockedByCycle), "deferred": .bool(sequenced.isDeferred)])
        }
        let progress: JSONValue = item.progress.map { measured -> JSONValue in
            .object(["done": .int(Int64(measured.done)), "total": .int(Int64(measured.total)), "note": faceText(measured.note)])
        } ?? .null
        let notes: [JSONValue] = item.notes.map { note -> JSONValue in .object(["text": .string(note.text), "at": .string(note.ts)]) }
        let refs: [JSONValue] = item.refs.map { ref -> JSONValue in
            let target: (text: String, label: String) = switch DeskRefAffordance.action(for: ref) {
            case .open(let url, let named): (url, named)
            case .copy(let copied, let named): (copied, named)
            }
            return .object(["id": .string(ref.refId), "priority": .int(Int64(ref.priority)), "label": .string(target.label),
                            "text": .string(target.text)])
        }
        let studio = MakeStudio(dataRoot: dataRoot)
        let opened: [JSONValue] = item.refs.compactMap { pieces.facts($0, studio: studio, opened: true) }
        let onBoard = snapshot.boardItems.contains { $0.handle == handle }
        return .object([
            "kind": .string("item"), "handle": .string(item.handle), "found": .bool(true), "onBoard": .bool(onBoard),
            "alias": .string(item.alias), "itemKind": .string(item.kind.rawValue), "status": .string(item.status.rawValue),
            "project": .string(item.project), "origin": .string(item.origin.rawValue), "title": .string(item.title),
            "updatedAt": .string(item.updatedAt), "summary": faceText(item.summary), "assignee": faceText(item.assignee),
            "progress": progress, "blockedReason": faceText(item.blockedReason), "waitingOn": faceText(item.waitingOn),
            "requiresOwnerInput": .bool(item.requiresOwnerInput), "plan": plan,
            "deferAt": faceText(item.deferUntil.flatMap(DeskSequencing.parseDeferStamp).map(NativeTimestampFormat.fractionalZulu)),
            "nextUp": .bool(snapshot.plan.nextUp.contains(item.handle)),
            "pursuit": deskPursuitFacts(item, snapshot: snapshot), "notes": .array(notes), "refs": .array(refs), "pieces": .array(opened),
            "vetoable": .bool(onBoard && Self.deskItemActions(item).contains { $0.id == "veto" }),
        ])
    }

    /// A pursuit lane item still open carries its pursuit's measures, or names them unavailable; any other item carries none.
    private func deskPursuitFacts(_ item: DeskItem, snapshot: DeskPageSnapshot) -> JSONValue {
        guard DeskBoardLayout.isPursuitLaneItem(item), !item.status.isTerminal else { return .null }
        guard let pursuit = item.pursuit else { return .object(["state": .string("unavailable")]) }
        let today = snapshot.board?.deskState?.pursuitWorkSessions(on: DeskClock.dayStamp(snapshot.now), handle: item.handle)
        let score = DeskPursuitChoice.score(for: item, now: snapshot.now)
        return .object([
            "state": .string("available"), "why": .string(pursuit.why), "doneWhen": .string(pursuit.doneLooksLike),
            "sessionsUsed": .int(Int64(pursuit.sessionsUsed(in: item.workAttempts))), "maxSessions": .int(Int64(pursuit.maxSessions)),
            "sessionsToday": today.map { JSONValue.int(Int64($0)) } ?? .null, "lastWorkedAt": faceText(pursuit.lastWorkedAt),
            "score": score.map { JSONValue.double($0.total) } ?? .null,
        ])
    }
}

/// What Make holds for the pieces laid on the Desk, read once per packet from the Make shelf, the one index the Make pane draws.
struct DeskPieceShelf: Sendable {
    let loaded: Bool
    let fault: String?
    let metadata: [String: MakeStudio.Meta]

    /// A piece's facts: its Make ref, its title (the label, else Make's), what it is, its versions and the newest; opened, a text piece's
    /// words, or a table's size and first rows. Nil for a reference that is not a piece. A ref Make has not read is waiting, a fault is
    /// named, and only a complete read without it says it is missing.
    func facts(_ ref: DeskRef, studio: MakeStudio, opened: Bool) -> JSONValue? {
        guard case .url(_, let label) = ref.kind, let made = DeskPiece.makeRef(ref) else { return nil }
        var fields: [String: JSONValue] = ["id": .string(ref.refId), "ref": .string(made), "title": faceText(label), "state": .string("ready"),
            "reason": .null, "what": .null, "leaf": .null, "versions": .null, "version": .null, "newestAt": .null]
        guard let meta = metadata[made], let newest = meta.versions.last else {
            if let fault {
                fields["state"] = .string("unavailable")
                fields["reason"] = .string("Make could not be read: " + fault)
            } else { fields["state"] = .string(loaded ? "missing" : "waiting") }
            return .object(fields)
        }
        let file = studio.url(made, newest)
        let type = file.pathExtension.lowercased()
        let kind = EngineFaceWorkProjection.makeKind(file)
        let isText = MakeStudio.textTypes.contains(type)
        let delimiter = SheetTable.delimiter(type: type)
        if label == nil { fields["title"] = .string(EngineFaceWorkProjection.versionTitle(made, newest)) }
        // An SVG is a picture to whoever looks at it, and the Mac draws it as one.
        fields["what"] = .string(delimiter != nil ? "sheet" : isText ? "document" : kind == "image" || type == "svg" ? "picture"
            : kind == "web" ? "page" : "file")
        fields["leaf"] = .string(kind == "file" ? "preview" : kind)
        fields["versions"] = .int(Int64(meta.versions.count))
        fields["version"] = .string(String(newest.n))
        fields["newestAt"] = faceText(NativeTimestampFormat.parseISO8601(newest.created).map(NativeTimestampFormat.fractionalZulu))
        guard opened else { return .object(fields) }
        if let delimiter {
            do { fields["table"] = try Self.table(file, delimiter: delimiter) }
            catch { fields["reason"] = .string("I couldn't read its table: " + error.localizedDescription) }
            return .object(fields)
        }
        guard isText else { return .object(fields) }
        do {
            let read = try Self.words(file)
            fields["text"] = .string(read.text)
            fields["textCut"] = .bool(read.cut)
            fields["format"] = .string(["md", "markdown"].contains(type) ? "markdown" : "plain")
        } catch { fields["reason"] = .string("I couldn't read its words: " + error.localizedDescription) }
        return .object(fields)
    }

    /// A table piece's size, its first rows as the file's own text and its file name, read whole up to the words Make takes in hand.
    static func table(_ file: URL, delimiter: Unicode.Scalar) throws -> JSONValue {
        // The file's own size bounds the read before any byte of it is loaded.
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
        guard size <= MakePreviewFace.wordsLimit else {
            throw PartCallError(code: "table_too_large", message: "it is over 2 MB; make.read gives its file")
        }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let table = SheetTable(text, delimiter: delimiter)
        var first = table
        first.rows = Array(table.rows.prefix(8))
        // The face shows 4 KiB of these rows; a field of megabytes is cut here, on a character, before it rides the packet.
        var shown = Data(first.text.utf8.prefix(4096))
        while !shown.isEmpty, String(data: shown, encoding: .utf8) == nil { shown.removeLast() }
        return .object(["rows": .int(Int64(table.rows.count)), "columns": .int(Int64(table.width)),
                        "first": .string(String(decoding: shown, as: UTF8.self)),
                        "file": .string(file.lastPathComponent)])
    }

    /// A text piece's words, at most a page's inline block, cut on a character boundary.
    static func words(_ file: URL) throws -> (text: String, cut: Bool) {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let limit = PartFace.Block.inlineByteLimit
        let cut = data.count > limit
        var bytes = data.prefix(limit)
        // A cut can fall inside a character, which is at most four bytes: drop its partial bytes.
        for _ in 0..<4 {
            if let text = String(data: bytes, encoding: .utf8) { return (text, cut) }
            guard cut, !bytes.isEmpty else { break }
            bytes = bytes.dropLast()
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
