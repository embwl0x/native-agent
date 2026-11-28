import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import MacNerves
import AppKit
// Blueprint: | `PartHost.swift` | `Parts.rehearse`, `ToolHost`: gated host; previews suppress effects; a read verb's run only reads |

extension OwnedProgramExecution {
    func macOperation(dataRoot: URL) -> MacOperationContext {
        var context = MacOperationContext(dataRoot: dataRoot, deadline: deadline)
        context.life = turn?.enclosingCall ?? deadlines.innermostCall
        context.handsBack = options.handsBack
        context.readContent = readContent
        return context
    }
}

extension Parts {
    /// Intercept every host call during rehearsal so sealing cannot claim unobserved effects.
    func rehearse(_ candidate: OwnedProgramStore.Candidate, capture: Bool, input: JSONValue?, faceSampleInput: JSONValue?,
                  facePages: [PartFaces], invocation: Invocation) async throws -> (proof: JSONValue, faceChecked: Bool) {
        guard let base = invocation.host else {
            throw PartError.invalid("Rehearsal needs the gated app door of a conversation or wake run.")
        }
        try await checkDependencies(candidate, invocation: invocation)
        let key = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
        let broker = ToolPrimitiveBroker(permissions: try PartReachGrant.parse(candidate.program.permissions), abilityID: candidate.id, dataRoot: root,
            readPaths: JSONValue.stringArray(Self.fields(Self.fields(candidate.manifest)["reach"] ?? .null)["readPaths"] ?? .array([])))
        let dataRoot = root
        let openScreenWatch = invocation.openScreenWatch
        let faceHost = ToolHost(base: base, candidate: candidate, broker: broker, dataRoot: root, openScreenWatch: nil,
            projection: true, admission: {})
        let face = Self.fields(Self.fields(candidate.manifest)["face"] ?? .null)["projection"] == .bool(true)
        let schema = face ? Self.faceNeeds(candidate.program.schema) : candidate.program.schema
        var ownerPages: [PartFaceSnapshot] = []
        if face {
            for pages in facePages {
                let snapshots = await pages.snapshots
                ownerPages += snapshots.sorted { $0.key < $1.key }.map(\.value).filter {
                    $0.part == candidate.id && ($0.levers != nil || $0.keyLevers != nil)
                }
            }
        }
        let selfAction = candidate.program.entry.callable ? "authored." + candidate.id : nil
        let turn = invocation.execution.turn
        do {
            let result = try await store.validate(candidate, key: key, capture: capture, input: input, faceSampleInput: faceSampleInput,
                runner: OwnedProgramRunner(dataRoot: root).rehearsal(),
                host: { input in
                    ToolHost(base: base, candidate: candidate, broker: broker, dataRoot: dataRoot, openScreenWatch: openScreenWatch,
                        readOnly: ToolHost.readOnly(candidate, input: input), admission: {})
                }, faceHost: faceHost, ownerPages: ownerPages,
                execution: invocation.execution,
                prepareFace: { try await self.prepareFace(id: candidate.id, input: $0) },
                actionExists: { action in
                    if action == selfAction { return true }
                    return try base.action(action) != nil
                }, documentReadAllowed: { try AppActionBinding.action(input: $0.input, turn: turn)?.read == true }) { input, label in
                if let problem = input.schemaProblem(schema: schema) {
                    throw SenseFailure(code: "bad_input", message: "\(label): \(problem.words).", remedy: .object([
                        "kind": .string("correct_arguments"), "instruction": .string(
                            "Correct the input to match \(problem.expected) in ability.validate for \(candidate.id)."), "next_call": .null]))
                }
            }
            await broker.close()
            return result
        } catch {
            await broker.close()
            throw error
        }
    }

