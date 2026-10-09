// swift-tools-version: 6.1

import PackageDescription

// RELEASE-2026-05-06: added Sparkle 2.x for auto-update (Task 4.3)
let package = Package(
    name: "NativeAgent",
    platforms: [
        // USER 2026-08-16: Liquid Glass floor — "no one is using mac os 14".
        // Public DMG minimum rises with this; deliberate.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "nativeagent-link", targets: ["NativeAgentLink"]),
        .executable(name: "NativeAgentApp", targets: ["NativeAgentApp"]),
        .executable(name: "NativeAgentChromeRelay", targets: ["NativeAgentChromeRelay"]),
        .executable(name: "NativeAgentSenseHost", targets: ["NativeAgentSenseHost"])
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            // 2.9.2 is the security floor: it hardens delta-update symlink
            // handling and validates the installer connection before data is
            // accepted. Package.resolved pins the current 2.9.4 patch.
            from: "2.9.2"
        ),
        .package(path: "Modules/NativeAgentShared"),
        .package(path: "Modules/NativeAgentCore")
    ],
    targets: [
        .executableTarget(
            name: "NativeAgentSenseHost",
            dependencies: [.product(name: "Senses", package: "NativeAgentCore"),
                           .product(name: "NativeAgentCore", package: "NativeAgentCore")],
            path: "Sources/NativeAgentSenseHost",
            resources: [.copy("../../Resources/Senses")]
        ),
        .executableTarget(name: "NativeAgentLink", dependencies: [.product(name: "GrokLink", package: "NativeAgentCore"), .product(name: "PersistenceCore", package: "NativeAgentCore")], path: "Sources/NativeAgentLink"),
        .executableTarget(
            name: "NativeAgentChromeRelay",
            dependencies: [
                .product(name: "NativeAgentChromeRelayCore", package: "NativeAgentCore"),
                .product(name: "PersistenceCore", package: "NativeAgentCore"),
                .product(name: "FeedPolicy", package: "NativeAgentCore"),
                .product(name: "Privacy", package: "NativeAgentCore"),
                .product(name: "GrokLink", package: "NativeAgentCore"),
            ],
            path: "Sources/NativeAgentChromeRelay"
        ),
        .executableTarget(
            name: "NativeAgentApp",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "NativeAgentCore", package: "NativeAgentCore"),
                .product(name: "EngineRuntime", package: "NativeAgentCore"),
                .product(name: "AppToolRuntime", package: "NativeAgentCore"),
                .product(name: "ApprovalTransactions", package: "NativeAgentCore"),
                .product(name: "ApprovalInbox", package: "NativeAgentCore"),
                .product(name: "MCPDispatcher", package: "NativeAgentCore"),
                .product(name: "MemoryV2", package: "NativeAgentCore"),
                .product(name: "Context", package: "NativeAgentCore"),
                .product(name: "ToolRegistry", package: "NativeAgentCore"),
                .product(name: "ToolExecution", package: "NativeAgentCore"),
                .product(name: "PersonaEngine", package: "NativeAgentCore"),
                .product(name: "TrustCenter", package: "NativeAgentCore"),
                .product(name: "TrustPersistence", package: "NativeAgentCore"),
                .product(name: "PersistenceCore", package: "NativeAgentCore"),
                .product(name: "Desk", package: "NativeAgentCore"),
                .product(name: "Studio", package: "NativeAgentCore"),
                .product(name: "Senses", package: "NativeAgentCore"),
                .product(name: "TurnTrace", package: "NativeAgentCore"),
                .product(name: "Transcripts", package: "NativeAgentCore"),
                .product(name: "Procedures", package: "NativeAgentCore"),
                .product(name: "BackgroundLoops", package: "NativeAgentCore"),
                .product(name: "BackgroundWork", package: "NativeAgentCore"),
                .product(name: "DoctorChecks", package: "NativeAgentCore"),
                // Wave-3 BackgroundLoops wiring (BackgroundLoopsAssembly.swift)
                // needs ProviderRouting for SwiftNativeLLMClient + adapters, and
                // DreamREMCycle for SwiftNativeREMConsolidator + DreamDiaryReader
                // + REMTombstoneStore + GrowthDocManager. BackgroundLoops itself
                // doesn't import these — the assembly happens app-side so the
                // module stays dep-light.
                .product(name: "ProviderRouting", package: "NativeAgentCore"),
                .product(name: "DreamREMCycle", package: "NativeAgentCore"),
                // TriggerScheduler owns inbox and Workshop trigger lifecycle.
                .product(name: "TriggerScheduler", package: "NativeAgentCore"),
                .product(name: "SchedulerExecution", package: "NativeAgentCore"),
                .product(name: "StandingBots", package: "NativeAgentCore"),
                .product(name: "SwarmRuns", package: "NativeAgentCore"),
                // WAVE 32 W07 (2026-06-01): WorkshopExecution owns the read-side of
                // GET /v1/missions, /v1/missions/<id>, /v1/missions/<id>/timeline
                // (SwiftNativeWorkshopRunner queue + legacy-store reads).
                .product(name: "WorkshopExecution", package: "NativeAgentCore"),
                // NotificationInbox owns GET /v1/inbox[/<id>]
                // PLUS the POST /v1/inbox/<id>/{read,archive,dismiss} status
                // writes (wave 32 W16: flock + proactive-outcome ledger closed).
                // NativeClient.inboxAction uses it for those three actions.
                .product(name: "NotificationInbox", package: "NativeAgentCore"),
                // Research owns SearXNG autodetect and search in process.
                .product(name: "Research", package: "NativeAgentCore"),
                // SystemOps owns router planning, rebuild, stash recovery, and
                // crash-report surfaces.
                .product(name: "SystemOps", package: "NativeAgentCore"),
                // Dispatcher owns the Swift-native POST /v1/dispatch path.
                .product(name: "Dispatcher", package: "NativeAgentCore"),
                // MacControl zero-daemon Swift surface. Native actions:
                // notify, applescript, file/read/write/list/move/trash,
                // focus_app, quit_app, spotlight, shell. High-risk or
                // unported actions fail closed in Swift: jxa, shortcut,
                // shortcut/run, keystroke, click, system, self_test.
                .product(name: "MacControl", package: "NativeAgentCore"),
                // ScreenVision v1 (2026-06-06): Swift-native ScreenCaptureKit
                // wrapper that powers the chat composer's "Show agent my
                // screen" button. Fail-closed on permission denial; no
                // daemon HTTP fallback. See
                // Modules/NativeAgentCore/Sources/ScreenVision/ScreenVision.swift.
                .product(name: "ScreenVision", package: "NativeAgentCore"),
                // Onboarding owns the Swift-native onboarding start path.
                .product(name: "Onboarding", package: "NativeAgentCore"),
                // MacAssistantStatus owns the Swift-native status projection.
                .product(name: "MacAssistantStatus", package: "NativeAgentCore"),
                // Subsystem #17 (2026-05-31): SelfImprovement — NativeClient
                // routes self-improvement endpoints through this module.
                .product(name: "SelfImprovement", package: "NativeAgentCore"),
                // ChatOrchestration owns chat and streaming turns in process.
                .product(name: "ChatOrchestration", package: "NativeAgentCore"),
                .product(name: "CognitiveSubstrate", package: "NativeAgentCore"),
                // XConnector — 2026-06-07: moved out of Sources/NativeAgentApp/
                // so the Core ChatOrchestration dispatch layer can call it
                // and surface x_* tools to Agent in chat. App still imports
                // it (NativeClient.runConnectorAction routes here).
                .product(name: "XConnector", package: "NativeAgentCore"),
                .product(name: "GitHubConnector", package: "NativeAgentCore"),
                .product(name: "SlackConnector", package: "NativeAgentCore"),
                // WorkflowOrchestration — Swift-native workflow list, run,
                // resume, cancel, rollback, approval pause/resume, and promoted
                // tool/MCP step execution.
                .product(name: "WorkflowOrchestration", package: "NativeAgentCore"),
                // KnowledgeGraph owns local graph, search, and entity reads.
                .product(name: "KnowledgeGraph", package: "NativeAgentCore"),
                // Connectors — Swift-native connector registry, workspace
                // search, OAuth/auth helpers, and connector-action status/dry-run
                // receipts. Provider side-effect actions remain explicitly gated.
                .product(name: "Connectors", package: "NativeAgentCore"),
                // TelegramBot product — Swift-native polling, status, receipts,
                // blocked-message, and error telemetry.
                .product(name: "TelegramBot", package: "NativeAgentCore"),
                // SlackBot — Swift-native Slack Socket Mode loop, turn
                // ingress, session map, delivery journal, and runtime state.
                .product(name: "SlackBot", package: "NativeAgentCore"),
                // ChromeControl — the Chrome control socket, relay handshake,
                // leases and native-host registration.
                .product(name: "ChromeControl", package: "NativeAgentCore"),
                // Agents — A2A wire and tasks, peer identity, desktop and Grok
                // routes, completion delivery and the reply/notice continuation.
                .product(name: "Agents", package: "NativeAgentCore"),
                // ContextFlow — the live ContextFlow owner and the projections
                // it compiles (memory, resident work, Knowledge Graph, Studio).
                .product(name: "ContextFlow", package: "NativeAgentCore"),
                // Cognition — the resident mind's runtime the engine root owns.
                .product(name: "Cognition", package: "NativeAgentCore"),
                // DeviceSync — the Mac side of the phone: CloudKit/KVS bridge,
                // snapshot projection, signed inbox actions, pairing and APNs.
                .product(name: "DeviceSync", package: "NativeAgentCore"),
                .product(name: "AttentionRouting", package: "NativeAgentCore"),
                // Skills — Swift-native skill registry reads and lifecycle
                // mutations. No daemon write route is used on this branch.
                .product(name: "Skills", package: "NativeAgentCore"),
                // Browser — Swift-native status, dry-run/cancel persistence, and
                // app-owned WKWebView visible navigation through approval replay.
                .product(name: "Browser", package: "NativeAgentCore"),
                // MultimodalTTS owns POST /v1/multimodal/tts.
                // VoiceOutputController.speakOpenAI calls SwiftOpenAITTSClient
                // (direct URLSession POST to
                // OpenAI's /v1/audio/speech, key via LLMCredentialResolver).
                .product(name: "MultimodalTTS", package: "NativeAgentCore"),
                // MacIntegration — per-integration READ/WRITE permission
                // gating for Calendar / Reminders / Contacts / Mail / Messages
                // / Notes / Music / Notifications / Spotlight / Scheduler.
                // The chat tool dispatcher calls
                // MacIntegrationPermissionStore.shared.allows(id, mode:) before
                // executing any integration-bound side effect.
                .product(name: "MacIntegration", package: "NativeAgentCore"),
                // ActivityWatch (W7/W8, 2026-08-14) — the ambient activity
                // watcher. The app links it for exactly two jobs, both of them
                // user-facing: `ActivityWatchController` owns the capture
                // lifecycle behind the Trust Center toggle, and the Trust
                // Center panel + menu-bar indicator render its state.
                //
                // The old architecture guard asserted this dependency did NOT
                // exist (v0 was dev-only and fenced at compile time). That
                // fence is replaced by a RUNTIME one — capture cannot run
                // unless the toggle is explicitly on — and the guard now
                // asserts the runtime property plus the egress enumeration
                // instead. See ActivityWatchArchitectureTests.
                .product(name: "ActivityWatch", package: "NativeAgentCore")
            ],
            path: "Sources/NativeAgentApp",
            // R10-N22: bundle docs/data-bounds.md so AboutView (or any in-app viewer)
            // can open it directly from the app bundle's Resources directory.
            resources: [
                .copy("../../docs/data-bounds.md"),
                // Public app-only installs do not have a source checkout. The
                // async Codex / OMP bridges still need their durable
                // wakeup workers, so ship the exact helpers as app resources
                // instead of resolving only <repo>/script at runtime.
                .copy("../../script/codex_thread_wakeup.js"),
                .copy("../../script/chatgpt_dot_ipc.js"),
                .copy("../../script/codex_wake_daemon_probe.js"),
                .copy("../../script/codex_wake_execution_policy.js"),
                .copy("../../script/codex_wake_prompt.js"),
                .copy("../../script/codex_wake_request_params.js"),
                .copy("../../script/codex_wake_rpc.js"),
                .copy("../../script/codex_wake_thread_state.js"),
                .copy("../../script/codex_wake_inbox_projection.js"),
                .copy("../../script/codex_wake_lane_identity.js"),
                .copy("../../script/codex_wake_heartbeat.js"),
                .copy("../../script/wake_worker_common.js"),
                .copy("../../script/wake_queue_admission.js"),
                .copy("../../script/wake_turn_observation.js"),
                .copy("../../script/wake_reply_delivery.js"),
                .copy("../../script/wake_recovery.js"),
                .copy("../../script/codex_turn_result.js"),
                .copy("../../script/omp_thread_wakeup.js")
            ]
        )
    ]
)
