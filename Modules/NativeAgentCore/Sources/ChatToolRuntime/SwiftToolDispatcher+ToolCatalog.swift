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

    /// Read file/git executors. `ParallelToolDispatch` owns concurrency admission;
    /// `git_diff` runs alone because working-tree diff can rewrite the index.
    package static let fullMacReadOnlyFileToolNames: [String] = [
        "file_excerpt", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
    ]

    /// The WRITE half of the Full-Mac file surface — mutates the filesystem.
    static let fullMacWriteFileToolNames: [String] = [
        "write_file", "move_file", "copy_file", "trash_file", "mac_screenshot_save", "mail_save_attachment",
    ]

    /// Swift-implemented builder/file tools exposed only when Trust Center's
    /// Full Mac mode is active and the matching MacControl category is enabled.
    /// Composed from the two halves so gating, catalog membership and dispatch
    /// routing keep covering exactly the same set they always did.
    package static let fullMacFileToolNames: [String] =
        fullMacReadOnlyFileToolNames + fullMacWriteFileToolNames

    package static let fullMacSystemToolNames: [String] = [
        "system_info", "mac_volume", "mac_media", "remote_node_list",
    ]


    /// Read-only Mac perception under the Accessibility category. `mac_view`
    /// also reports the separate Screen Recording grant for its image.
    static let fullMacAccessibilityReadToolNames: [String] = [
        "mac_view", "mac_attention",
        // mac_look shares the Accessibility read gate and needs no additional grant.
        "mac_look",
        // screen and wait are pure perception; they hold and expire nothing.
        "screen", "wait",
    ]

    /// The clipboard organ has its own read and write gates.
    ///
    ///   • It is not an accessibility READ — it walks no AX tree and needs no
    ///     Accessibility TCC grant to answer.
    ///   • It is not INJECTION — it posts no CGEvent and performs no AX action,
    ///     so it must not carry the injection list's approval capability.
    ///
    /// Clipboard is separately reachable through the four-verb surface.
    ///
    /// GATE: both reads and writes require `accessibilityAllowed`, an ACTIVE Full Mac
    /// window and the accessibility category, enforced again inside MacControl.
    static let macClipboardReadToolNames: [String] = ["clipboard_read"]
    static let macClipboardWriteToolNames: [String] = ["clipboard_write"]
    static let macClipboardToolNames: [String] =
        macClipboardReadToolNames + macClipboardWriteToolNames

    /// `menu` is a bounded read-only walk
    /// of `AXMenuBar` (no CGEvent, no AX action, it does not even open a menu),
    /// while `menu_press` runs the app's own handler and clears the full
    /// injection contract inside MacControl.
    ///
    /// Separate read/press lists preserve their admission and capability contracts.
    static let macMenuReadToolNames: [String] = ["menu"]
    static let macMenuPressToolNames: [String] = ["menu_press"]
    static let macMenuToolNames: [String] = macMenuReadToolNames + macMenuPressToolNames

    /// fable51 item 33 — THE READ ORGAN. Its own list for the same reason the
    /// two organs above have theirs: it is neither neighbour.
    ///
    ///   • It is not one of the accessibility READS. That list's contract is
    ///     the bounded glance under `look`'s budgets, and this one deliberately
    ///     is not bounded that way — it returns a whole document and lets the
    ///     turn's existing spill pager carry it.
    ///   • It is not INJECTION. It moves a viewport and puts it back; it
    ///     presses, types and activates nothing, so it must not carry the
    ///     injection list's approval capability.
    ///
    /// The separate list also keeps it OUT of `legacyMacModelToolNames`: `read`
    /// is a NEW organ for the four-verb surface to reach for, not a legacy
    /// `mac_*` organ being retired.
    ///
    /// GATE: `accessibilityAllowed`, plus the file gate (`fileOpsAllowed`
    /// and workspace file policy) for ANY filesystem route — a `path` the caller
    /// names or one inferred from `AXDocument` (see `impl_mac_read_tool`).
    static let macReadToolNames: [String] = ["read"]

    /// Local activity reads require capture and separate agent admission, checked at discovery and dispatch.
    static let activityQueryToolNames: [String] = ["activity_query"]

    /// Injection tools synthesize input and drive other apps' UI.
    /// They require a body-bound injection capability,
    /// and are blocked under `fileAccess=read_only`. Standard modes obtain the
    /// capability through approved replay; admitted Full Mac YOLO obtains it
    /// directly for the checked call without a per-call prompt.
    /// `mac_wake` is in this list rather than the read list even though
    /// most of what it RETURNS is a `mac_view` result: it posts a HID mouse
    /// move first, and the tier is decided by what a tool does, not by what it
    /// hands back. Read tier for it would have been a bypass with a view-shaped
    /// result stapled to it.
    static let fullMacAccessibilityInjectionToolNames: [String] = [
        "mac_wake",
        // Four verbs: `act` drives the closed loop (raise,
        // gates, actuator, observer) addressed by NAME instead of handle;
        // `go` activates/launches/opens — hands, so injection tier.
        "act", "go",
    ]

    /// The four-verb surface routes to its OWN impl (see the dispatch switch:
    /// its case precedes the read/injection list cases, so membership above
    /// buys loading/visibility while routing lands here).
    static let fourVerbToolNames: [String] = ["screen", "act", "go", "wait"]

    /// The implementation organs retained for direct diagnostics and the Tools
    /// UI, but removed from the conversational model surface. This one set is
    /// the cutover boundary; prompt filters, same-turn loading, and stale-call
    /// rejection all consult it instead of maintaining parallel exclusion
    /// lists.
    package static let legacyMacModelToolNames: Set<String> = Set(fullMacAccessibilityReadToolNames
            + fullMacAccessibilityInjectionToolNames)
            .subtracting(fourVerbToolNames)

    /// Internal Mac, folded, merged and retired names excluded from model catalogs.
    package static let modelHiddenToolNames: Set<String> = legacyMacModelToolNames.union(ToolNameAliases.foldedTools.keys).union(ToolNameAliases.mergedTools)
            .union(ToolNameAliases.retiredAppTools)

    package static func isModelHidden(_ name: String) -> Bool {
        modelHiddenToolNames.contains(name)
    }

    /// Keep the retained UI and studio tools out of the conversational catalog.
    public static func modelVisibleCatalogToolNames(
        _ availableToolNames: Set<String>
    ) -> Set<String> {
        availableToolNames.filter { !isModelHidden($0) }
    }

    /// Add the fixed app floor and exclude internal names from active tools.
    package static func normalModelToolNames(activeTools: Set<String>) -> Set<String> {
        alwaysOnCoreNames.union(activeTools.filter { !isModelHidden($0) })
    }

    /// The advertised tool contract for one turn, split into the part that can
    /// never move and the part that only ever grows.
    ///
    /// FLOOR is `alwaysOnCoreNames ∩ available`, sorted by name.
    /// APPENDED preserves the incoming order of every other name.
    package struct ToolContractOrdering: Sendable, Equatable {
        package let floor: [String]
        package let appended: [String]

        init(floor: [String], appended: [String]) {
            self.floor = floor
            self.appended = appended
        }

        package var advertised: [String] { floor + appended }

        /// SHA-256 over the ordered advertised contract. Two consecutive turns
        /// with the same fingerprint carry the same catalog rows in the same
        /// order, so a cache miss between them cannot be blamed on the tool
        /// contract. Membership AND order both feed the digest — reordering
        /// alone breaks a prefix just as thoroughly as adding a row.
        package var fingerprintSHA256: String {
            let text = floor.joined(separator: "\n")
                + "\n\u{1F}\n"
                + appended.joined(separator: "\n")
            return SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    /// Canonical advertised order for `names`: the floor sorted by name, then
    /// everything else in incoming order.
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

    // App lifecycle tools. Not general builder tools (no arbitrary Process
    // args/cwd surface), but they share the builder tools' policy shape:
    // schema lives in the includeFullMacFileTools block, dispatch gates on
    // file_ops_allowed, and listAvailableTools() surfaces them under the same
    // gate. Kept in a separate list so the tool catalog doesn't mislabel them
    // "implemented_swift_builder_tools".
    package static let fullMacRestartToolNames: [String] = [
        "restart_app", "install_app",
    ]

    /// Names implemented by this dispatcher, including capability-gated
    /// surfaces. Dynamic registry tools are catalog rows too, but are
    /// intentionally not claimed here because this static dispatcher cannot
    /// vouch for their registration lifecycle.
    package static let nativeToolDescriptors: [String: ToolDescriptor] = Dictionary(uniqueKeysWithValues:
        BuiltInToolSchemaFactory(requestedNames: nil).schemas(
            includeFullMacFileTools: true, includeFullMacSystemTools: true,
            includeFullMacAccessibilityReadTools: true, includeFullMacAccessibilityInjectionTools: true,
            includeActivityQueryTool: true
        ).map { ($0.name, ToolDescriptor(schema: $0, bucket: nativeBucket($0.name))) })

    public static let catalogRegisteredToolNames = Set(nativeToolDescriptors.keys)

    /// Returns nil deliberately for a name without an explicit reviewed
    /// category. Callers must present that condition visibly instead of
    /// treating an arbitrary runtime name as a reviewed category.
    public static func catalogBucket(forRegisteredToolNamed name: String) -> ChatToolCatalogBucket? {
        nativeToolDescriptors[name]?.bucket
    }

    private static func nativeBucket(_ name: String) -> ChatToolCatalogBucket {
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
        if MacIntegrationGates.byTool[name] != nil || name == "work_context" {
            return .macIntegration
        }
        return .core // Only the schema factory calls this classifier.
    }

    private static let standardFileToolNames: Set<String> = [
        "read_file", "list_dir", "file_info", "write_file", "move_file", "copy_file", "trash_file", "mail_save_attachment",
    ]

}
