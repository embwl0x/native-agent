import AgentConversations
import ChatToolRuntime
import Dispatcher
import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
import MemoryV2

// Blueprint: | `AppToolExecutor+Make.swift` | `AppToolExecutor`; Studio versions, intake and workspace-fenced reply images |

extension AppToolExecutor {
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
    @MainActor
    func runMake(verb: String, input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue {
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
                    if let madeBy = version.madeBy { row["made_by"] = .string(madeBy) }
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
        if execution.generatedImagePaths.contains(candidate.path),
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
