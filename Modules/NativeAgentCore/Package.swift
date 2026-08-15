// swift-tools-version:6.0
import Foundation
import PackageDescription

let subsystems: [String] = [
    "PersistenceCore",
    "ApprovalInbox",
    "MCPDispatcher",
    "ToolRegistry",
    "PersonaEngine",
    "DoctorChecks",
    "ChatOrchestration",
    "CognitiveSubstrate",
    "MemoryV2",
    "DreamREMCycle",
    "SelfImprovement",
    "TrustCenter",
    "TelegramBot",
    "ProviderRouting",
    "BackgroundLoops",
    "ToolExecution",
    "Research",
    "TriggerScheduler",
    "CommandPalette",
    "SystemOps",
    "Dispatcher",
    "MacControl",
    "ScreenVision",
    "Onboarding",
    "MacAssistantStatus",
    "WorkshopExecution",
    "WorkflowOrchestration",
    "KnowledgeGraph",
    "Skills",
    "NotificationInbox",
    "Connectors",
    "SwarmRuns",
    "Browser",
    "Context",
    "MultimodalTTS",
    "CapabilityFoundry",
    "XConnector",
    "GitHubConnector",
    "SlackConnector",
    "MacIntegration",
    // Ambient activity watcher (W7/W8, 2026-08-14). Was fenced behind
    // NATIVEAGENT_DEV_ACTIVITY_PROBE=1 for the dev-only v0; the fence is LIFTED
    // now that the feature ships in-app. The compile-time guarantee it provided
    // ("this code cannot exist in a build") is replaced by a RUNTIME one that
    // is structurally enforced rather than conventional:
    //   * `ActivityWatcher.start()` installs no AX observer, no NSWorkspace
    //     observer and no lock observer, and opens no span, unless the Trust
    //     Center policy's `captureEnabled` is true;
    //   * the policy defaults to false and an unreadable/missing policy file
    //     decodes to false, so a fresh install captures nothing;
    //   * a policy flipped to false at runtime tears the observers down on the
    //     next capture-thread hop rather than at the next restart.
    // ActivityWatchArchitectureTests pins all of that, plus the egress
    // enumeration (no context assembly, no memory promotion, no sync/backup).
    "ActivityWatch",
]

let products: [Product] =
    [.library(name: "NativeAgentCore", targets: ["NativeAgentCore"])]
    + subsystems.map { .library(name: $0, targets: [$0]) }
    + [
        .executable(name: "chat-drive", targets: ["ChatDrive"]),
        .executable(name: "task-ledger", targets: ["TaskLedgerCLI"]),
        .executable(name: "ContextSelectionABHarness", targets: ["ContextSelectionABHarness"]),
        .executable(name: "activity-probe", targets: ["ActivityProbeCLI"]),
    ]

