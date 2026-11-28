import SenseCore
import MacNerves
import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import MindCore
import ProviderRouting
// Blueprint: | `ActionRuntime.swift` | Normalized dispatch; pure validation; part-write receipts |
final class ActionRuntime: Sendable {
    let allowsCanonicalBodyTools: Bool
    var usesCanonicalBody: Bool { allowsCanonicalBodyTools }

    let dataRoot: URL
    let bodyField: BodyField?
    let jobStore: AgentJobStore
    let dotTransport: ChatGPTDotIPCTransport?
    let pageReader: SwiftNativeResearchClient
    /// Local durable enqueue only: return the accepted request ID after writing, without executing a provider or waiting for a bot run. Supplied by the
    /// runner's app assembly; nil reports unavailable rather than fake success.
    let standingBotRunner: BotRunner?
    let standingBotRunEnqueue: (@Sendable (UUID, String?, Turn, Set<UUID>) throws -> BotRunReceipt)?
    /// Exact semantic-memory owner for this dispatcher body. Alternate roots must never fall through to the process-wide production singleton.
    private let memoryOwner: Mutex<SwiftNativeMemoryV2?>
    var memoryV2: SwiftNativeMemoryV2 {
        get throws {
            try memoryOwner.withLock { owner in
                if let owner { return owner }
                let storage: MemoryStorage
                do {
                    storage = try MemoryStorage(dataRoot: dataRoot)
                } catch {
                    throw MemoryStorageError.databaseUnavailable(error.localizedDescription).failure
                }
                let opened = SwiftNativeMemoryV2(embedder: ManagedEmbeddingProvider(dataRoot: dataRoot), storage: storage)
                owner = opened
                return opened
            }
        }
    }
    let knowledgeGraphPath: URL
    let providerLifecycleObserver: (any LLMCallLifecycleObserving)?
    /// The cognition runtime's journal bus; no other dispatcher or global body supplies it.
    let studioJournalBus: StudioJournalCognitiveBus?
    /// Headless contexts have no Mac integration bridge; return bridge_not_wired rather than claim execution.
    public let macIntegrationBridge: (any ChatMacIntegrationToolBridge)?
    /// Permission authority for the Mac integration route. Production uses the shared app-root store; an explicit store keeps a dispatcher assembled for
    /// another root from consulting live permission state.
    let macIntegrationPermissionStore: MacIntegrationPermissionStore
    let agentBridgeConfigRoot: URL?
    let a2aPushConfiguration: (@Sendable (AgentPeerContact) async throws -> JSONValue)?
    /// Connector execution context; relative file reads resolve only in the canonical workspace, with an explicit namespace for bundled docs.
    var rootForRead: URL { dataRoot.deletingLastPathComponent().standardizedFileURL }

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        bodyField: BodyField? = nil,
        allowProcessGlobalTools: Bool = true,
        dotTransport: ChatGPTDotIPCTransport? = nil,
        jobStore: AgentJobStore? = nil,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        studioJournalBus: StudioJournalCognitiveBus? = nil,
        macIntegrationBridge: (any ChatMacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async throws -> JSONValue)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID, String?, Turn, Set<UUID>) throws -> BotRunReceipt)? = nil,
        standingBotRunner: BotRunner? = nil
    ) {
        self.dataRoot = dataRoot
        self.bodyField = bodyField
        self.jobStore = jobStore ?? AgentJobStore(dataRoot: dataRoot)
        self.dotTransport = dotTransport
        self.pageReader = SwiftNativeResearchClient(dataRoot: dataRoot)
        self.standingBotRunEnqueue = standingBotRunEnqueue
        self.standingBotRunner = standingBotRunner
        self.memoryOwner = Mutex(SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) ? .shared : nil)
        self.knowledgeGraphPath = DataRootPaths.memoryDatabase(in: dataRoot)
        self.allowsCanonicalBodyTools = allowProcessGlobalTools
        self.providerLifecycleObserver = providerLifecycleObserver
        self.studioJournalBus = studioJournalBus
        self.macIntegrationBridge = macIntegrationBridge
        self.macIntegrationPermissionStore = macIntegrationPermissionStore
            ?? (dataRoot == PersistenceCore.defaultDataRoot()
                ? .shared
                : MacIntegrationPermissionStore(dataRoot: dataRoot))
        self.agentBridgeConfigRoot = agentBridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        self.a2aPushConfiguration = a2aPushConfiguration
    }

}

