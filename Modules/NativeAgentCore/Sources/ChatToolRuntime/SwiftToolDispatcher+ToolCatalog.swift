import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import ToolRegistry
// Blueprint: | `SwiftToolDispatcher+ToolCatalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |

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


    /// Read-only Mac perception under the Accessibility category. `mac_view` also reports the separate Screen Recording grant for its image.
    static let fullMacAccessibilityReadToolNames: [String] = [
        "mac_view", "mac_attention",
        // mac_look shares the Accessibility read gate and needs no additional grant.
        "mac_look",
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

    /// Injection requires a body-bound capability and refuses read_only access. Approved replay or checked Full Mac supplies it; mac_wake belongs here because
    /// it posts HID input before reading.
    static let fullMacAccessibilityInjectionToolNames: [String] = [
        "mac_wake",
        // act drives the closed loop; go launches or activates, so both require injection admission.
        "act", "go",
    ]

    /// Four-verb membership controls visibility; earlier dispatch cases retain their composed execution owner.
    static let fourVerbToolNames: [String] = ["screen", "act", "go", "wait"]

    /// Share one internal-name set across prompts, visibility and stale-call refusal so conversational exclusions cannot drift.
    package static let internalMacToolNames: Set<String> = Set(fullMacAccessibilityReadToolNames
            + fullMacAccessibilityInjectionToolNames)
            .subtracting(fourVerbToolNames)

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

    package static func normalModelToolNames(activeTools: Set<String>) -> Set<String> {
        alwaysOnCoreNames
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
            return SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
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
    package static let nativeToolDescriptors: [String: ToolDescriptor] = Dictionary(uniqueKeysWithValues:
        BuiltInToolSchemaFactory(requestedNames: nil).schemas(
            includeFullMacFileTools: true, includeFullMacSystemTools: true,
            includeFullMacAccessibilityReadTools: true, includeFullMacAccessibilityInjectionTools: true,
            includeActivityQueryTool: true
        ).map { ($0.name, ToolDescriptor(schema: $0, bucket: nativeBucket($0))) })

    public static let catalogRegisteredToolNames = Set(nativeToolDescriptors.keys)

    /// An unreviewed category stays nil and visible; never infer trust from an arbitrary runtime name.
    public static func catalogBucket(forRegisteredToolNamed name: String) -> ChatToolCatalogBucket? {
        nativeToolDescriptors[name]?.bucket
    }

    /// Each built-in's own declaration supplies its integration, including before executor registration.
    public static func macIntegrationAccess(forTool tool: String) -> MacIntegrationAccess? {
        nativeToolDescriptors[ToolNameAliases.canonical(tool)]?.schema.macIntegration
    }

    private static func nativeBucket(_ schema: LLMToolSchema) -> ChatToolCatalogBucket {
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
        return .core // Only the schema factory calls this classifier.
    }

    private static let standardFileToolNames: Set<String> = [
        "read_file", "list_dir", "file_info", "write_file", "move_file", "copy_file", "trash_file", "mail_save_attachment",
    ]

}
