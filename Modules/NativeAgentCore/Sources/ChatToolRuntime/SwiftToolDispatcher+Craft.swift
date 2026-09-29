import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MacControl
import Dispatcher
import MacIntegration
#if canImport(Darwin)
import Darwin
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif

package enum CraftToolContext {
    package typealias Dispatch = @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    @TaskLocal package static var dispatch: Dispatch?
    @TaskLocal package static var requiresCurrentAuthority = false
}

/// Effects share one lease across agents and sessions.
private actor CraftSurfaceLease {
    static let shared = CraftSurfaceLease()
    private var busy = false
    func acquire() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }
    func release() { busy = false }
}

extension SwiftToolDispatcher {
    var craftStore: ProceduralCraftStore? {
        guard let agent = ChatTurnRuntimeContext.current?.personaID, !agent.isEmpty else { return nil }
        return ProceduralCraftStore(dataRoot: dataRoot, agentID: agent)
    }

    func impl_craft_run(input: [String: JSONValue]) async throws -> JSONValue {
        guard let dispatch = CraftToolContext.dispatch,
              let agent = ChatTurnRuntimeContext.current?.personaID, !agent.isEmpty,
              let session = ChatToolSessionContext.verifiedSessionId, !session.isEmpty else {
            throw CraftFailure("Craft requires an invoking agent and the current gated chat session.")
        }
        let name = input["method"] ?? .string(CraftMethod.textEdit.skillName)
        guard let method = CraftMethod.supported.first(where: { name == .string($0.skillName) }) else {
            throw CraftFailure("Unsupported craft method.")
        }
        let store = ProceduralCraftStore(dataRoot: dataRoot, agentID: agent)
        let saved = try store.candidate(method)
        guard saved != nil || input["learn"] == .bool(true) else {
            throw CraftFailure("No verified method yet. Use learn:true to try this supported route.")
        }
        guard await CraftSurfaceLease.shared.acquire() else {
            throw CraftFailure("Another craft call is running. No action was performed.")
        }
        // Lazy dependency loading is scoped to this call; it confers no trust
        // or file authority. Every operation re-enters the outer dispatcher.
        let result: JSONValue
        do {
            result = try await LLMCallContext.$turnActiveTools.withValue(
                (LLMCallContext.turnActiveTools ?? []).union(method == .textEdit ? ["read_file"]
                    : method == .finder ? ["list_dir", "shell"]
                    : ["mac_reminders_list_due_today", "mac_reminders_create"])) {
                try await CraftToolContext.$requiresCurrentAuthority.withValue(true) {
                    switch method.intent {
                    case .finderFolderAndMove:
                        return try await executeFinderCraft(input: input, agent: agent, session: session, store: store, dispatch: dispatch)
                    case .reminderWithDueDate:
                        return try await executeReminderCraft(input: input, agent: agent, session: session, store: store, dispatch: dispatch)
                    case .textEditReplaceAndSave:
                        let path = try requireString(input, "path")
                        let before = try requireString(input, "expected_before")
                        let after = try requireString(input, "replacement")
                        let url = URL(fileURLWithPath: path).standardizedFileURL
                        guard path.hasPrefix("/"), Data(path.utf8) == Data(url.path.utf8),
                              url.pathExtension == "txt", before.utf8.count <= 4096,
                              !after.isEmpty, after.utf8.count <= 4096, Data(before.utf8) != Data(after.utf8) else {
                            throw CraftFailure("Use an absolute .txt path and different UTF-8 contents up to 4096 bytes; replacement must be nonempty.")
                        }
                        return try await executeTextEditCraft(path: path, before: before, after: after,
                            agent: agent, session: session, store: store, dispatch: dispatch)
                    }
                }
            }
        } catch {
            await CraftSurfaceLease.shared.release()
            throw error
        }
        await CraftSurfaceLease.shared.release()
        return result
    }