extension SwiftToolDispatcher {
    /// Only bare web addresses gain https://; explicit schemes, file names and navigation words retain their meaning.
    static func withWebScheme(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:[/?#]\S*)?$"#
        guard text.range(of: bare, options: [.regularExpression, .caseInsensitive]) != nil else { return raw }
        let host = text.prefix { !":/?#".contains($0) }.lowercased()
        return fileSuffixes.contains(String(host.split(separator: ".").last ?? "")) ? raw : "https://" + text
    }
    private static let fileSuffixes: Set<String> = ["txt", "md", "json", "jsonl", "pdf", "png", "jpg", "jpeg", "gif", "heic",
        "webp", "svg", "swift", "js", "ts", "py", "rb", "rs", "sh", "html", "css", "csv", "tsv", "log", "zip", "gz", "tar",
        "dmg", "pkg", "app", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "mov", "mp3", "mp4",
        "wav", "yaml", "yml", "toml", "xml", "plist", "sql", "db", "rtf", "ipynb"]

    public func dispatch(tool requestedTool: String, input rawInput: [String: JSONValue], surface: String, turn: Turn,
        invocation: ChatToolInvocation) async throws -> JSONValue {
        try await makeGatedToolDispatchClient(tools: self, jobStore: jobStore, fileAccess: turn.fileAccess ?? "auto",
            dataRoot: dataRoot, verifiedSessionId: turn.verifiedSessionID)
            .dispatch(tool: requestedTool, input: rawInput, surface: surface, turn: turn, invocation: invocation)
    }

    public func executeAdmitted(_ admission: consuming SecurityToolAdmission, invocation: ChatToolInvocation) async throws -> JSONValue {
        if let appEnvironment {
            return try await appEnvironment.executeAdmitted(consume admission, client: self, invocation: invocation)
        }
        let (tool, input, surface, turn) = (admission.tool, admission.input, admission.surface, admission.turn)
        return try await withToolArguments(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface) { input, invocation in
            _ = try admission.decision(for: input)
            return try await MacAppActGate.withAdmission(origin: .currentTurn(turn: turn, surface: surface), dataRoot: dataRoot, turn: turn,
                context: invocation.macContext(dataRoot: dataRoot)) { turn, context in
                ChatToolOutcome.normalizedFailure(try await dispatchAdmitted(turn: turn, invocation: invocation.serving(mac: context),
                    tool: tool, input: input, surface: surface), tool: tool, throughAppDoor: invocation.appDoor != nil)
            }
        }
    }
    func dispatchAdmitted(turn: Turn, invocation: ChatToolInvocation, tool requestedTool: String, input rawInput: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        var input = rawInput
        let invocation = invocation.with(\.bodyField, bodyField)
        if ToolCallParser.isIgnorableToolName(tool) {
            return .object([
                "status": .string("ignored"),
                "reason": .string("placeholder_tool_name"),
                "tool": .string(tool),
            ])
        }
        if !usesCanonicalBody, Self.canonicalBodyOnlyToolNames.contains(tool) {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("canonical_body_unavailable"),
                "detail": .string("\(tool) is not available in this context, so nothing ran."),
                "tool": .string(tool),
            ])
        }
        var deskState: DeskState?
        if Self.deskItemTools.contains(tool) {
            if tool == "desk_wait" {
                try ActionCatalog.catalog.contract("desk_wait").admitHost(input)
            }
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            deskState = state
            let handle = try resolveDeskHandle(input, in: state)
            input["handle"] = .string(handle)
            if let refusal = try await deskHeld(handle) { return refusal }
        }
        // A contributed tool runs in its owner's executor.
        if let appTools, executorOwnedToolNames.contains(tool) {
            return try await dispatchContributedTool(appTools, turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
        }
        if Self.fileAccessGatedToolNames.contains(tool), try await !fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed {
            return builderFullMacRequired(invocation: invocation, tool: tool, input: input)
        }
        if let descriptor = ActionCatalog.current.tools[tool] {
            return try await descriptor.bound(input, invocation: invocation).run(ActionContext(client: self, turn: turn, invocation: invocation, tool: tool,
                surface: surface, deskState: deskState, transportMetadata: input.filter { $0.key.hasPrefix("__") }))
        }
        return try await dispatchAuthoredPart(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
    }

    /// A contributed tool runs in its owner's executor; each call the app door carries is checked by the pre-approval and file-read preview
    /// refusals.
    func dispatchContributedTool(_ appTools: AppToolExecutor, turn: Turn, invocation: ChatToolInvocation, tool: String,
        input: [String: JSONValue], surface: String) async throws -> JSONValue {
        func execute(_ invocation: ChatToolInvocation) async throws -> JSONValue {
            let scoped = invocation.callExecution
            return try await appTools.execute(tool: tool, input: input, surface: surface, turn: turn, execution: scoped)
        }
        if tool == "app" {
            guard var door = invocation.appDoor else {
                throw ToolFailureError("The app door has no dispatcher. Nothing ran.", effects: .none, owner: "App dispatch")
            }
            let validate = door.validate
            door.validate = { name, arguments, turn, invocation in
                if let refusal = await validate(name, arguments, turn, invocation) { return refusal }
                return await self.fileReadPreviewRefusal(turn: turn, invocation: invocation, tool: name, input: arguments, surface: surface)
            }
            return try await execute(invocation.with(\.appDoor, door))
        }
        return try await execute(invocation)
    }

    /// A web search with its query, categories and time range; a failed search reports that it changed nothing.
    func dispatchWebSearch(args: WebSearchArgs) async throws -> JSONValue {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolFailureError("search needs query: the words to search for.", argumentPath: "query", effects: .none)
        }
        let reader = pageReader
        var result = await WebSearchRoutes.search {
            let categories = args.categories?.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await reader.search(query: query, categories: categories?.isEmpty == false ? categories : nil,
                                           timeRange: args.timeRange)
        }
        let reply = ToolResult(result)
        // A search only reads: a failed one changed nothing.
        if case .object(var fields) = result,
           !(reply.said("ok") && reply.status == fields["status"]?.stringValue) {
            fields["effects"] = .string("none")
            result = .object(fields)
        }
        return result
    }