// Per-subsystem extra dependencies on other subsystem libraries. Most
// subsystems depend only on the NativeAgentCore runtime support; subsystems
// that touch disk depend on PersistenceCore for atomic byte-compatible IO.
let extraDeps: [String: [String]] = [
    "ApprovalInbox": ["PersistenceCore"],
    "MCPDispatcher": ["PersistenceCore", "Research", "KnowledgeGraph", "CapabilityFoundry"],
    "ToolRegistry": ["PersistenceCore"],
    "PersonaEngine": ["PersistenceCore"],
    // M5 (2026-07-09): KnowledgeGraph so MemoryStoreCheck can validate the real
    // KG store (memory.sqlite kg_entities/kg_relationships) through the existing
    // reader instead of a JSON file nothing reads. No cycle — KnowledgeGraph
    // depends only on PersistenceCore.
    // 2026-07-12: MemoryV2 so CoreMLEmbedderCheck can probe the real
    // bundled-model load path (compile cache + vocab) and repair by wiping the
    // poisoned compile cache. No cycle — MemoryV2 never imports DoctorChecks.
    "DoctorChecks": ["PersistenceCore", "PersonaEngine", "KnowledgeGraph", "MemoryV2"],
    // R9: ToolExecution so chat dispatch can route registry custom tools
    // through the sandboxed run engine (no cycle — ToolExecution depends only
    // on PersistenceCore/TrustCenter/ToolRegistry).
    // W7 (2026-08-14): ActivityWatch so the `activity_query` tool has an
    // implementation to route to. ONE file may import it —
    // SwiftToolDispatcher+Sandbox.swift, the tool impl — and
    // ActivityWatchArchitectureTests pins that: the dependency exists so an
    // EXPLICIT tool call can read the rollups, never so context assembly,
    // recall, or memory promotion can. The arrow only points this way;
    // ActivityWatch imports nothing from ChatOrchestration, which is what
    // keeps the module unable to reach a turn on its own.
    "ChatOrchestration": ["PersistenceCore", "PersonaEngine", "MemoryV2", "ProviderRouting", "TrustCenter", "DreamREMCycle", "ApprovalInbox", "MCPDispatcher", "KnowledgeGraph", "Dispatcher", "MacControl", "Context", "SwarmRuns", "XConnector", "GitHubConnector", "SlackConnector", "MacIntegration", "WorkshopExecution", "SystemOps", "CognitiveSubstrate", "ToolExecution", "Skills", "ActivityWatch"],
    "CognitiveSubstrate": ["PersistenceCore"],
    "XConnector": ["PersistenceCore"],
    "GitHubConnector": ["PersistenceCore"],
    "SlackConnector": ["PersistenceCore"],
    // U3w2 item 7: ApprovalInbox so the consolidation gate can stage its
    // swap-on-approve card from inside the module (no cycle — ApprovalInbox
    // depends only on PersistenceCore).
    "MemoryV2": ["PersistenceCore", "KnowledgeGraph", "ApprovalInbox"],
    "DreamREMCycle": ["PersistenceCore", "ProviderRouting", "KnowledgeGraph"],
    "SelfImprovement": ["PersistenceCore"],
    "TrustCenter": ["PersistenceCore", "PersonaEngine", "ToolRegistry", "MCPDispatcher", "MacControl"],
    "TelegramBot": ["PersistenceCore", "BackgroundLoops", "ProviderRouting"],
    "ProviderRouting": ["PersistenceCore"],
    "BackgroundLoops": ["PersistenceCore", "DoctorChecks", "DreamREMCycle", "ProviderRouting", "TriggerScheduler"],
    "ToolExecution": ["PersistenceCore", "TrustCenter", "ToolRegistry"],
    "Research": ["PersistenceCore"],
    "TriggerScheduler": ["PersistenceCore", "WorkshopExecution"],
    "SystemOps": ["PersistenceCore", "TrustCenter"],
    "Dispatcher": ["PersistenceCore", "MacControl"],
    "MacControl": ["PersistenceCore"],
    "Onboarding": ["PersistenceCore", "PersonaEngine"],
    "MacAssistantStatus": ["PersistenceCore", "TrustCenter"],
    // MemoryV2 (2026-08-02, NORTHSTAR clause 1): a finished Workshop execution
    // writes one prose memory of what it did, on the `missions` disclosure
    // surface the policy already carried but nothing ever filled. No cycle —
    // MemoryV2 depends on PersistenceCore/KnowledgeGraph/ApprovalInbox and
    // never imports WorkshopExecution. See WorkshopExecution+ExecutionMemory.swift.
    "WorkshopExecution": ["PersistenceCore", "ProviderRouting", "ApprovalInbox", "MemoryV2"],
    "WorkflowOrchestration": [
        "PersistenceCore",
        "ApprovalInbox",
        "MCPDispatcher",
        "MemoryV2",
        "Research",
        "SystemOps",
        "ToolExecution",
    ],
    "KnowledgeGraph": ["PersistenceCore"],
    "Skills": ["PersistenceCore"],
    "NotificationInbox": ["PersistenceCore"],
    "Connectors": ["PersistenceCore"],
    "SwarmRuns": ["PersistenceCore"],
    "Browser": ["PersistenceCore"],
    "Context": ["PersistenceCore", "TrustCenter"],
    // Subsystem #28 wave 35 W18 — SwiftNative POST /v1/multimodal/tts port.
    // Depends on ProviderRouting for LLMCredentialResolver (the OpenAI platform
    // key resolver that landed with the chat cutover — the dep that lifts the
    // wave-34 "Swift secret layer" blocker) and PersistenceCore for
    // defaultDataRoot() / readJSON to enforce the SAME multimodalPolicy.tts_openai
    // trust gate the daemon's _multimodal_policy_check applies (default OFF).
    // See CUTOVER_PLAN.md §6.117.
    "MultimodalTTS": ["ProviderRouting", "PersistenceCore"],
    // Subsystem #29 wave 41 W10 — CapabilityFoundry seam. Depends only on
    // PersistenceCore for JSONValue (the result serializer). The SwiftNative
    // impl is a static structural contract — it does NOT touch the other
    // subsystem modules because their per-lane counts are NOT aggregated yet
    // (PORTED-DORMANT, default OFF). See CUTOVER_PLAN.md §6.241.
    "CapabilityFoundry": ["PersistenceCore"],
    // MacIntegration — per-integration READ/WRITE permission gating for the
    // Calendar / Reminders / Contacts / Mail / Messages / Notes / Music /
    // Notifications / Spotlight / Scheduler surface. PersistenceCore for
    // flocked atomic JSON IO of mac_integration_permissions.json.
    "MacIntegration": ["PersistenceCore"],
    // Ambient activity watcher — PersistenceCore for defaultDataRoot() and
    // atomic policy IO; MacControl for MacScreenViewTextRedaction, the SHARED
    // secret redactor every captured window title passes through (W5). We reuse
    // it rather than writing a second redactor: two copies drift, and the copy
    // that drifts is the one nobody re-reviews. No cycle — MacControl depends
    // only on PersistenceCore, and nothing in the tree depends on ActivityWatch
    // except its own CLI.
    "ActivityWatch": ["PersistenceCore", "MacControl"],
]

