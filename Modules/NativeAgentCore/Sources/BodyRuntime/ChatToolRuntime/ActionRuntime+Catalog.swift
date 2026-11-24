import Foundation
import Synchronization
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import DeskCore
import MindCore
import ProviderRouting
import MacNerves
import SenseCore
// Blueprint: | `ActionRuntime+Catalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |

struct ActionCatalog: Sendable {
    static let catalog = Self(minimumInterval: BotRunLimits.minimumInterval)
    let ordered: [ActionDescriptor]
    let tools: [String: ActionDescriptor]
    let minimumInterval: TimeInterval?

    init(minimumInterval: TimeInterval?) {
        self.minimumInterval = minimumInterval
        var rows = BrowserActions.webActions
        rows += FileActions.fileActions
        rows += MemoryActions.memoryReadActions
        rows += ChatActions.historyActions
        rows += QuietAdminActions.personaActions
        rows += ChatActions.turnActions
        rows += PersonalAppActions.personalAppActions
        rows += ScheduleActions.schedulerActions
        rows += MemoryActions.memoryWriteActions
        rows += DeskActions.collaborationActions
        rows += MemoryActions.innerStateActions
        rows += DeskActions.deskActions
        rows += StudioActions.studioActions
        rows += MemoryActions.memoryReviewActions
        rows += BotActions.standingBotActions(minimumInterval: minimumInterval)
        rows += AgentCommsActions.agentCommunicationActions
        rows += MacActions.macActions
        ordered = rows
        tools = Dictionary(uniqueKeysWithValues: rows.map { ($0.schema.name, $0) })
    }

    func contract(_ tool: String) throws -> DoorArgsContract {
        guard let action = tools[tool] else {
            throw ToolFailureError("The action's input contract is unavailable.", effects: .none,
                owner: "Tool catalog", instruction: "Repair its registered schema before calling it again.")
        }
        return action.args
    }

    private static let latest = Mutex(catalog)

    static var current: Self {
        latest.withLock { snapshot in
            let interval = BotRunLimits.minimumInterval
            if snapshot.minimumInterval != interval { snapshot = Self(minimumInterval: interval) }
            return snapshot
        }
    }
}

extension SwiftToolDispatcher {
    /// The fixed model-facing floor; pages and actions travel in results.
    public static let alwaysOnCoreNames: Set<String> = [
        "app",
    ]

    /// Read file/git executors. `ParallelToolDispatch` owns concurrency admission; `git_diff` runs alone because working-tree diff can rewrite the index.
    package static let fullMacReadOnlyFileToolNames: [String] = [
        "file_excerpt", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
    ]

    static let fullMacWriteFileToolNames: [String] = [
        "write_file", "move_file", "copy_file", "trash_file", "mac_screenshot_save", "mail_save_attachment",
    ]

    /// Share builder membership with dispatch so Full Mac and category gates cover exactly the advertised executors.
    package static let fullMacFileToolNames: [String] =
        fullMacReadOnlyFileToolNames + fullMacWriteFileToolNames

    package static let fullMacSystemToolNames: [String] = [
        "system_info", "mac_volume", "mac_media", "remote_node_list",
    ]


    /// Read-only Mac perception under the Accessibility category.
    static let fullMacAccessibilityReadToolNames: [String] = [
        // screen and wait are pure perception; they hold and expire nothing.
        "screen", "wait",
    ]

    /// Clipboard needs its own read/write gates: it neither walks AX nor injects input. Both require accessibilityAllowed, active Full Mac and the
    /// accessibility category, rechecked inside MacControl.
    static let macClipboardReadToolNames: [String] = ["clipboard_read"]
    static let macClipboardWriteToolNames: [String] = ["clipboard_write"]
    static let macClipboardToolNames: [String] =
        macClipboardReadToolNames + macClipboardWriteToolNames

    /// Menu reads walk AXMenuBar without opening it; menu_press invokes a handler and needs injection admission.
    static let macMenuReadToolNames: [String] = ["menu"]
    static let macMenuPressToolNames: [String] = ["menu_press"]
    static let macMenuToolNames: [String] = macMenuReadToolNames + macMenuPressToolNames

    /// Whole-document reads use spill paging rather than glance budgets and restore any viewport movement. They need accessibilityAllowed plus fileOpsAllowed
    /// and workspace policy for explicit or AXDocument-derived paths. Keep them separate from injection: they press, type and activate nothing.
    static let macReadToolNames: [String] = ["read"]

    /// Local activity reads require capture and separate agent admission, checked at discovery and dispatch.
    static let activityQueryToolNames: [String] = ["activity_query"]

    /// Injection requires a body-bound capability and refuses read_only access. Approved replay or checked Full Mac supplies it.
    static let fullMacAccessibilityInjectionToolNames: [String] = [
        // act drives the closed loop; go launches or activates, so both require injection admission.
        "act", "go",
    ]

    /// Ordinary turns carry only app; an absent exclusion never grants visibility to an internal executor.
    package static func isModelHidden(_ name: String) -> Bool {
        !alwaysOnCoreNames.contains(name)
    }

