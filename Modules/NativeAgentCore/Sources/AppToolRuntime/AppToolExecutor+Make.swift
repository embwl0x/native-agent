import ChatOrchestration
import Foundation
import PersistenceCore
import Studio

extension AppToolExecutor {
    /// make.add and make.read, in process: the Make studio's refs and their
    /// versions (`MakeStudio`), which the Work pane's Make tab shows.
    @MainActor
    func runMake(verb: String, input: [String: JSONValue]) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let studio = MakeStudio(dataRoot: root)
        let ref = Self.inputString(input["ref"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if verb == "read" {
            let found: MakeStudio.Meta?
            do { found = try (ref.isEmpty ? studio.newestRef() : ref).flatMap(studio.readMeta) } catch {
                return Self.failure("make_unreadable", "Make could not be read: \(error.localizedDescription)", extra: ["effects": .string("none")])
            }
            guard let meta = found else {
                return Self.failure("unknown_ref", ref.isEmpty ? "Nothing is in Make yet." : "No Make ref is called \(ref).")
            }
            var receipt: [String: JSONValue] = [
                "status": .string("ok"), "ref": .string(meta.ref),
                "versions": .array(meta.versions.map { version in
                    var row: [String: JSONValue] = [
                        "n": .int(Int64(version.n)), "path": .string(studio.url(meta.ref, version).path),
                        "created": .string(version.created),
                    ]
                    if let prompt = version.prompt { row["prompt"] = .string(prompt) }
                    if let model = version.model { row["model"] = .string(model) }
                    return .object(row)
                }),
            ]
            // What the shelf could not read stays on the receipt beside what it could.
            if let fault = MakeStudio.Shelf.shared.fault { receipt["shelf_fault"] = .string(fault) }
            return .object(receipt)
        }
        let path = Self.inputString(input["path"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.failure("invalid_input", "Pass path: the file to add to Make.") }
        let fullMac = await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName
        let file: URL
        switch await Self.fencedAttachment(path, fullMac: fullMac, dataRoot: root) {
        case .success(let found): file = found
        case .failure(let refusal): return Self.failure(refusal.reason, refusal.detail)
        }
        do {
            let added = try studio.add(file, ref: ref.isEmpty ? nil : ref)
            return .object(["status": .string("ok"), "ref": .string(added.ref), "version": .int(Int64(added.version.n)),
                            "path": .string(studio.url(added.ref, added.version).path)])
        } catch let refusal as MakeStudio.Refusal {
            return Self.failure(refusal.reason, refusal.message)
        } catch {
            return Self.failure("make_show_failed", error.localizedDescription + " Nothing was added.", extra: ["effects": .string("unknown")])
        }
    }

    /// reply.attach: an image she sends with this reply, behind the same fence as
    /// make.add, chosen into the turn's own reply.
    @MainActor
    func runReplyAttach(input: [String: JSONValue]) async -> JSONValue {
        let path = Self.inputString(input["path"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.failure("invalid_input", "Pass path: the image to send with this reply.") }
        guard let choices = ReplyChoices.current else {
            return Self.failure("no_reply", "Only a turn answering a conversation has a reply to attach to. Nothing was attached.")
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let fullMac = await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName
        switch await Self.fencedAttachment(path, fullMac: fullMac, dataRoot: root) {
        case .failure(let refusal): return Self.failure(refusal.reason, refusal.detail)
        case .success(let file):
            guard ChatGeneratedImageArtifacts.attachment(file) != nil else {
                return Self.failure("not_an_image", "\(file.lastPathComponent) is not an image a reply carries: jpg, png, gif, webp, bmp or heic. Nothing was attached.")
            }
            choices.choose(file.path)
            return .object(["status": .string("ok"), "effects": .string("none"), "attached": .string(file.path),
                            "detail": .string("Attached; it goes with this reply.")])
        }
    }
}