// Per-subsystem external (Swift Package) product dependencies.
let externalDeps: [String: [Target.Dependency]] = [
    "CognitiveSubstrate": [.product(name: "GRDB", package: "GRDB.swift")],
    "Context": [.product(name: "GRDB", package: "GRDB.swift")],
    "MCPDispatcher": [.product(name: "GRDB", package: "GRDB.swift")],
    "MemoryV2": [.product(name: "GRDB", package: "GRDB.swift")],
    // F6 (eval E06 fix-2): KnowledgeGraph reader now queries the same
    // memory.sqlite the MemoryV2 actor writes (kg_entities + kg_relationships
    // tables added by the v2_knowledge_graph migration). One-time JSON import
    // from <root>/memory/knowledge_graph.json is gated by a sentinel.
    "KnowledgeGraph": [.product(name: "GRDB", package: "GRDB.swift")],
    "ActivityWatch": [.product(name: "GRDB", package: "GRDB.swift")],
]

let subsystemTargets: [Target] = subsystems.flatMap { name -> [Target] in
    let deps: [Target.Dependency] =
        [.target(name: "NativeAgentCore")] +
        (extraDeps[name] ?? []).map { .target(name: $0) } +
        (externalDeps[name] ?? [])
    let testDeps: [Target.Dependency] =
        [.target(name: name), .target(name: "NativeAgentCore"), .target(name: "NativeAgentTestSupport")] +
        (extraDeps[name] ?? []).map { .target(name: $0) } +
        (externalDeps[name] ?? []) +
        (["ChatOrchestration", "PersistenceCore"].contains(name)
            ? [.target(name: "NativeAgentEvaluation")]
            : [])
    // Per-subsystem resources (e.g. MemoryV2 ships the WordPiece vocab).
    let targetResources: [Resource]? = (name == "MemoryV2") ? [
        .process("Resources/minilm_vocab.txt"),
        .copy("Resources/minilm.mlpackage"),
    ] : nil
    // WorkshopExecution persists content-addressed identities (procedure
    // shape/schema digests). Transitively visible extension members — e.g.
    // GRDB's SQL interpolation via MemoryV2 — must never participate in type
    // inference there: an inference flip silently hashes an unstable debug
    // description instead of the intended string (2026-08-05 preflight bug).
    let targetSwiftSettings: [SwiftSetting]? = (name == "WorkshopExecution")
        ? [.enableUpcomingFeature("MemberImportVisibility")]
        : nil
    return [
        .target(
            name: name,
            dependencies: deps,
            path: "Sources/\(name)",
            resources: targetResources,
            swiftSettings: targetSwiftSettings
        ),
        .testTarget(
            name: "\(name)Tests",
            dependencies: testDeps,
            path: "Tests/\(name)Tests"
        )
    ]
}

