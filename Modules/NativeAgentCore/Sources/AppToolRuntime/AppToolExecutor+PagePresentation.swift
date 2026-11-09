import ChatToolParsing
import Dispatcher
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `AppToolExecutor+PagePresentation.swift` | screenshot results, quiet page reads, and a door-only page's read (summary, actions, Trust's access rows) |

/// Where a door-only page's access is set: on Trust (with Trust's snapshot as the door last read it, nil when Trust never published), or
/// nowhere of its own.
public enum DoorPageAccess {
    case trust(PartFaceSnapshot?)
    case notOnTrust
}

extension AppToolExecutor {
    /// A door-only page has no screen: it is a group of the door's actions. It reads as its summary, the actions registered on it and, for
    /// a page whose access the person sets on Trust, the Trust page's own rows for it (`integration.<page>.*`), as Trust draws them.
    /// Trust's words for a face that did not draw stand in for those rows; a page Trust draws no row for says so.
    @MainActor public static func doorPageRead(_ page: QuietToolPage, access: DoorPageAccess, turn: Turn?) -> [JSONValue] {
        func section(_ heading: String, _ lines: [String]) -> JSONValue {
            .object(["heading": .string(heading), "lines": .array(lines.map(JSONValue.string))])
        }
        var content = [section(page.title, [page.summary])]
        do {
            let registered = try AppActions.on(page: page.id, turn: turn).filter { $0.page == page.id }.map(\.id)
            content.append(section("Registered actions", registered.isEmpty ? ["None."] : registered))
        } catch {
            content.append(.object(["heading": .string("Registered actions"), "lines": .array([]), "status": .string("unavailable"),
                "reason": .string("action_catalog_unavailable"), "detail": .string(error.localizedDescription),
                "remedy": Repair.remedy(owner: "Registered actions", nextCall: nil, tap: nil,
                    instruction: "Repair the action catalog before reading this page's registered actions.")]))
        }
        guard case .trust(let trust) = access else { return content }
        guard let snapshot = trust else { return content + [section("Access in Trust", ["Trust has not published its page."])] }
        let prefix = "integration." + page.id + "."
        let rows = ((snapshot.levers ?? []) + (snapshot.drawnFace?.sections ?? [])).flatMap(\.rows).filter { $0.id.hasPrefix(prefix) }
        func lines(_ words: String) -> [String] { words.components(separatedBy: "\n").filter { !$0.isEmpty } }
        if snapshot.drawnFace == nil, rows.isEmpty {
            return content + [section("Access in Trust", lines(snapshot.text(title: "Trust", door: true)))]
        }
        guard !rows.isEmpty else { return content + [section("Access in Trust", ["Trust draws no switch for \(page.title)."])] }
        return content + [section("Access in Trust", lines(PartFace(sections: [.init(id: "access", rows: rows)]).text(door: true)))]
    }