    /// A face reads the facts it needs from its owner's packet, and packets grow: a face part's input is checked only for what the part
    /// declares it needs. A field beyond its declaration is never refused, and a declared field it does not require may be null.
    static func faceNeeds(_ schema: JSONValue) -> JSONValue {
        guard case .object(var rules) = schema else { return schema }
        if rules["additionalProperties"] == .bool(false) { rules.removeValue(forKey: "additionalProperties") }
        let required = Set((rules["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        if case .object(let properties)? = rules["properties"] {
            rules["properties"] = .object(Dictionary(uniqueKeysWithValues: properties.map { name, property in
                (name, required.contains(name) ? faceNeeds(property) : ToolSchema.nullable(faceNeeds(property)))
            }))
        }
        if let items = rules["items"] { rules["items"] = faceNeeds(items) }
        return .object(rules)
    }
}

struct ToolHost: OwnedProgramHostProfile {
    static let primitives = ToolPrimitiveBroker.operations.union(["apps.call", "part.call", PartOpenURLRequest.operation])
    static func readOnly(_ candidate: OwnedProgramStore.Candidate, input: JSONValue) -> Bool {
        guard let verb = input.objectValue?["verb"]?.stringValue else { return false }
        return candidate.manifest.objectValue?["answers"]?.objectValue?[verb]?.objectValue?["class"] == .string("read")
    }
    let base: any OwnedProgramToolHost
    let candidate: OwnedProgramStore.Candidate
    let broker: ToolPrimitiveBroker
    let streamRun = ToolPrimitiveBroker.StreamRun()
    let dataRoot: URL
    let openScreenWatch: (@Sendable (MacScreenWatch.Request, Bool) async throws -> MacScreenWatch)?
    var projection = false
    var preview = false
    /// A verb the part declares read runs read-confined: its app events, app actions and primitives can only read.
    var readOnly = false
    let admission: @Sendable () async throws -> Void
    private var appTargets: [String: String] {
        var targets: [String: String] = [:]
        for grant in broker.permissions {
            switch grant {
            case .appWrite(let app): targets[app] = readOnly ? "read" : "write"
            case .appRead(let app) where targets[app] == nil: targets[app] = "read"
            default: break
            }
        }
        return targets
    }
    private var readPaths: [String] { JSONValue.stringArray(Parts.fields(Parts.fields(candidate.manifest)["reach"] ?? .null)["readPaths"] ?? .array([])) }
    /// A read verb's run refuses anything that can change something, before it is admitted or sent.
    private func readRefusal(_ operation: String, _ arguments: JSONValue) -> JSONValue? {
        guard readOnly else { return nil }
        let reads = operation == "apps.call" ? AuthoredToolEffects.appReadOnly(Parts.fields(arguments))
            : operation != "part.call" && ToolPrimitiveBroker.readOnly(operation, arguments)
        return reads ? nil : Self.failure("read_verb", "\(operation) can change something, and this verb is declared read, so it only reads. Nothing ran.",
            effects: "none", execution: "not_run")
    }
    var actionIDs: [String] { candidate.program.dependencies }
    private var modelOnly: Bool { candidate.id == DreamPart.id || candidate.id == MindMemoryJudgment.DigestPart.id }
    var allowsNotebook: Bool {
        !modelOnly && candidate.id != FieldRepairPart.id
    }

    func checkNotebook(_ value: Data?, keyedWrite: Bool) async throws {
        guard !keyedWrite || !readOnly else {
            throw SenseFailure(code: "read_verb", message: "This read verb cannot change keyed notebook entries.")
        }
        try await admission()
        if let value { try await broker.checkNotebook(value) }
    }
    private func declaredDependency(_ id: String) throws -> String? {
        let resolved = try base.canonicalAction(id)
        return try candidate.program.dependencies.first { try base.canonicalAction($0) == resolved }
    }
    var floorReasons: Set<String> { base.floorReasons.union(["undeclared_dependency", "state_changed"]) }
    var scriptKey: String { base.scriptKey }
    func action(_ id: String) throws -> OwnedProgramAction? {
        if projection { return nil }
        guard let action = try base.action(id) else { return nil }
        let permissions = candidate.program.permissions
        return try declaredDependency(id) != nil || AbilityStore.reachActions(permissions).contains(base.canonicalAction(id)) ? action : nil
    }
    func canonicalAction(_ id: String) throws -> String { try base.canonicalAction(id) }
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
        do {
        guard try action(id) != nil else {
            if try declaredDependency(id) != nil, try base.action(id) == nil {
                return .failure(.init(reason: "dependency_unavailable", detail: """
                    \(id) is declared by ability \(candidate.id), but is unavailable in this app door. Use app find to inspect it; an authored dependency \
                    may need to be kept or enabled. It was not called.
                    """))
            }
            let declared = Parts.fields(candidate.manifest)["declaredActions"].map { JSONValue.stringArray($0) } ?? candidate.program.dependencies
            let actions = Set(declared + [id]).sorted().map { "\"" + $0 + "\"" }.joined(separator: ", ")
            return .failure(.init(reason: "undeclared_dependency",
                detail: "\(id) is not among the actions ability \(candidate.id) declares, so it was not called. "
                + "An action named at run time isn't read off the code: declare it with ability.save {id:\"\(candidate.id)\", actions:[\(actions)]}."))
        }
        return base.doorInput(id: id, given: given)
        } catch { return .failure(.init(reason: "action_catalog_unavailable",
            detail: "The ability's action catalog is unavailable: \(error.localizedDescription). Repair its owner before running this call.")) }
    }
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool { base.opensHomeItem(input) }
    func callArgumentsForEvidence(_ id: String, given: [JSONValue]) throws -> [JSONValue] {
        try base.callArgumentsForEvidence(id, given: given)
    }
    func secretLine(_ text: String) -> Bool { base.secretLine(text) }
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence { base.evidence(receipt) }
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { base.receiptField(key, in: receipt) }
    func answer(_ receipt: JSONValue) -> JSONValue { base.answer(receipt) }
    /// Read/find envelopes need no action declaration because every part may inspect its app surface.
    private func reads(_ call: [String: JSONValue]) -> Bool {
        call["action"] == nil && (call["page"] != nil || call["find"] != nil)
    }
    func validationPerform(_ call: [String: JSONValue], fixture: OwnedProgramFixtures, execution: OwnedProgramExecution) async -> JSONValue {
        if reads(call) { return await fixture.reply(call, execution: execution) }
        guard case .string(let id)? = call["action"] else {
            return Self.failure("invalid_args", "A rehearsal call needs an action id.", effects: "none", execution: "not_run")
        }
        if case .failure(let error) = doorInput(id: id, given: [call["args"] ?? .object([:])]) {
            var fields = Parts.fields(Self.failure(error.reason, error.detail, effects: "none", execution: "not_run"))
            fields["try_instead"] = error.tryInstead
            return .object(fields)
        }
        // Interception must not turn a malformed dynamic call into a successful rehearsal. Live execution reaches this same schema at the app door.
        do {
            if let problem = try base.callProblem(id, given: [.object((call["args"]?.objectValue ?? [:]).mapValues(OwnedProgram.Calls.Argument.value))]) {
                var fields = Parts.fields(Self.failure("invalid_args", "\(id) \(problem).", effects: "none", execution: "not_run"))
                fields["try_instead"] = try await base.callAdvice(id, given: [.value(call["args"] ?? .object([:]))])
                return .object(fields)
            }
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
        return await fixture.reply(call, execution: execution)
    }

    func perform(_ call: [String: JSONValue], execution: OwnedProgramExecution) async -> JSONValue {
        if projection { return Self.failure("projection_only", "A face reads only its frozen sources.", effects: "none") }
        if candidate.id == FieldRepairPart.id {
            return Self.failure("undeclared_dependency", "Field repair reads its captured evidence.", effects: "none")
        }
        if modelOnly {
            return Self.failure("undeclared_dependency", "This part reads its captured evidence and calls only its model.", effects: "none")
        }
        var call = call
        // JavaScript and model tools share this boundary. Neither can bypass authored secret/typed-text restrictions by supplying raw app JSON.
        if opensHomeItem(call) {
            return Self.failure("home_item_in_script", "A part cannot open a home arrival from inside its own run.", effects: "none")
        }
        if let id = call["action"]?.stringValue,
           case .failure(let error) = doorInput(id: id, given: [call["args"] ?? .object([:])]) {
            return Self.failure(error.reason, error.detail, effects: "none")
        }
        // A named action read must pass its declaration and read classification so preview/live reads cannot become writes.
        do {
        if reads(call), let page = call["page"]?.stringValue, page.contains("."), let named = try base.action(page) {
            guard named.read else {
                return Self.failure("not_a_read", "app.read(\"\(page)\") names an action that changes something; a read never runs it. "
                    + "Call it as its own action, declared, if the ability means to.", effects: "none")
            }
            call = call.filter { $0.key.hasPrefix("__") || $0.key == "preview" }.merging(["action": .string(page), "args": .object([:])]) { $1 }
        }
        // A read goes through the same selection check and gates as any call.
        guard try reads(call) || call["action"]?.stringValue.map({ try action($0) != nil }) == true else {
            return Self.failure("undeclared_dependency", "An ability calls only its declared app actions.", effects: "none")
        }
        if readOnly, let id = call["action"]?.stringValue, let named = try base.action(id),
           !(named.read || named.readOnly(Parts.fields(call["args"] ?? .null))) {
            return Self.failure("read_verb", "\(id) changes something, and this verb is declared read, so it only reads. Nothing ran.", effects: "none")
        }
            try Task.checkCancellation()
            try await admission()
            try Task.checkCancellation()
            let permissions = broker.permissions
            let reach = permissions.contains(.flag(.appDataRead)) || permissions.contains(.flag(.appDataWrite))
                ? (root: dataRoot, write: permissions.contains(.flag(.appDataWrite))) : nil
            var execution = execution
            if var turn = execution.turn { turn.fileReach = reach; execution.turn = turn }
            if preview {
                call["preview"] = .bool(true)
                execution.turn?.doorPreview = .program(candidate.id)
            }
            if call["action"] != nil {
                let broker = self.broker
                let inherited = execution.anatomyScrub
                execution.anatomyScrub = {
                    let parent = await inherited?()
                    let scrub = await broker.anatomyRedactor()
                    let revision = scrub.values.count
                    return .init(text: { text in scrub(parent?.text(text) ?? text) }, isCurrent: {
                        if let parent, !(await parent.isCurrent()) { return false }
                        return await broker.anatomyRedactorIsCurrent(revision)
                    })
                }
            }
            return await base.perform(call, execution: execution)
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
    }

    func primitiveAction(_ operation: String) -> OwnedProgramAction? {
        if operation == "part.call" { return .init(id: operation, page: "tools", read: false, program: true, readOnly: { _ in false }) }
        let files = OwnedProgramRunner.hostFilePrimitives.contains(operation)
        guard files || Self.primitives.contains(operation) else { return nil }
        let read = ToolPrimitiveBroker.readOperations.contains(operation)
        let space = String(operation.prefix { $0 != "." })
        let page = ["apps.call", PartOpenURLRequest.operation, MacAXQuery.operation].contains(operation) ? "apps" : files ? "files"
            : ["screen", "frame", "hand"].contains(space) ? "screen" : space == "program" ? "shell" : "network"
        return OwnedProgramAction(id: operation, page: page, read: read,
                                  journaled: !ToolPrimitiveBroker.frameOperations.union(ToolPrimitiveBroker.programOperations).contains(operation),
                                  readOnly: { ToolPrimitiveBroker.readOnly(operation, .object($0)) })
    }

    func checkPrimitive(_ operation: String, arguments: JSONValue, fixture: OwnedProgramFixtures?, execution: OwnedProgramExecution) async -> JSONValue? {
        if projection { return Self.failure("projection_only", "A face reads only its frozen sources.", effects: "none") }
        if candidate.id == FieldRepairPart.id {
            return Self.failure("not_declared", "Field repair reads its captured evidence.", effects: "none")
        }
        if modelOnly, operation != "model.call" {
            return Self.failure("not_declared", "This part calls only its model.", effects: "none")
        }
        if let refused = readRefusal(operation, arguments) { return refused }
        do {
            if OwnedProgramRunner.hostFilePrimitives.contains(operation) {
                _ = try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths,
                    permissions: broker.permissions, dataRoot: dataRoot)
            } else if operation == "part.call" {
                _ = try partRequest(arguments)
            } else if operation == PartOpenURLRequest.operation {
                _ = try await checkedOpenURL(arguments, context: execution.macOperation(dataRoot: dataRoot))
            } else if operation == "apps.call" {
                try Task.checkCancellation()
                guard case .object(let args) = arguments, case .string(let bundleID)? = args["bundle_id"],
                      let access = appTargets[bundleID] else {
                    throw SenseFailure(code: "undeclared_target", message: "Declare app_read:<bundle_id> or app_write:<bundle_id> for this target.")
                }
                guard access == "write" || AuthoredToolEffects.appReadOnly(args) else {
                    throw SenseFailure(code: "read_only", message: "A read-declared app refuses modifying or unclassified events.")
                }
                try AppleScriptExecution.checkAppScript(args)
                if !AuthoredToolEffects.appReadOnly(args), let refusal = MacAppActGate.refusal(bundleID: bundleID, throughAppleEvents: true,
                    context: execution.macOperation(dataRoot: dataRoot)) { throw refusal }
            } else {
                var fixtureOwnsStream = false
                if let fixture, OwnedProgramRunner.layeredHostPrimitives.contains(operation), !ToolPrimitiveBroker.streamOpenOperations.contains(operation),
                   let id = Parts.fields(arguments)["id"]?.stringValue {
                    let websocket = operation.hasPrefix("network.websocket.")
                    fixtureOwnsStream = await fixture.ownsStream(id, opening: websocket ? "network.websocket.open" : "fetch.sse.open",
                        reading: websocket ? "network.websocket.receive" : "fetch.sse.next",
                        closing: websocket ? "network.websocket.close" : "fetch.sse.close")
                }
                try await broker.check(operation, arguments: arguments, run: streamRun, fixtureOwnsStream: fixtureOwnsStream)
            }
            return nil
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
    }

    private func checkedOpenURL(_ arguments: JSONValue, context: MacOperationContext) async throws -> (PartOpenURLRequest, URL) {
        try Task.checkCancellation()
        let request = try PartOpenURLRequest(arguments)
        let missing = request.missingAppReach(broker.permissions)
        guard missing.isEmpty else {
            throw Parts.revisionFailure("undeclared_target", "Declare reach.capabilities \(missing.joined(separator: ", ")) to open this app URL.",
                id: candidate.id)
        }
        let matches = try await MacAppIndex.shared.apps(context: context).filter {
            $0.bundleID.flatMap(OpenURLClassification.normalizedBundleID) == request.bundleID
        }
        let installed = MacAppIndex.installed(matches)
        guard !matches.contains(where: \.installationUncertain), installed.count == 1, let target = installed.first,
              let info = try? Data(contentsOf: target.url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: info, options: [], format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              OpenURLClassification.normalizedBundleID(bundleID) == request.bundleID else {
            throw SenseFailure(code: "bundle_not_installed", message: "No unique installed Mac app could be verified for \(request.bundleID).")
        }
        guard let types = plist["CFBundleURLTypes"] as? [[String: Any]], types.contains(where: { type in
            (type["CFBundleURLSchemes"] as? [String])?.contains(where: { OpenURLClassification.normalizedScheme($0) == request.scheme }) == true
        }) else {
            throw SenseFailure(code: "scheme_not_owned_by_bundle", message: "The installed \(bundleID) does not declare the \(request.scheme) scheme.")
        }
        guard !request.needsShellReach(broker.permissions) else {
            throw Parts.revisionFailure("undeclared", "Declare reach.capabilities shell to open this shell-level app URL.", id: candidate.id)
        }
        if let refusal = MacAppActGate.refusal(bundleID: bundleID, context: context) { throw refusal }
        return (request, target.url)
    }

    @MainActor private static func openURL(_ request: PartOpenURLRequest, at target: URL) async throws -> JSONValue {
        try Task.checkCancellation()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = request.activate
        config.addsToRecentItems = false
        config.allowsRunningApplicationSubstitution = false
        do {
            let app = try await NSWorkspace.shared.open([request.url], withApplicationAt: target, configuration: config)
            return receipt(.object(["status": .string("ok"), "bundle_id": .string(request.bundleID), "scheme": .string(request.scheme),
                "open_url_class": .string(request.classification.rawValue), "activated": .bool(request.activate && app.isActive),
                "pid": .int(Int64(app.processIdentifier))]), effects: "occurred")
        } catch {
            return failure(error, effects: "unknown", execution: "attempted")
        }
    }

    private func partRequest(_ arguments: JSONValue) throws -> (id: String, input: JSONValue) {
        try Task.checkCancellation()
        let args = Parts.fields(arguments)
        guard !projection, let id = args["id"]?.stringValue, AbilityStore.isAbilityID(id),
              let input = args["input"], case .object = input,
              try input.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
            throw SenseFailure(code: "bad_input", message: "part.call takes an exact id and a JSON object input of at most 4 MiB.")
        }
        guard try declaredDependency("authored." + id) != nil else {
            throw SenseFailure(code: "undeclared_dependency", message: "Declare authored.\(id) in actions before calling that part.")
        }
        return (id, input)
    }

    func primitive(_ operation: String, arguments: JSONValue, preview: Bool, execution: OwnedProgramExecution) async throws -> JSONValue {
        if let refused = readRefusal(operation, arguments) { return refused }
        if modelOnly, operation == "part.call" {
            return Self.failure("not_declared", "This part calls only its model.", effects: "none")
        }
        if operation == "part.call" {
            // Pin before any admission/card wait. The existing gated authored action runs it, retaining its terminal envelope for value calls.
            do {
                let (id, input) = try partRequest(arguments)
                guard let version = try Parts(root: dataRoot).row(id)?["codeFingerprint"]?.stringValue else {
                    throw Parts.missing(id)
                }
                var execution = execution
                execution.valueIdentity = (id, version); execution.wake = nil
                let receipt = await perform(["action": .string("authored." + id), "args": input, "preview": .bool(preview)], execution: execution)
                let result = Parts.callResult(receipt, as: JSONValue.self)
                let fields = Parts.fields(receipt)
                let effects = fields["effects"]?.stringValue ?? Parts.fields(fields["result"] ?? .null)["effects"]?.stringValue ?? "unknown"
                return Self.receipt(try .fromEncodable(result), effects: effects)
            } catch {
                let failure = PartCallResult<JSONValue>.failure(.init(code: error is CancellationError ? "cancelled"
                    : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed", message: error.localizedDescription))
                return Self.receipt(try .fromEncodable(failure), effects: "none")
            }
        }
        if let refused = await checkPrimitive(operation, arguments: arguments, fixture: nil, execution: execution) { return refused }
        if preview, ["model.call", "screen.watch", "screen.next", "network.receive", "program.receive", "network.websocket.receive",
                     "fetch.sse.next", PartOpenURLRequest.operation].contains(operation) {
            return .object(["status": .string("preview"), "effects": .string("none"), "execution": .string("preview"), "result": .null])
        }
        if operation == "model.call" { return try await performPrimitive(operation, arguments: arguments, execution: execution) }
        // Watch frames and program reads/close stay inside their admitted operation while the same enabled version owns them. They reach
        // their broker without crossing the door, so each takes its call bound here; every other primitive takes it at the door.
        if ToolPrimitiveBroker.frameOperations.contains(operation) || ["program.receive", "program.close"].contains(operation) {
            let read = ToolPrimitiveBroker.readOnly(operation, arguments)
            let run: @Sendable (OwnedProgramExecution) async throws -> JSONValue = { execution in
                if operation.hasPrefix("program.") {
                    do { try await self.admission() } catch { await self.broker.end(arguments); throw error }
                }
                return Self.receipt(try await self.broker.perform(operation, arguments: arguments, run: self.streamRun, host: self.base, execution: execution,
                    openScreenWatch: self.openScreenWatch), effects: read ? "none" : "occurred")
            }
            do {
                return try await CallBound.run(name: operation, declared: CallBound.declaredSeconds(input: Parts.fields(arguments)),
                    deadlines: execution.deadlines, enclosing: execution.turn?.enclosingCall) { deadlines, call in
                    var bounded = execution
                    bounded.deadlines = deadlines
                    bounded.turn = execution.turn?.with(\.enclosingCall, call)
                    return try await run(bounded)
                }
            } catch let ended where CallBound.ended(ended, name: operation) != nil {
                var receipt = CallBound.ended(ended, name: operation)?.objectValue ?? [:]
                if read { receipt["effects"] = .string("none") }
                receipt["result"] = .null
                return .object(receipt)
            } catch {
                return Self.failure(error, effects: read ? "none" : "unknown", execution: "attempted")
            }
        }
        // Each new effect requires current ability admission and Trust; refused program input ends its program.
        let effect = AuthoredToolEffects.primitiveEffect(operation, arguments: arguments)
        let args = Parts.fields(arguments)
        if ToolPrimitiveBroker.streamOpenOperations.contains(operation) { await broker.observeStreams() }
        let result = await base.admitTool(effect.tool, input: args, execution: execution, effect: {
            try await self.performPrimitive(operation, arguments: arguments, execution: execution)
        })
                ?? Self.failure(SenseFailure(code: "door_unavailable", message: "A primitive needs the app door's gate chain from a conversation or wake run.",
                    remedy: Repair.reconcile(instruction: """
                        Read ability \(candidate.id) and its recorded effects, then do only the missing work through the gated app door of a conversation \
                        or wake run.
                        """, nextCall: Parts.readCall(candidate.id))), effects: "none", execution: "not_run")
        if operation == "program.send", Parts.fields(result)["status"] != .string("ok") { await broker.end(arguments) }
        return result
    }

    private func performPrimitive(_ operation: String, arguments: JSONValue, execution: OwnedProgramExecution) async throws -> JSONValue {
        var dispatched = false
        do {
            try await admission()
            guard await !broker.closed else { throw CancellationError() }
            if operation == PartOpenURLRequest.operation {
                let (request, target) = try await checkedOpenURL(arguments, context: execution.macOperation(dataRoot: dataRoot))
                return try await Self.openURL(request, at: target)
            }
            dispatched = true
            let result = if operation == "apps.call" {
                try await AppleScriptExecution().callApp(arguments, targets: appTargets, context: execution.macOperation(dataRoot: dataRoot))
            } else if operation == "files.query" {
                try PartFileReads.query(try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths,
                    permissions: broker.permissions, dataRoot: dataRoot), Parts.fields(arguments))
            } else if operation == "files.mime" {
                try PartFileReads.mime(try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths,
                    permissions: broker.permissions, dataRoot: dataRoot), Parts.fields(arguments), readPaths: readPaths,
                    permissions: broker.permissions, dataRoot: dataRoot)
            } else if operation == "files.names" {
                try PartFileReads.names(try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths,
                    permissions: broker.permissions, dataRoot: dataRoot), Parts.fields(arguments))
            } else { try await broker.perform(operation, arguments: arguments, run: streamRun, host: base, profile: self, execution: execution,
                openScreenWatch: openScreenWatch) }
            // The thought's envelope already carries its nested tool effects.
            if operation == "model.call" { return result }
            if operation == "apps.call", result.objectValue?["status"] == .string("denied") { return result }
            let read = ToolPrimitiveBroker.readOnly(operation, arguments)
            // A 429 or 5xx answer fails the fetch and keeps the response it names, so its body and Retry-After stay readable.
            if ["fetch", "fetch.sse.open"].contains(operation), case .int(let status)? = Parts.fields(result)["status"],
               status == 429 || (500...599).contains(status) {
                let host = Parts.fields(arguments)["url"]?.stringValue.flatMap { URL(string: $0)?.host } ?? "the service"
                var failed = Parts.fields(Self.failure(SenseFailure(code: "http_\(status)", message: """
                    fetch returned HTTP \(status) from \(host). Inspect the service's response in result and its state; for 429 reduce request \
                    rate, for 5xx address the service failure before another request.
                    """, remedy: Repair.reconcile(instruction: """
                    Read the response in result and the service's state before repeating ability \(candidate.id)'s fetch; a modifying request's \
                    effects are uncertain.
                    """, nextCall: Parts.readCall(candidate.id))), effects: read ? "none" : "unknown", execution: "attempted"))
                failed["result"] = result
                return .object(failed)
            }
            // Effect receipts derive from observed events, never app-call intent.
            let observed = if operation == "apps.call", case .object(let fields) = result, case .string(
                let effects)? = fields["effects"] { effects } else { nil as String? }
            if operation == "apps.call", case .object(let fields) = result, case .string(let state)? = fields["state"] {
                let effects = observed ?? (read || ["needs_consent", "denied", "unavailable"].contains(state) ? "none" : "unknown")
                // A write that may have landed is unknown, never refused: a refusal says nothing happened.
                var refusal: [String: JSONValue] = ["status": .string(effects == "unknown" ? "unknown" : "refused"), "reason": .string(state),
                    "detail": fields["detail"] ?? .string(state), "result": result, "effects": .string(effects)]
                refusal["remedy"] = fields["remedy"]
                return .object(refusal)
            }
            return Self.receipt(result, effects: observed ?? (read ? "none" : "occurred"))
        } catch {
            // A refused screen-control card cannot claim execution.
            if let refusal = error as? MacScreenWatch.Refusal {
                return .object(Parts.fields(refusal.receipt).merging(["effects": .string("none")]) { said, _ in said })
            }
            return Self.failure(error,
                effects: !dispatched || ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "unknown",
                execution: dispatched ? "attempted" : "not_run")
        }
    }

    static func receipt(_ result: JSONValue, effects: String) -> JSONValue {
        .object(["status": .string("ok"), "effects": .string(effects), "result": result])
    }
    static func failure(_ error: Error, effects: String, execution: String) -> JSONValue {
        if let refusal = error as? MacAppActRefusal { return .object(refusal.fields.merging([
            "effects": .string(effects), "execution": .string(execution)
        ]) { said, _ in said }) }
        let owned = error as? ToolFailureError
        let sense = error as? SenseFailure
        let reason = owned?.failureCode ?? sense?.code ?? (error is CancellationError ? "cancelled" : "world_error")
        var fields = sense?.failureEvidence() ?? Parts.fields(failure(reason, error.localizedDescription,
            effects: owned?.effects.rawValue ?? effects, execution: execution,
            status: owned?.status.rawValue ?? (reason == "cancelled" ? "cancelled" : "failed")))
        fields["effects"] = .string(owned?.effects.rawValue ?? effects)
        fields["execution"] = .string(execution)
        fields["result"] = .null
        fields["failure_code"] = .string(reason)
        if let owned {
            fields.merge(owned.failureEvidence(defaultCode: reason)) { _, owned in owned }
        } else if fields["remedy"] == nil, reason == "cancelled" {
            fields["remedy"] = Repair.terminal(instruction: "The caller cancelled this work; do not resume it without a new request.")
        }
        return .object(fields)
    }

    static func failure(_ reason: String, _ detail: String, effects: String, execution: String? = nil, status: String = "refused") -> JSONValue {
        var fields: [String: JSONValue] = ["status": .string(status), "reason": .string(reason), "detail": .string(detail),
                                         "effects": .string(effects), "result": .null]
        if let execution { fields["execution"] = .string(execution) }
        return .object(fields)
    }
}