    /// A public page read over HTTP, located by `find` when asked, answered through the sense door; a thin script shell is read again in Chrome.
    func dispatchReadPage(turn: Turn, invocation: ChatToolInvocation, args: ReadPageArgs,
        transportMetadata: [String: JSONValue]) async throws -> JSONValue {
        let url = Self.withWebScheme(args.url)
        guard let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil else {
            throw AutonomyGateError.toolDenied(reason: "read_page requires a public http(s) URL.")
        }
        let find = args.find?.trimmingCharacters(in: .whitespacesAndNewlines)
        if find?.isEmpty == true {
            throw AutonomyGateError.toolDenied(reason: "find must contain the words to locate in the page.")
        }
        let around: Int
        switch args.around {
        case nil: around = 1
        case .int(let value)? where (0...3).contains(value): around = Int(value)
        default: throw AutonomyGateError.toolDenied(reason: "around must be an integer from 0 through 3 surrounding paragraphs.")
        }
        let full = args.full ?? false
        let fetched: JSONValue
        do { fetched = try await self.pageReader.fetchURL(url).readJSON(find: find, around: around, full: full) }
        catch ResearchClientError.httpStatus(let status) {
            var failure: [String: JSONValue] = ["status": .string("failed"), "reason": .string("http_status"),
                "http_status": .int(Int64(status)),
                "url": .string(url), "effects": .string("none"),
                "message": .string(ResearchClientError.httpStatus(status).localizedDescription)]
            if [404, 410].contains(status) {
                failure["remedy"] = .object(["kind": .string("inspect"),
                    "instruction": .string("Use a different address or search for the page."), "next_call": .null])
            }
            return .object(failure)
        }
        catch let error as ResearchClientError where error.failureReason != nil {
            return .object(["status": .string("failed"), "reason": .string(error.failureReason!),
                "url": .string(url), "effects": .string("none"), "message": .string(error.localizedDescription)])
        }
        let observedURL: String = if case .object(let fields) = fetched, case .object(let coverage)? = fields["coverage"],
            case .string(let finalURL)? = coverage["final_url"] { finalURL } else { url }
        if case .object(let httpFields) = fetched, httpFields["coverage"]?.objectValue?["thin_page"] == .bool(true) {
            return try await readPageThroughBrowser(httpFields: httpFields, fetched: fetched, find: find, full: full, observedURL: observedURL,
                turn: turn, invocation: invocation, args: args)
        }
        let corner = SenseCorner.site(host: URL(string: observedURL)?.host?.lowercased() ?? parsed.host!.lowercased())
        var senseInput = transportMetadata.merging(args.wire) { _, argument in argument }
        senseInput["__sense_action"] = .string("web.read")
        let result = try await SenseDoor.read(corner: corner, address: observedURL, input: senseInput,
            scope: turn.verifiedSessionID ?? "",
            nativeCorner: .stream(id: "web"),
            operation: invocation.senseOperation(turn: turn),
            raw: { _ in fetched },
            material: { document, _ in
                let reply = ToolResult(document)
                guard case .object(let fields) = document,
                      !(reply.said("failed") && reply.status == fields["status"]?.stringValue) else {
                    throw SenseFailure(code: "source_unavailable", message: "The original reader refused this read.")
                }
                return .pageSnapshot(document)
            })
        return result
    }