    /// PNG outputs: excluded from local/off-disk backup, export and phone sync; listed in PrivacyMap. The returned path is a live output artifact.
    public static func pageScreenshotResult(
        page: QuietToolPage, tabKey: String, dataRoot: URL,
        rendered: (data: Data, width: Int, height: Int), imageSink: LocalToolImage.Sink?
    ) -> JSONValue {
        // Every picture is also a file, so whoever asked can open the PNG.
        let folder = dataRoot
            .appendingPathComponent("diagnostics/page_shots", isDirectory: true)
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let file = folder.appendingPathComponent("\(page.id)\(tabKey.isEmpty ? "" : "-" + tabKey)-\(stamp)-\(UUID().uuidString.lowercased()).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try rendered.data.write(to: file, options: .atomic)
        } catch {
            var failure = Self.ownedFailure(error, code: "page_image_save_failed", owner: file.path,
                instruction: "Inspect the output directory and reported storage error; rendering succeeded, but saving was not verified.",
                next: ["action": .string("files.list"), "args": .object(["path": .string(folder.path)])], effects: .unknown).objectValue ?? [:]
            failure["attempted_path"] = .string(file.path)
            return .object(failure)
        }
        do {
            // The current file stays protected until delivery. Inline delivery owns the encoded bytes, so later trims cannot invalidate pixels already handed
            // to an active model continuation.
            try prunePageShots(in: folder, preserving: file)
        } catch {
            return AppToolExecutor.doorRefusal("page_image_retention_failed", "The PNG was saved, but retention failed: \(error.localizedDescription)",
                remedy: "inspect", "Use the saved PNG; delivery was not attempted. Inspect the reported retention error before another screenshot.",
                next: ["action": .string("files.read"), "args": .object(["path": .string(file.path)])],
                extra: ["path": .string(file.path), "effects": .string("occurred")])
        }
        // Text-only bridge calls have no image continuation, so return the file path.
        if imageSink == nil {
            return .object([
                "status": .string("ok"), "page": .string(page.id), "title": .string(page.title),
                "path": .string(file.path),
                "width": .int(Int64(rendered.width)), "height": .int(Int64(rendered.height)),
                "note": .string("An offscreen drawing saved as a PNG; this call has no turn to show pixels in."),
            ])
        }
        guard case .object(var delivery) = LocalToolImage.deliverPNG(
            rendered.data, name: "\(page.id).png",
            width: rendered.width, height: rendered.height, sink: imageSink
        ) else {
            return AppToolExecutor.doorRefusal("page_image_delivery_failed", "The PNG was saved; delivery to the model was not verified.",
                remedy: "inspect", "Read the saved PNG; do not render another copy to recover delivery.",
                next: ["action": .string("files.read"), "args": .object(["path": .string(file.path)])],
                extra: ["path": .string(file.path), "effects": .string("occurred")])
        }
        if !ChatToolOutcome.outputLooksSuccessful(.object(delivery)) {
            delivery["reason"] = .string("page_image_delivery_failed")
            delivery["effects"] = .string("occurred")
            delivery["remedy"] = Repair.reconcile(instruction: "Read the saved PNG; resolve the reported delivery cause before sending pixels again.",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("files.read"),
                    "args": .object(["path": .string(file.path)])])]))
        }
        delivery["page"] = .string(page.id)
        delivery["title"] = .string(page.title)
        delivery["path"] = .string(file.path)
        delivery["note"] = .string(
            "An offscreen drawing of this page, not a capture of the screen. The app was not brought "
            + "forward and nothing on screen changed.")
        return .object(delivery)
    }

    /// Replaceable offscreen pictures: seven days, 64 files, 64 MiB. The picture being returned is always kept, even if it alone exceeds a bound.
    private static func prunePageShots(in folder: URL, preserving current: URL, now: Date = Date()) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "png" }
        var captures: [(url: URL, bytes: Int, modified: Date)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, let modified = values.contentModificationDate else { continue }
            captures.append((file, bytes, modified))
        }
        captures.sort {
            $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified < $1.modified
        }
        var count = captures.count
        var bytes = captures.reduce(0) { $0 + $1.bytes }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for capture in captures where capture.url != current {
            guard capture.modified < cutoff || count > 64 || bytes > 64 * 1024 * 1024 else { continue }
            try FileManager.default.removeItem(at: capture.url)
            count -= 1
            bytes -= capture.bytes
        }
    }

    @MainActor public static func agentViewRead(
        input: [String: JSONValue], rooms: [String], activeSessionID: String,
        paneText: (String, String) async -> String
    ) async -> JSONValue {
        let tabs = JSONValue.array(rooms.map { .string($0) })
        let room = pageInputText(input["room"]).lowercased()
        guard !room.isEmpty else {
            return AppToolExecutor.pageReadResult(page: "agent_view", fields: ["status": .string("ok"), "title": .string("Agent view"), "tabs": tabs])
        }
        guard rooms.contains(room) else {
            return AppToolExecutor.doorRefusal("unknown_room", "The Agent view has no tab called that.",
                remedy: "read_tabs", "Read the available tabs, then pass one as item on agent_view.",
                next: ["page": .string("agent_view")], extra: ["requested": .string(room), "tabs": tabs])
        }
        let named = pageInputText(input["session_id"])
        let scope = named.isEmpty ? activeSessionID : named
        return AppToolExecutor.pageReadResult(page: "agent_view", fields: [
            "status": .string("ok"), "title": .string("Agent view"), "room": .string(room), "session_id": .string(scope),
            "content": .string(await paneText(room, scope)),
        ])
    }

    @MainActor public static func contextReceiptRead(
        input: [String: JSONValue], activeSessionID: String,
        read: (String) async -> [(id: String, label: String)]
    ) async -> JSONValue {
        let sessionId = [pageInputText(input["session_id"]), pageInputText(input["__session_id"])]
            .first { !$0.isEmpty } ?? activeSessionID
        let lines = await read(sessionId)
        return AppToolExecutor.pageReadResult(page: "context", fields: [
            "status": .string("ok"),
            "title": .string("Context"),
            "session_id": .string(sessionId),
            "content": .array(lines.map { .string($0.label) }),
            "rows": .array(lines.map { .object(["id": .string($0.id), "label": .string($0.label)]) }),
        ])
    }

    private static func pageInputText(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
