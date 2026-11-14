import AgentConversations
import ChatToolRuntime
import Dispatcher
import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
import MemoryV2

// Blueprint: | `AppToolExecutor+Make.swift` | `AppToolExecutor`; Studio versions, intake and workspace-fenced reply images |

extension AppToolExecutor {
    /// A nil ref reads the shelf; an empty ref reads the newest piece, as make.read declares.
    @MainActor
    func readMake(ref: String?, offset: Int = 0) async -> JSONValue {
        let studio = MakeStudio(dataRoot: securityCenter.dataRoot)
        do {
            return try await Task.detached(priority: .userInitiated) {
                guard let ref else { return try studio.shelfPage(offset: offset) }
                let found = try (ref.isEmpty ? studio.newestMeta() : studio.readMeta(ref))
                guard let meta = found else {
                    return Self.doorRefusal("unknown_ref", ref.isEmpty ? "Nothing is in Make yet." : "No Make ref is called \(ref).",
                        remedy: "correct_route", "Read Make's shelf to choose a retained ref.", next: ["page": .string("make")])
                }
                return studio.receipt(meta)
            }.value
        } catch {
            return Self.ownedFailure(error, code: "make_unreadable", owner: studio.root.path,
                instruction: "Repair the named Make metadata or storage error, then read the shelf again; no empty shelf was established.",
                next: ["page": .string("make")], effects: .none)
        }
    }

    @MainActor
    func runStudioIntakeRead(input: [String: JSONValue], surface: String) async -> JSONValue {
        guard MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains(MemoryRecordDisclosurePolicy.canonicalSurface(surface)) else {
            return Self.failure("private_surface_required", "Studio intake is available only on private surfaces.")
        }
        let root = securityCenter.dataRoot
        do {
            let offset: Int
            // An ability's JavaScript numbers arrive as doubles; a whole one is the integer it says.
            if let exact = input["offset"]?.exactIntegerValue { offset = exact }
            else if input["offset"] == nil { offset = 0 }
            else { throw PersistenceCoreError.ioFailure("Studio intake offset must be an integer.") }
            return try await SwiftNativeStudioStore(dataRoot: root).encounterIntakePage(
                kind: input["kind"]?.scalarText ?? "", offset: offset, snapshot: input["snapshot"]?.scalarText)
        } catch {
            return Self.failure("studio_intake_unavailable", error.localizedDescription, extra: ["effects": .string("none")])
        }
    }