    /// A thin HTTP page is read in a background Chrome tab; Chrome's text serves only when it measures richer, and the HTTP read is kept either way.
    private func readPageThroughBrowser(httpFields: [String: JSONValue], fetched: JSONValue, find: String?, full: Bool, observedURL: String,
        turn: Turn, invocation: ChatToolInvocation, args: ReadPageArgs) async throws -> JSONValue {
        // A successfully read script shell requires rendering. This is
        // reader selection, never recovery from an HTTP failure.
        func retainingHTTP(reason: String, attempted: Bool, browser: JSONValue? = nil, note: String) -> JSONValue {
            var fields = httpFields
            fields["status"] = .string("partial")
            fields["reason"] = .string(reason)
            fields["text_reader"] = .string("http")
            fields["used_browser"] = .bool(attempted)
            fields["http_read"] = fetched
            fields["browser_read"] = browser
            fields["reader_note"] = .string(note)
            return .object(fields)
        }
        guard let door = invocation.appDoor else {
            return retainingHTTP(reason: "browser_door_unavailable", attempted: false,
                note: "This call has no Chrome app door. The HTTP text is retained; rendered content remains unknown.")
        }
        var arguments: [String: JSONValue] = ["url": .string(observedURL), "new_tab": .bool(true)]
        if let find, !full { arguments["find"] = .string(find) }
        arguments[ReadPageArgs.rawField.name] = args.raw.map(JSONValue.bool)
        arguments[ReadPageArgs.wrongField.name] = args.wrong.map(JSONValue.bool)
        arguments[ReadPageArgs.whyField.name] = args.why.map(JSONValue.string)
        let browser: JSONValue
        do {
            // This nested navigation owns the rendered read. The enclosing
            // workspace sees web.read, so it cannot attach Chrome's page.
            browser = CanonicalToolNameDispatcher.actionResult(try await door.perform("app",
                ["action": .string("chrome.navigate"), "args": .object(arguments)], turn,
                invocation.with(\.frameSource, "direct")), action: "chrome.navigate")
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return retainingHTTP(reason: "browser_read_unavailable", attempted: true,
                browser: ChatToolOutcome.failure(error: error, tool: "chrome.navigate"),
                note: "Chrome did not return a readable page; its actual failure is attached. The HTTP text is retained.")
        }
        guard case .object(var fields) = browser else {
            return retainingHTTP(reason: "browser_read_unavailable", attempted: true, browser: browser,
                note: "Chrome returned no page envelope. The HTTP text is retained; rendered content remains unknown.")
        }
        let page = fields["page"]?.objectValue
        guard case .string(let httpText)? = httpFields["text"],
              let browserText = page?["text"]?.stringValue ?? page?["sense_page"]?.stringValue else {
            return retainingHTTP(reason: "browser_content_unmeasured", attempted: true, browser: browser,
                note: "Chrome supplied no measured readable text. The HTTP text is retained; Chrome's actual page or blocker is attached.")
        }
        // Measure the exact text each reader would serve, including an authored sense.
        let browserCharacters = browserText.filter { !$0.isWhitespace }.count
        let httpCharacters = httpText.filter { !$0.isWhitespace }.count
        let browserIsEmpty = browserCharacters == 0
            || ["read_window_empty", "find_not_observed"].contains(page?["reason"]?.stringValue ?? "")
        guard !browserIsEmpty, browserCharacters > httpCharacters else {
            let reason = browserIsEmpty ? "browser_read_empty" : "browser_read_not_richer"
            let detail = page?["reason"]?.stringValue ?? "No additional readable content was observed in this window."
            return retainingHTTP(reason: reason, attempted: true, browser: browser,
                note: "Chrome's background read did not contain more readable content "
                    + "(\(browserCharacters) non-whitespace characters in served text; HTTP \(httpCharacters)). "
                    + "The HTTP text is retained. Chrome: " + detail)
        }
        fields["text"] = .string(browserText)
        if let status = page?["status"] { fields["status"] = status }
        if fields["status"] == nil { fields["status"] = .string("partial") }
        fields["used_browser"] = .bool(true)
        fields["text_reader"] = .string("browser")
        fields["http_read"] = fetched
        if fields["url"] == nil { fields["url"] = .string(observedURL) }
        fields["reader_note"] = .string("""
            Chrome supplied more readable content than the thin HTTP text, so its background-tab read supplies text. The HTTP extraction and its \
            source receipt remain in http_read. Chrome's receipt and page describe what actually happened. Consent was not accepted or dismissed.
            """)
        return .object(fields)
    }

