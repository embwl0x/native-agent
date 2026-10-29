import Dispatcher
import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import PersistenceCore
import Studio
import TrustCenter
import MemoryV2

// Blueprint: | `AppToolExecutor+Make.swift` | `AppToolExecutor` Make actions: studio ref reads/writes, intake reads and reply image attachment behind the workspace fence |

extension AppToolExecutor {
    @MainActor
    func runStudioIntakeRead(input: [String: JSONValue], surface: String) async -> JSONValue {
        guard MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains(MemoryRecordDisclosurePolicy.canonicalSurface(surface)) else {
            return Self.failure("private_surface_required", "Studio intake is available only on private surfaces.")
        }
        let root = securityCenter.dataRoot
        do {
            let offset: Int
            if case .int(let value)? = input["offset"], let exact = Int(exactly: value) { offset = exact }
            else if input["offset"] == nil { offset = 0 }
            else { throw PersistenceCoreError.ioFailure("Studio intake offset must be an integer.") }
            return try await SwiftNativeStudioStore(dataRoot: root).encounterIntakePage(
                kind: input["kind"]?.scalarText ?? "", offset: offset, snapshot: input["snapshot"]?.scalarText)
        } catch {
            return Self.failure("studio_intake_unavailable", error.localizedDescription, extra: ["effects": .string("none")])
        }
    }

    /// make.add and make.read, in process: the Make studio's refs and their
    /// versions (`MakeStudio`), which the Work pane's Make tab shows.
    @MainActor
    func runMake(verb: String, input: [String: JSONValue]) async -> JSONValue {
        let root = securityCenter.dataRoot
        let studio = MakeStudio(dataRoot: root)
        let ref = input["ref"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if verb == "read" {
            let found: MakeStudio.Meta?
            do { found = try (ref.isEmpty ? studio.newestMeta() : studio.readMeta(ref)) } catch {
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
            if let fault = quietHost()?.makeShelfFault { receipt["shelf_fault"] = .string(fault) }
            return .object(receipt)
        }
        let path = input["path"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.failure("invalid_input", "Pass path: the file to add to Make.") }
        let file: URL
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        if MakeStudio.generatedImagePaths.contains(candidate.path),
           (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
           !connectorPathIsSensitiveData(candidate, dataRoot: root) {
            // Only the native receipt's actual outputs have this provenance;
            // every arbitrary file still goes through the workspace fence.
            file = candidate
        } else {
            switch await SwiftNativeSecurityCenter.fencedAttachment(path, dataRoot: root) {
            case .success(let found): file = found
            case .failure(let refusal): return Self.failure(refusal.reason, refusal.detail)
            }
        }
        do {
            let added = try studio.add(file, ref: ref.isEmpty ? nil : ref,
                prompt: input["prompt"]?.scalarText, model: input["model"]?.scalarText)
            return .object(["status": .string("ok"), "ref": .string(added.ref), "version": .int(Int64(added.version.n)),
                            "path": .string(studio.url(added.ref, added.version).path)])
        } catch let refusal as MakeStudio.Refusal {
            return Self.doorRefusal(refusal.reason, refusal.message, remedy: "inspect",
                "Read Make's latest retained piece before choosing a destination; omit ref only for a new piece.",
                next: ["action": .string("make.read")])
        } catch {
            return Self.ownedFailure(error, code: "make_add_failed", owner: studio.root.path,
                instruction: "Read Make's retained versions and resolve the reported storage error before adding another copy; this add was not verified.",
                next: ["action": .string("make.read"), "args": .object(ref.isEmpty ? [:] : ["ref": .string(ref)])], effects: .unknown)
        }
    }

    /// reply.attach: an image she sends with this reply, behind the same fence as
    /// make.add, chosen into the turn's own reply.
    @MainActor
    func runReplyAttach(input: [String: JSONValue]) async -> JSONValue {
        let path = input["path"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.failure("invalid_input", "Pass path: the image to send with this reply.") }
        guard let choices = ReplyChoices.current else {
            return Self.failure("no_reply", "Only a turn answering a conversation has a reply to attach to. Nothing was attached.")
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        switch await SwiftNativeSecurityCenter.fencedAttachment(path, dataRoot: root) {
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