    /// Studio reads and writes share the versioned MakeStudio refs shown in the Work pane.
    func runMake(verb: String, input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue {
        let root = securityCenter.dataRoot
        let studio = MakeStudio(dataRoot: root)
        let ref = input["ref"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if verb == "read" {
            return await readMake(ref: ref)
        }
        let path = input["path"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let file: URL
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // Words the caller already holds go in as they are: content with a file name, no file written somewhere first.
        var written: URL?
        defer { if let written { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) } }
        if path.isEmpty {
            guard case .string(let content)? = input["content"], !content.isEmpty else {
                return Self.failure("invalid_input", "Pass path (a file to add), or content with name (its words and a file name such as board.html).")
            }
            let name = URL(fileURLWithPath: input["name"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").lastPathComponent
            guard !name.isEmpty, name != "/", !name.hasPrefix("."), !URL(fileURLWithPath: name).pathExtension.isEmpty else {
                return Self.failure("invalid_input", "With content, pass name: a file name with its type, such as board.html or notes.md.")
            }
            guard content.utf8.count <= MakePreviewFace.wordsLimit else {
                return Self.failure("invalid_input", "content is over 2 MB; write it to a file and pass path instead.")
            }
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("make-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let staged = folder.appendingPathComponent(name)
                try Data(content.utf8).write(to: staged, options: .atomic)
                written = staged
            } catch {
                return Self.failure("make_add_failed", "The words could not be staged for Make: " + error.localizedDescription + " Nothing was added.")
            }
        }
        if let written {
            file = written
        } else if execution.generatedImagePaths.contains(candidate.path),
           (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
           !connectorPathIsSensitiveData(candidate, dataRoot: root, turn: turn) {
            // Only the native receipt's actual outputs have this provenance; every arbitrary file still goes through the workspace fence.
            file = candidate
        } else {
            switch await SwiftNativeSecurityCenter.fencedAttachment(path, dataRoot: root, turn: turn) {
            case .success(let found): file = found
            case .failure(let refusal): return Self.failure(refusal.reason, refusal.detail)
            }
        }
        do {
            // A table the person changed in the window is laid as their edit of the version on screen (`Turn.personEditOf`).
            let added = try studio.add(file, ref: ref.isEmpty ? nil : ref,
                prompt: input["prompt"]?.scalarText, model: input["model"]?.scalarText, personEditOf: turn.personEditOf)
            return .object(["status": .string("ok"), "ref": .string(added.ref), "version": .int(Int64(added.version.n)),
                            "path": .string(studio.url(added.ref, added.version).path)])
        } catch let refusal as MakeStudio.Refusal {
            return Self.doorRefusal(refusal.reason, refusal.message, remedy: "inspect",
                "Read Make's shelf before choosing a destination; omit ref only for a new piece.",
                next: ["page": .string("make")])
        } catch {
            return Self.ownedFailure(error, code: "make_add_failed", owner: studio.root.path,
                instruction: "Read Make's retained versions and resolve the reported storage error before adding another copy; this add was not verified.",
                next: ref.isEmpty ? ["page": .string("make")] : ["page": .string("make"), "item": .string(ref)], effects: .unknown)
        }
    }

    /// A job's posture ceiling is read here, at the door, from the turn's own origin. What the job makes registers in Make through `jobRegistrar`.
    @MainActor
    func runAgentJob(input: [String: JSONValue], surface: String, turn: Turn) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let ceiling = await SwiftNativeSecurityCenter(dataRoot: root).drivenAgentLaunchPermission(
            origin: SecurityOriginContext.currentTurn(turn: turn, surface: surface), turn: turn)
        // A line of the agent's carries this turn's limits: the peers steering it and its file access, so nothing reaches the agent's hands wider through a
        // line.
        let limits = (peers: turn.peerSteering?.checkpointSources ?? [], elevated: turn.peerSteering?.elevatedSources ?? [], fileAccess: turn.fileAccess)
        return await AgentJobs.commission(input.filter { !$0.key.hasPrefix("__") }, session: turn.verifiedSessionID ?? input["__session_id"]?.scalarText,
            surface: surface, ceiling: ceiling, limits: limits, dataRoot: root, register: Self.jobRegistrar(dataRoot: root))
    }

    /// The image_generate receipt's rule, generalized: only paths the native stem verified inside the job's folder reach this, and only the stem supplies
    /// their provenance; neither the organ's JSON nor a part can. The brief is what was asked, as a generation's prompt is.
    public static func jobRegistrar(dataRoot: URL) -> AgentJobRegistrar {
        { file, provenance in
            let added = try MakeStudio(dataRoot: dataRoot).add(file, prompt: String(provenance.brief.prefix(4000)), madeBy: provenance.madeBy)
            return (added.ref, added.version.n)
        }
    }

    /// Reply images share make.add's workspace fence and belong only to the current turn.
    @MainActor
    func runReplyAttach(input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue {
        let path = input["path"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.failure("invalid_input", "Pass path: the image to send with this reply.") }
        guard let choices = turn.replyChoices else {
            return Self.failure("no_reply", "Only a turn answering a conversation has a reply to attach to. Nothing was attached.")
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        switch await SwiftNativeSecurityCenter.fencedAttachment(path, dataRoot: root, turn: turn) {
        case .failure(let refusal): return Self.failure(refusal.reason, refusal.detail)
        case .success(let file):
            guard ChatGeneratedImageArtifacts.attachment(file) != nil else {
                return Self.failure("not_an_image", """
                    \(file.lastPathComponent) is not an image a reply carries: jpg, png, gif, webp, bmp or heic. Nothing was attached.
                    """)
            }
            choices.choose(file.path)
            return .object(["status": .string("ok"), "effects": .string("none"), "attached": .string(file.path),
                            "detail": .string("Attached; it goes with this reply.")])
        }
    }
}