    /// Retained UI and Studio executors must stay outside the conversational catalog.
    public static func modelVisibleCatalogToolNames(
        _ availableToolNames: Set<String>
    ) -> Set<String> {
        availableToolNames.intersection(alwaysOnCoreNames)
    }

    /// Keep the always-on floor sorted and preserve incoming order for appended tools so advertised prefixes remain stable.
    package struct ToolContractOrdering: Sendable, Equatable {
        package let floor: [String]
        package let appended: [String]

        init(floor: [String], appended: [String]) {
            self.floor = floor
            self.appended = appended
        }

        package var advertised: [String] { floor + appended }

        /// Hash ordered contracts: reordering alone breaks a cached prefix just as adding a row does.
        package var fingerprintSHA256: String {
            let text = floor.joined(separator: "\n")
                + "\n\u{1F}\n"
                + appended.joined(separator: "\n")
            return SHA256Hex.of(Data(text.utf8))
        }
    }

    package static func canonicalToolOrder(_ names: some Sequence<String>) -> ToolContractOrdering {
        var seen = Set<String>()
        let ordered = names.filter { seen.insert($0).inserted }
        return ToolContractOrdering(
            floor: ordered.filter { alwaysOnCoreNames.contains($0) }.sorted(),
            appended: ordered.filter { !alwaysOnCoreNames.contains($0) }
        )
    }

    // Builder discovery and dispatch share the Full Mac file-operations gate.
    package static let fullMacBuilderToolNames: [String] = [
        "shell", "bash", "git", "apply_patch",
        "swift_build", "swift_test", "remote_node_execute",
    ]

    // Lifecycle tools share builder policy but keep a separate list so the catalog does not mislabel them as general builders.
    package static let fullMacRestartToolNames: [String] = [
        "restart_app", "install_app",
    ]

    /// Static dispatch cannot vouch for dynamic registration lifecycles; claim only its own executor names.
    package static let nativeToolDescriptors = ActionCatalog.catalog.tools.mapValues(\.toolDescriptor)

    public static let catalogRegisteredToolNames = Set(nativeToolDescriptors.keys)

    /// An unreviewed category stays nil and visible; never infer trust from an arbitrary runtime name.
    public static func catalogBucket(forRegisteredToolNamed name: String) -> ChatToolCatalogBucket? {
        nativeToolDescriptors[name]?.bucket
    }

    /// Each built-in's own declaration supplies its integration, including before executor registration.
    public static func macIntegrationAccess(forTool tool: String) -> MacIntegrationAccess? {
        nativeToolDescriptors[ToolNameAliases.canonical(tool)]?.schema.macIntegration
    }

    /// The integration switch a call needs: a built-in's own, or the one a part's answered verb carries from its app reach, whether the verb is named
    /// directly or run as its part with the verb in its input. An unreadable catalog throws; it never means no switch.
    public static func integrationGate(tool: String, input: [String: JSONValue], turn: Turn?, parts: AppActionBinding.PartLookup? = nil) throws -> MacIntegrationAccess? {
        if let native = macIntegrationAccess(forTool: tool) { return native }
        let verb = try AppActionBinding.answeredVerb(tool: tool, input: input, turn: turn, parts: parts) ?? tool
        guard let binding = try AppActionBinding.binding(verb, turn: turn, parts: parts), binding.fixedInput["verb"] == .string(verb) else { return nil }
        return binding.descriptor?.schema.macIntegration
    }

    static func nativeBucket(_ schema: LLMToolSchema) -> ChatToolCatalogBucket {
        let name = schema.name
        if Self.fullMacBuilderToolNames.contains(name)
            || Self.fullMacRestartToolNames.contains(name) {
            return .shell
        }
        if Self.standardFileToolNames.contains(name) || Self.fullMacFileToolNames.contains(name) {
            return .fileOps
        }
        if Self.fullMacSystemToolNames.contains(name) {
            return .system
        }
        if Self.fullMacAccessibilityReadToolNames.contains(name)
            || Self.fullMacAccessibilityInjectionToolNames.contains(name)
            || Self.macClipboardToolNames.contains(name) || Self.macMenuToolNames.contains(name)
            || Self.macReadToolNames.contains(name) {
            return .macControl
        }
        if schema.macIntegration != nil || name == "work_context" {
            return .macIntegration
        }
        return .core
    }

    private static let standardFileToolNames: Set<String> = [
        "read_file", "list_dir", "file_info", "write_file", "move_file", "copy_file", "trash_file", "mail_save_attachment",
    ]

}