let package = Package(
    name: "NativeAgentCore",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "NativeAgentCore",
            dependencies: [],
            path: "Sources/NativeAgentCore"
        ),
        .testTarget(
            name: "NativeAgentCoreTests",
            dependencies: ["NativeAgentCore", "NativeAgentTestSupport"],
            path: "Tests/NativeAgentCoreTests"
        ),
        .target(
            name: "NativeAgentCTestSupport",
            path: "Tests/NativeAgentCTestSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NativeAgentTestSupport",
            dependencies: ["NativeAgentCTestSupport"],
            path: "Tests/NativeAgentTestSupport"
        ),
        .target(
            name: "NativeAgentEvaluation",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "ChatOrchestration"),
                .target(name: "CognitiveSubstrate"),
                .target(name: "Context"),
                .target(name: "PersistenceCore"),
                .target(name: "ProviderRouting"),
            ],
            path: "Sources/NativeAgentEvaluation"
        ),
        .executableTarget(
            name: "ChatDrive",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "NativeAgentEvaluation"),
                .target(name: "ApprovalInbox"),
                .target(name: "ChatOrchestration"),
                .target(name: "Context"),
                .target(name: "KnowledgeGraph"),
                .target(name: "MemoryV2"),
                .target(name: "PersistenceCore"),
                .target(name: "ProviderRouting"),
                .target(name: "DoctorChecks"),
                .target(name: "TrustCenter"),
                .target(name: "WorkshopExecution"),
            ],
            path: "Sources/ChatDrive"
        ),
        .executableTarget(
            name: "TaskLedgerCLI",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
            ],
            path: "Sources/TaskLedgerCLI"
        ),
        // Offline A/B for the selection score rebalance — reads a sqlite
        // .backup copy of a context store through the production
        // ContextSQLiteStore + selection-index path. See
        // docs/build_plans/selection-score-rebalance.md.
        .executableTarget(
            name: "ContextSelectionABHarness",
            dependencies: [
                .target(name: "Context"),
            ],
            path: "Sources/ContextSelectionABHarness"
        ),
        .executableTarget(
            name: "DeskSweepCLI",
            dependencies: [
                .target(name: "PersistenceCore"),
            ],
            path: "Sources/DeskSweepCLI"
        ),
        // Activity watcher probe/simulator CLI. Unconditional since the W7/W8
        // in-app wiring: it is the headless harness the ground-truth
        // simulation runs through, and it drives the SAME engine + store the
        // live capture path does.
        .executableTarget(
            name: "ActivityProbeCLI",
            dependencies: [
                .target(name: "ActivityWatch"),
                .target(name: "PersistenceCore"),
            ],
            path: "Sources/ActivityProbeCLI"
        ),
    ] + subsystemTargets
)