    private func executeReminderCraft(input: [String: JSONValue], agent: String, session: String,
        store: ProceduralCraftStore, dispatch: CraftToolContext.Dispatch) async throws -> JSONValue {
        let list = try requireString(input, "list_name")
        let title = try requireString(input, "title")
        let rawDate = try requireString(input, "due_date")
        let formatter = ISO8601DateFormatter()
        guard !list.isEmpty, list == list.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              list.utf8.count <= 256, title.utf8.count <= 1024,
              let due = formatter.date(from: rawDate),
              rawDate.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw CraftFailure("Supply an exact list, a nonempty title, and an ISO-8601 due timestamp with timezone and whole seconds.")
        }
        let binding = try craftBinding([CraftMethod.reminder.skillName, list, title, formatter.string(from: due)])
        var run = try store.evidence(binding) ?? CraftRunEvidence(bindingID: binding, path: list,
            beforeDigest: ProceduralCraftStore.digest(title), afterDigest: ProceduralCraftStore.digest(formatter.string(from: due)), sessionID: session)
        guard run.bindingID == binding, run.path == list, run.beforeDigest == ProceduralCraftStore.digest(title),
              run.afterDigest == ProceduralCraftStore.digest(formatter.string(from: due)),
              run.method == nil || run.method == .reminder else { throw CraftFailure("Craft journal does not match its inputs.") }
        run.method = .reminder
        if run.ownerBindings == nil { run.ownerBindings = [:] }
        var cause: JSONValue = .null
        var state = "not_observed"
        func ownerBinding() -> ReminderCraftBinding {
            ReminderCraftBinding(listName: list, title: title, dueDate: due,
                listID: run.ownerBindings?["list_id"], reminderID: run.ownerBindings?["reminder_id"])
        }
        func inspect() async throws -> [String: JSONValue] {
            try Task.checkCancellation()
            let result = try await ReminderCraftBinding.$current.withValue(ownerBinding()) {
                try await dispatch("mac_reminders_list_due_today", [:])
            }
            guard case .object(let evidence) = result, evidence["ok"] == .bool(true),
                  case .string(let observed)? = evidence["state"], case .string? = evidence["list_id"] else {
                cause = result
                throw CraftFailure("The exact reminder could not be read with current authority.")
            }
            state = observed
            return evidence
        }
        func receipt(_ reason: String, ok: Bool = false) -> JSONValue {
            .object(["ok": .bool(ok), "status": .string(ok ? "verified" : "stopped"),
                "method": .string(CraftMethod.reminder.skillName), "phase": .string(run.phase.rawValue),
                "reminder": .string(state), "reason": .string(reason),
                "evidence_ref": .string(binding + ".json"), "cause": cause])
        }
        do {
            var observed = try await inspect()
            if run.phase == .ready {
                guard state == "absent", case .string(let listID)? = observed["list_id"] else {
                    throw CraftFailure("A matching reminder already exists or its list changed. Nothing was created.")
                }
                run.ownerBindings?["list_id"] = listID
                run.phase = .reminderIssued
                try store.record(run)
                try Task.checkCancellation()
                do {
                    cause = try await ReminderCraftBinding.$current.withValue(ownerBinding()) {
                        try await dispatch("mac_reminders_create", ["list_name": .string(list),
                            "title": .string(title), "due_date": .string(formatter.string(from: due))])
                    }
                } catch { cause = .string(String(describing: error)) }
                if case .object(let result) = cause, result["status"] == .string("completed"),
                   case .string(let id)? = result["reminderId"], !id.isEmpty {
                    run.ownerBindings?["reminder_id"] = id
                    try store.record(run)
                }
                observed = try await inspect()
            }
            guard (run.phase == .reminderIssued || run.phase == .verified), state == "verified",
                  case .string(let id)? = observed["reminder_id"] else {
                throw CraftFailure("Reminder creation is not verified. Inspect it manually; it will not be repeated.")
            }
            run.ownerBindings?["reminder_id"] = id
            run.phase = .verified
            run.lastReason = nil
            try await ProceduralLane.shared.retainCraft(run, dataRoot: dataRoot, agentID: agent)
            return receipt("The exact reminder, list, and due timestamp were read back; candidate retained locally.", ok: true)
        } catch {
            run.lastReason = String(describing: error)
            do { try store.record(run) }
            catch { return receipt("\(run.lastReason ?? "Stopped"); progress persistence failed: \(error)") }
            return receipt(run.lastReason ?? "Stopped")
        }
    }

    private func craftBinding(_ fields: [String]) throws -> String {
        ProceduralCraftStore.digest(String(decoding: try JSONEncoder().encode(fields), as: UTF8.self))
    }

    private func executeFinderCraft(input: [String: JSONValue], agent: String, session: String,
        store: ProceduralCraftStore, dispatch: CraftToolContext.Dispatch) async throws -> JSONValue {
        let source = try requireString(input, "source_directory")
        let folder = try requireString(input, "folder_name")
        func safeName(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains(":")
                && value.utf8.count <= 255 && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
        guard case .array(let rawNames)? = input["file_names"], (1...16).contains(rawNames.count),
              source.hasPrefix("/"), source == URL(fileURLWithPath: source).standardizedFileURL.path,
              source.rangeOfCharacter(from: .controlCharacters) == nil, safeName(folder) else {
            throw CraftFailure("Use an absolute local directory, a new child folder name, and 1–16 regular file names.")
        }
        let names = try rawNames.map { value -> String in
            guard case .string(let name) = value, safeName(name) else { throw CraftFailure("Use file names without paths or control characters.") }
            return name
        }.sorted()
        let folded = names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(folded).count == names.count, !folded.contains(folder.precomposedStringWithCanonicalMapping.lowercased()) else {
            throw CraftFailure("File and folder names must be distinct.")
        }
        let destination = URL(fileURLWithPath: source).appendingPathComponent(folder).path
        let binding = try craftBinding([CraftMethod.finder.skillName, source, folder] + names)
        var run = try store.evidence(binding) ?? CraftRunEvidence(bindingID: binding, path: source,
            beforeDigest: try craftBinding(names), afterDigest: ProceduralCraftStore.digest(folder), sessionID: session)
        guard run.bindingID == binding, run.path == source, run.beforeDigest == (try craftBinding(names)),
              run.afterDigest == ProceduralCraftStore.digest(folder),
              run.method == nil || run.method == .finder else { throw CraftFailure("Craft journal does not match its inputs.") }
        run.method = .finder
        var cause: JSONValue = .null
        var moved = run.verifiedFiles ?? []
        func inspect(_ path: String, _ children: [String]) async throws -> [String: JSONValue] {
            try Task.checkCancellation()
            let result = try await FileReadEvidence.$directoryNames.withValue(children) {
                try await dispatch("list_dir", ["path": .string(path)])
            }
            guard case .object(let evidence) = result, evidence["ok"] == .bool(true),
                  evidence["path"] == .string(path), case .string? = evidence["identity"],
                  case .object? = evidence["entries"] else {
                cause = result
                throw CraftFailure("Exact filesystem evidence is unavailable; paths must be local and contain no symlinks.")
            }
            return evidence
        }
        func entry(_ evidence: [String: JSONValue], _ name: String) -> [String: JSONValue]? {
            guard case .object(let entries)? = evidence["entries"], case .object(let item)? = entries[name] else { return nil }
            return item
        }
        func string(_ object: [String: JSONValue], _ key: String) throws -> String {
            guard case .string(let value)? = object[key] else { throw CraftFailure("Incomplete filesystem evidence.") }
            return value
        }
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func appleQuote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func pathGuards(_ path: String) -> [String] {
            var prefix = ""
            return path.split(separator: "/").map { component in
                prefix += "/" + component
                return "[ ! -L " + shellQuote(prefix) + " ]"
            }
        }
        func identityGuard(_ path: String, _ expected: String, version: Bool = false) throws -> String {
            #if canImport(Darwin)
            var prefix = ""
            var info = stat()
            guard lstat(path, &info) == 0 else { throw CraftFailure("A bound path changed or contains a symlink.") }
            for component in path.split(separator: "/") {
                prefix += "/" + component
                guard lstat(prefix, &info) == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                    throw CraftFailure("A bound path changed or contains a symlink.")
                }
            }
            let identity = "\(info.st_dev):\(info.st_ino)" + (version ? ":\(info.st_size):\(info.st_mtimespec.tv_sec)" : "")
            // source was authorized by list_dir; no resolved path may leave it.
            guard let resolved = realpath(path, nil) else { throw CraftFailure("A bound path cannot be resolved.") }
            defer { free(resolved) }
            let real = String(cString: resolved)
            guard identity == expected, real == path, real == source || real.hasPrefix(source == "/" ? "/" : source + "/") else {
                throw CraftFailure("A bound path changed or escaped the allowed directory.")
            }
            // BSD stat uses lstat unless -L is supplied. Repeat component and
            // real-path checks in the shell immediately before Finder.
            return (pathGuards(path) + [
                "[ \"$(/usr/bin/readlink -f " + shellQuote(path) + ")\" = " + shellQuote(path) + " ]",
                "[ \"$(/usr/bin/stat -f " + shellQuote(version ? "%d:%i:%z:%m" : "%d:%i") + " " + shellQuote(path) + ")\" = " + shellQuote(expected) + " ]"
            ]).joined(separator: " && ")
            #else
            throw CraftFailure("Finder craft requires macOS.")
            #endif
        }
        func absentGuard(_ path: String) -> String { "[ ! -e " + shellQuote(path) + " ] && [ ! -L " + shellQuote(path) + " ]" }
        func requireFinderAutomation() throws {
            #if canImport(ApplicationServices)
            let status = "com.apple.finder".withCString { bundle -> OSStatus in
                var target = AEAddressDesc()
                let built = AECreateDesc(AEKeyword(typeApplicationBundleID), bundle, strlen(bundle), &target)
                guard built == noErr else { return OSStatus(built) }
                defer { AEDisposeDesc(&target) }
                return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
            }
            guard status == noErr else { throw CraftFailure("Craft requires existing Finder automation access; no permission prompt was opened.") }
            #else
            throw CraftFailure("Finder craft requires macOS.")
            #endif
        }
        func effect(_ script: String, guards: [String], createdDirectory: String? = nil) async {
            var commands = guards + ["/usr/bin/osascript -e " + shellQuote(script)]
            if let createdDirectory {
                commands[commands.count - 1] = "created_path=$(" + commands[commands.count - 1] + ")"
                commands.append("[ \"$created_path\" = " + shellQuote(createdDirectory + "/") + " ]")
                commands += pathGuards(createdDirectory)
                commands.append("/usr/bin/stat -f '%d:%i' " + shellQuote(createdDirectory))
            }
            let command = commands.joined(separator: " && ")
            do {
                try requireFinderAutomation()
                cause = try await dispatch("shell", ["cmd": .string(command), "timeout_seconds": .int(30)])
            }
            catch { cause = .string(String(describing: error)) }
        }
        func receipt(_ reason: String, ok: Bool = false) -> JSONValue {
            .object(["ok": .bool(ok), "status": .string(ok ? "verified" : "stopped"),
                "method": .string(CraftMethod.finder.skillName), "phase": .string(run.phase.rawValue),
                "verified_files": .array(moved.map(JSONValue.string)),
                "issued_files": .array((run.issuedFiles ?? []).map(JSONValue.string)),
                "reason": .string(reason), "evidence_ref": .string(binding + ".json"), "cause": cause])
        }
        do {
            var current = try await inspect(source, names + [folder])
            if run.phase == .ready {
                guard entry(current, folder) == nil else { throw CraftFailure("The destination already exists. Nothing was moved.") }
                try requireFinderAutomation()
                var bindings = ["source": try string(current, "identity")]
                for name in names {
                    guard let file = entry(current, name), file["kind"] == .string("file") else { throw CraftFailure("A named source is missing or is not a regular file.") }
                    bindings["file:" + name] = try string(file, "version")
                    bindings["ns:" + name] = try string(file, "modified_ns")
                }
                run.ownerBindings = bindings
                run.issuedFiles = []
                run.verifiedFiles = []
                run.phase = .folderIssued
                try store.record(run)
                try Task.checkCancellation()
                await effect("tell application \"Finder\"\nset createdFolder to make new folder at (POSIX file " + appleQuote(source) + " as alias) with properties {name:" + appleQuote(folder) + "}\nreturn POSIX path of (createdFolder as alias)\nend tell",
                    guards: [try identityGuard(source, bindings["source"]!), absentGuard(destination)], createdDirectory: destination)
                guard case .object(let result) = cause, result["status"] == .string("completed"),
                      result["exit_code"] == .int(0), case .string(let output)? = result["stdout"],
                      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CraftFailure("New folder creation failed or drifted. An existing folder will not be adopted.")
                }
                run.ownerBindings?["destination"] = output.trimmingCharacters(in: .whitespacesAndNewlines)
                try store.record(run)
                current = try await inspect(source, names + [folder])
            }
            guard let parentID = run.ownerBindings?["source"], current["identity"] == .string(parentID),
                  let directory = entry(current, folder), directory["kind"] == .string("directory") else {
                throw CraftFailure("Folder creation is unverified or the source changed. Creation will not be repeated.")
            }
            let folderID = try string(directory, "identity")
            guard run.ownerBindings?["destination"] == folderID else { throw CraftFailure("The destination folder changed or its creation was not recorded.") }
            if run.phase != .verified { run.phase = .movingFiles }
            try store.record(run)

            func inspectMoves() async throws -> [String: JSONValue] {
                let from = try await inspect(source, names + [folder])
                let to = try await inspect(destination, names)
                guard from["identity"] == .string(parentID), to["identity"] == .string(folderID),
                      entry(from, folder)?["identity"] == .string(folderID) else { throw CraftFailure("A bound directory changed.") }
                var drift = false
                for name in names {
                    guard let version = run.ownerBindings?["file:" + name], let ns = run.ownerBindings?["ns:" + name] else { throw CraftFailure("Missing original file evidence.") }
                    let sourceFile = entry(from, name)
                    let targetFile = entry(to, name)
                    if sourceFile == nil, let targetFile, targetFile["kind"] == .string("file"),
                       targetFile["version"] == .string(version), targetFile["modified_ns"] == .string(ns),
                       (run.issuedFiles ?? []).contains(name) {
                        if !moved.contains(name) {
                            moved.append(name)
                            run.verifiedFiles = moved
                        }
                    } else if let sourceFile, targetFile == nil, sourceFile["kind"] == .string("file"),
                              sourceFile["version"] == .string(version), sourceFile["modified_ns"] == .string(ns),
                              !moved.contains(name) {
                        continue
                    } else { drift = true }
                }
                try store.record(run)
                guard !drift else { throw CraftFailure("A named file changed, disappeared, or collided with its destination.") }
                return from
            }
            _ = try await inspectMoves()
            for name in names where !moved.contains(name) {
                guard run.phase != .verified, !(run.issuedFiles ?? []).contains(name) else {
                    throw CraftFailure("An issued move is not verified. Inspect it manually; it will not be repeated.")
                }
                _ = try await inspectMoves()
                let original = URL(fileURLWithPath: source).appendingPathComponent(name).path
                let target = URL(fileURLWithPath: destination).appendingPathComponent(name).path
                run.issuedFiles?.append(name)
                try store.record(run)
                try Task.checkCancellation()
                await effect("tell application \"Finder\" to move (POSIX file " + appleQuote(original) + " as alias) to (POSIX file " + appleQuote(destination) + " as alias) without replacing",
                    guards: [try identityGuard(source, parentID), try identityGuard(destination, folderID),
                        try identityGuard(original, run.ownerBindings!["file:" + name]!, version: true), absentGuard(target)])
                _ = try await inspectMoves()
                guard moved.contains(name) else { throw CraftFailure("The move is not verified. Inspect it manually; it will not be repeated.") }
            }
            _ = try await inspectMoves()
            guard moved.count == names.count else { throw CraftFailure("Not all files were verified at destination.") }
            run.phase = .verified
            run.lastReason = nil
            try await ProceduralLane.shared.retainCraft(run, dataRoot: dataRoot, agentID: agent)
            return receipt("Every original file exists in the new folder and is absent from source; candidate retained locally.", ok: true)
        } catch {
            run.lastReason = String(describing: error)
            do { try store.record(run) }
            catch { return receipt("\(run.lastReason ?? "Stopped"); progress persistence failed: \(error)") }
            return receipt(run.lastReason ?? "Stopped")
        }
    }

    private func executeTextEditCraft(
        path: String, before: String, after: String, agent: String, session: String,
        store: ProceduralCraftStore, dispatch: CraftToolContext.Dispatch
    ) async throws -> JSONValue {
        let digest = ProceduralCraftStore.digest
        let binding = digest(path + "\u{0}" + digest(before) + "\u{0}" + digest(after))
        var run = try store.evidence(binding) ?? CraftRunEvidence(bindingID: binding, path: path,
            beforeDigest: digest(before), afterDigest: digest(after), sessionID: session)
        guard Data(run.path.utf8) == Data(path.utf8), run.beforeDigest == digest(before), run.afterDigest == digest(after) else {
            throw CraftFailure("Craft journal does not match its inputs.")
        }
        var diskState = "not_observed"
        var editorState = "not_observed"
        var cause: JSONValue = .null

        func act(_ arguments: [String: JSONValue], expected: String, replace: Bool = false) async throws -> JSONValue {
            try await MacCraftReplacement.$documentPath.withValue(path) {
                try await MacCraftReplacement.$editorDigest.withValue(digest(expected)) {
                    try await MacCraftReplacement.$required.withValue(replace) {
                        try await dispatch("act", arguments)
                    }
                }
            }
        }

        func fileText() async throws -> String {
            try Task.checkCancellation()
            // The exact path must clear the normal read_file policy first.
            let result = try await FileReadEvidence.$required.withValue(true) {
                try await dispatch("read_file", ["path": .string(path), "max_bytes": .int(4096)])
            }
            guard case .object(let read) = result, read["ok"] == .bool(true),
                  case .string(let readPath)? = read["path"], Data(readPath.utf8) == Data(path.utf8),
                  read["utf8_valid"] == .bool(true),
                  read["truncated"] == .bool(false), read["offset"] == .int(0),
                  case .string(let text)? = read["content"], text.utf8.count <= 4096,
                  read["content_sha256"] == .string(digest(text)) else {
                cause = result
                throw CraftFailure("The complete file could not be read with current authority.")
            }
            diskState = digest(text) == digest(before) ? "expected_before" : digest(text) == digest(after) ? "replacement" : "changed"
            return text
        }

        func editor() async throws -> (handle: String, frame: String, digest: String) {
            try Task.checkCancellation()
            let result = try await dispatch("screen", ["app": .string("TextEdit"), "structured": .bool(true)])
            guard case .object(let root) = result, root["ok"] == .bool(true),
                  case .object(let detail)? = root["detail"],
                  case .object(let controls)? = detail["controls"],
                  case .object(let document)? = controls["craft_document"],
                  case .string(let documentPath)? = document["path"], Data(documentPath.utf8) == Data(path.utf8),
                  case .string(let handle)? = document["handle"],
                  case .string(let frame)? = controls["frame_id"],
                  case .string(let value)? = document["editor_sha256"] else {
                cause = result
                throw CraftFailure("TextEdit must show the exact file, one complete editable text area, and no dialog.")
            }
            editorState = value == digest(before) ? "expected_before" : value == digest(after) ? "replacement" : "changed"
            return (handle, frame, value)
        }

        func receipt(_ status: String, _ reason: String) -> JSONValue {
            .object(["ok": .bool(status == "verified"), "status": .string(status), "method": .string(ProceduralCraftStore.skillName),
                "phase": .string(run.phase.rawValue), "disk": .string(diskState), "editor": .string(editorState),
                "reason": .string(reason), "evidence_ref": .string(binding + ".json"), "cause": cause])
        }

        func verified() async throws -> JSONValue {
            run.phase = .verified
            run.lastReason = nil
            try await ProceduralLane.shared.retainCraft(run, dataRoot: dataRoot, agentID: agent)
            return receipt("verified", "The exact file contains the replacement; candidate retained locally.")
        }

        do {
            let disk = try await fileText()
            if run.phase == .verified {
                guard digest(disk) == digest(after) else { throw CraftFailure("A completed binding has changed. It will not be reapplied.") }
                return try await verified()
            }
            if run.phase == .saveIssued || run.phase == .editorVerified || run.phase == .editIssued {
                if digest(disk) == digest(after), try await editor().digest == digest(after) {
                    // TextEdit may autosave before the explicit Save. Both
                    // object reads agree after a journalled edit attempt.
                    return try await verified()
                }
            }
            guard digest(disk) == digest(before) else { throw CraftFailure("The file no longer matches expected_before; nothing will be overwritten.") }
            var current = try await editor()
            if run.phase == .ready {
                guard current.digest == digest(before) else { throw CraftFailure("The editor has unsaved or unexpected content.") }
                // Write-ahead: cancellation or crash after this point can
                // never turn an uncertain edit into an automatic second edit.
                run.phase = .editIssued
                try store.record(run)
                try Task.checkCancellation()
                cause = try await act(["verb": .string("type"), "handle": .string(current.handle),
                    "frame_id": .string(current.frame), "text": .string(after)], expected: before, replace: true)
                current = try await editor()
            }
            guard current.digest == digest(after) else {
                throw CraftFailure("The edit was not verified. Inspect it manually; it will not be repeated.")
            }
            if run.phase == .saveIssued {
                throw CraftFailure("Save was already attempted but the file is not verified. Inspect it manually; Save will not be repeated.")
            }
            run.phase = .editorVerified
            try store.record(run)
            let beforeSave = try await fileText()
            if digest(beforeSave) == digest(after) { return try await verified() }
            guard digest(beforeSave) == digest(before) else { throw CraftFailure("The file changed before Save; the editor remains modified.") }
            // Re-resolve immediately before the menu action; act itself also
            // reads current controls and uses the existing app-map checks.
            guard try await editor().digest == digest(after) else { throw CraftFailure("The editor changed before Save.") }
            run.phase = .saveIssued
            try store.record(run)
            try Task.checkCancellation()
            cause = try await act(["app": .string("TextEdit"),
                "verb": .string("press"), "target": .string("File > Save")], expected: after)
            guard digest(try await fileText()) == digest(after) else {
                throw CraftFailure("Save was attempted; the file does not yet contain the replacement. No retry was made.")
            }
            return try await verified()
        } catch {
            run.lastReason = String(describing: error)
            do { try store.record(run) }
            catch { return receipt("stopped", "\(run.lastReason ?? "Stopped"); progress persistence failed: \(error)") }
            return receipt("stopped", run.lastReason ?? "Stopped")
        }
    }
}