extension SwiftToolDispatcher {
    /// The manifest projects the single app contract and Trust’s reachable actions; discovery never loads extra tools.
    public func toolManifest(turn: Turn, detail: String? = nil, surface: String = "chat") async throws -> JSONValue {
        let fullDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
        let catalog = try await catalogSnapshot(turn: turn, includeSchemas: fullDetail, surface: surface)
        let access = catalog.access
        let trustedRoots = try await trustedWorkspaceRoots()
        let modelNameSet = Self.modelVisibleCatalogToolNames(Set(catalog.names))
        let alwaysOnTools = Self.alwaysOnCoreNames.intersection(modelNameSet).sorted()
        let contributedBuckets = Dictionary((appTools?.descriptors ?? []).map { ($0.name, $0.bucket) }) { first, _ in first }
        let rows: [JSONValue] = try catalog.schemas.filter { modelNameSet.contains($0.name) }.sorted { $0.name < $1.name }.map { schema in
            var row: [String: JSONValue] = [
                "name": .string(schema.name),
                "description": .string(schema.description),
                "dispatchable_via": .string(contributedToolNames.contains(schema.name)
                    ? "nativeagent_app_tool_dispatcher" : "swift_tool_dispatcher"),
                "model_visible": .bool(true),
            ]
            // Use the registry’s buckets so rendered categories cannot drift from dispatch; unreviewed names stay visibly adverse.
            row["catalog_bucket"] = .string(
                (Self.catalogBucket(forRegisteredToolNamed: schema.name) ?? contributedBuckets[schema.name])?.rawValue
                    ?? ChatToolCatalogBucket.unclassified.rawValue
            )
            let parameters: JSONValue
            do { parameters = try JSONValue.parse(schema.parametersJSON) }
            catch {
                throw ToolFailureError("""
                    The catalog's input schema for \(schema.name) could not be read: \(error.localizedDescription). Repair its registered schema \
                    before reading the catalog again.
                    """,
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(schema.name).", recovery: .repair)
            }
            guard case .object = parameters else {
                throw ToolFailureError("""
                    The catalog's input schema for \(schema.name) must be an object. Repair its registered schema before reading the catalog \
                    again.
                    """,
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(schema.name).", recovery: .repair)
            }
            row["parameters"] = parameters
            return .object(row)
        }
        let listed = Set(catalog.names)
        let swiftBuilderTools = (Self.fullMacFileToolNames + Self.fullMacSystemToolNames + Self.fullMacBuilderToolNames + Self.fullMacRestartToolNames).sorted()
        let availableBuilderTools = swiftBuilderTools.filter { listed.contains($0) }.map { ToolNameAliases.appAction($0) ?? $0 }
        let lockedBuilderTools = swiftBuilderTools.filter { !listed.contains($0) }.map { ToolNameAliases.appAction($0) ?? $0 }
        // Only executors with app actions belong in folded discovery.
        let axReadTools = Self.fullMacAccessibilityReadToolNames.sorted()
        let availableAXReadTools = axReadTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedAXReadTools = axReadTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let activityTools = Self.activityQueryToolNames.sorted()
        let availableActivityTools = activityTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedActivityTools = activityTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let axActTools = Self.fullMacAccessibilityInjectionToolNames.sorted()
        let availableAXActTools = axActTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedAXActTools = axActTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        return .object([
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "catalog_detail": .string(fullDetail ? "full" : "compact"),
            "permission_source": .string("trust/policy.json"),
            "full_mac_active": .bool(access.fullMacActive),
            "permission_level": .string(access.permissionLevel),
            "outside_workspace_default": .string(access.outsideWorkspaceDefault),
            "file_ops_allowed": .bool(access.fileOpsAllowed),
            "system_allowed": .bool(access.systemAllowed),
            "app_control_allowed": .bool(access.accessibilityAllowed),
            "builder_mode": .string(access.fileOpsAllowed ? "available" : "policy_locked"),
            "builder_mode_detail": .string(access.fileOpsAllowed
                ? """
                    Trust Center Full Mac file access is active. app's files.*, git.*, shell.run/shell.bash, files.patch, swift.build/swift.test \
                    and app.install/app.restart actions are all available (autonomy-gated).
                    """
                : """
                    app files.write is available only inside Trust Center workspace roots; broader file, git and shell actions are locked until \
                    Trust Center Full Mac mode with file_ops_allowed is active.
                    """),
            "trusted_workspace_roots": .array(trustedRoots.map { .string($0.path) }),
            // Read-only AX perception is listed separately from app control.
            "mac_accessibility_read_available_tools": .array(availableAXReadTools.map { .string($0) }),
            "mac_accessibility_read_policy_locked_tools": .array(lockedAXReadTools.map { .string($0) }),
            // Activity and injection remain distinct from reads and app control.
            "activity_available_tools": .array(availableActivityTools.map { .string($0) }),
            "activity_policy_locked_tools": .array(lockedActivityTools.map { .string($0) }),
            "mac_accessibility_act_available_tools": .array(availableAXActTools.map { .string($0) }),
            "mac_accessibility_act_policy_locked_tools": .array(lockedAXActTools.map { .string($0) }),
            "always_on_tools": .array(alwaysOnTools.map { .string($0) }),
            "available_tools": .array(modelNameSet.sorted().map { .string($0) }),
            "builder_available_tools": .array(availableBuilderTools.map { .string($0) }),
            "builder_policy_locked_tools": .array(lockedBuilderTools.map { .string($0) }),
            "tools": .array(rows),
        ])
    }
}