    /// A generated image is registered as a made artifact through its part; a failed registration keeps the images and says so.
    func dispatchImageGenerate(turn: Turn, invocation: ChatToolInvocation, input: ImageGenerateArgs, makeReference: String?, surface: String) async -> JSONValue {
        let generated = await impl_image_generate(turn: turn, invocation: invocation, input: input, surface: surface)
        let reply = ToolResult(generated)
        guard case .object(let generation) = generated, reply.said("ok"), reply.status == generation["status"]?.stringValue else { return reply.payload }
        let paths = (generation["images"]?.arrayValue ?? []).compactMap { image -> String? in
            guard let path = (image.objectValue?["path"])?.stringValue else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        // Provider execution stays native; the part composes its raw artifact result with make.add. Only this native receipt grants output provenance, not
        // the part's returned or supplied JSON.
        let registration = await Parts(root: dataRoot).call(id: "make-generated", input: .object([
                "generated": generated, "prompt": .string(input.prompt),
                "ref": makeReference.map(JSONValue.string) ?? .null]),
                within: .init(actions: ["make.add"], capabilities: []),
                invocation: invocation.partInvocation(turn: turn.with(\.makeRegistration, .init(generatedImagePaths: Set(paths))), surface: surface),
                as: JSONValue.self)
        switch registration {
        case .success(let result): return Self.studioImageInvitation(result)
        case .failure(let error):
            // Registration failed after generation completed. Keep the artifacts top-level for every reply surface and persistence.
            var response = generation
            response["status"] = .string("failed")
            response["reason"] = .string("make_registration_failed")
            response["detail"] = .string(error.message)
            response["effects"] = .string("unknown")
            return .object(response)
        }
    }

    /// The Mac's held location fix answers first; a denial with nothing held raises the Location permission card.
    func dispatchMacLocation(invocation: ChatToolInvocation) async throws -> JSONValue {
        // The fix the Mac holds answers first, whatever the permission now. Not yet asked: the reader's refusal carries the permission card's
        // remedy; this Settings-row card is for a denial with nothing held.
        let held = try await MacLocationReader.read(context: invocation.macContext(dataRoot: dataRoot))
        let reply = ToolResult(held)
        guard !Task.isCancelled, !invocation.expired else { throw invocation.cancellationError }
        guard case .object(let fields) = held, !(reply.said("ok") && reply.status == fields["status"]?.stringValue),
              [.denied, .restricted].contains(SystemPermissionPreflight.status(.location)) else { return held }
        return await Self.requestedInteraction(invocation: invocation, input: [
            "kind": .string("permission"), "target": .string("location"), "mode": .string("read"),
            "why": .string("I need Location Services to read where this Mac is."),
            "decline_consequence": .string("I can ask the paired iPhone for location or use a place you give me.")
        ], dataRoot: dataRoot)
    }

    /// A tool the built-ins do not name runs as an authored part pinned to its selected fingerprint, behind its integration switch or Full Mac
    /// file reach.
    func dispatchAuthoredPart(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue], surface: String)
        async throws -> JSONValue {
        // Authored calls use Parts.run with the selected fingerprint. Parts verifies admission on every run; keeping follows its Full Mac/owner authority
        // rule. Built-ins matched above.
        if let record = try registryToolRecord(tool) {
            guard case .string(let fingerprint)? = record["codeFingerprint"], !fingerprint.isEmpty else {
                return .object([
                    "status": .string("failed"),
                    "effects": .string("none"),
                    "reason": .string("unsigned_tool"),
                    "tool": .string(tool),
                    "fix": .string("""
                        Part '\(tool)' has no codeFingerprint in its selected abilities/<id>.js file. Read it with ability.read, then keep \
                        it with ability.enable.
                        """),
                ])
            }
            // A verb the part answers passes its integration switch as the native verb did: granted, or the person's inline grant request.
            if let gate = try Self.integrationGate(tool: tool, input: input, turn: turn) {
                let allowed = try await macIntegrationPermissionStore.allows(gate.integration, mode: gate.mode)
                if !allowed {
                    return try await Self.macIntegrationDeniedEnvelope(invocation: invocation, integration: gate.integration, mode: gate.mode,
                        store: macIntegrationPermissionStore)
                }
            } else if case .string(let verb)? = input["verb"], case .object(let reach)? = record["reach"],
                      case .array(let paths)? = reach["readPaths"], !paths.isEmpty, !(await fullMacYoloAdmitted(turn: turn, surface: surface)) {
                // The person's files with no app switch over them are Full Mac's to read, refused without a card as a native reader was.
                return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("failed"), "reason": .string("full_mac_required"),
                    "effects": .string("none"), "detail": .string("""
                        \(verb) reads files outside any app's switch, which needs admitted Full Mac and file-read permission. Check Trust and file \
                        access at the Mac; nothing was read and no card was raised.
                        """)]))
            }
            // Pin the selected fingerprint so a registry or manifest swap fails with fingerprintMismatch.
            var partInvocation = invocation.partInvocation(turn: turn, surface: surface)
            partInvocation = Parts.Invocation(host: partInvocation.host, execution: partInvocation.execution,
                arrived: partInvocation.arrived, progressed: partInvocation.progressed,
                openScreenWatch: { request, hands in
                    try await self.openScreenWatch(turn: turn, invocation: invocation, request, hands: hands, surface: surface)
                })
            return try await Parts(root: dataRoot)
                .run(id: tool, input: .object(input.filter { $0.key != "__session_id" }),
                     requiredFingerprint: invocation.valueCall.flatMap { $0.id == tool ? $0.version : nil } ?? fingerprint,
                     invocation: partInvocation)
        }
        throw AutonomyGateError.toolDenied(
            reason: "SwiftToolDispatcher: '\(tool)' is not in the dispatch table"
        )
    }
}
extension SwiftToolDispatcher {
    func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue? {
        let tool = CanonicalToolNameDispatcher.canonical(tool)
        if tool == "desk_close" {
            do { try Self.validateDeskClose(input) }
            catch { return ChatToolOutcome.failure(error: error, tool: tool) }
        }
        if let appTools, executorOwnedToolNames.contains(tool) {
            return await appTools.argumentRefusal(tool: tool, input: input, turn: turn, execution: execution)
        }
        if tool == "apply_patch" { return Self.builderValidatePatch(input["patch"]?.stringValue).refusal }
        return await macIntegrationBridge?.argumentRefusal(tool: tool, input: input, turn: turn)
    }
}
