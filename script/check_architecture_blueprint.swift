#!/usr/bin/env swift

import Foundation

struct Family {
    let label: String
    let directory: String
    let prefix: String
}

struct Options {
    var repo: URL
}

func parseOptions() -> Options {
    var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--repo":
            guard !args.isEmpty else {
                fatalError("--repo requires a path")
            }
            repo = URL(fileURLWithPath: args.removeFirst())
        case "--help", "-h":
            print("""
            Architecture blueprint drift check

            Usage:
              script/check_architecture_blueprint.swift [--repo PATH]

            Checks that architecture-map Markdown table rows match the enforced
            Swift file families on disk, and that active operational instructions
            do not point agents at retired runtime paths.
            """)
            exit(0)
        default:
            fatalError("unknown argument: \(arg)")
        }
    }
    return Options(repo: repo)
}

func basename(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

func markdownTableSwiftFiles(in text: String) throws -> Set<String> {
    let pattern = #"`([^`]+\.swift)`"#
    let regex = try NSRegularExpression(pattern: pattern)
    var files: Set<String> = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains(".swift") else { continue }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: line) else { continue }
            let value = String(line[valueRange])
            if value.contains("*") { continue }
            files.insert(basename(value))
        }
    }
    return files
}

func swiftFilesByBasename(under roots: [URL]) -> [String: [String]] {
    let fm = FileManager.default
    var index: [String: [String]] = [:]
    for root in roots {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let base = url.lastPathComponent
            index[base, default: []].append(url.path)
        }
    }
    return index
}

struct StaleInstructionRule {
    let id: String
    let file: String
    let pattern: String
    let message: String
}

func appendMatches(
    repo: URL,
    rule: StaleInstructionRule,
    errors: inout [String]
) throws {
    let url = repo.appendingPathComponent(rule.file)
    guard FileManager.default.fileExists(atPath: url.path) else {
        errors.append("stale instruction rule \(rule.id) references missing file: \(rule.file)")
        return
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    let regex = try NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
    for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = String(rawLine)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard regex.firstMatch(in: line, range: range) != nil else { continue }
        let snippet = line.trimmingCharacters(in: .whitespaces)
        errors.append("stale instruction [\(rule.id)] \(rule.file):\(offset + 1): \(rule.message) -- \(snippet)")
    }
}

func appendStaleInstructionErrors(repo: URL, errors: inout [String]) throws {
    var identityFiles = [
        "README.md",
        "AGENTS.md",
        "SECURITY.md",
        "PROJECT_STATUS.md",
        "docs/ARCHITECTURE_BLUEPRINT.md",
        "docs/PROJECT_DIRECTION.md",
        "docs/data-bounds.md",
        "docs/mobile_companion.md",
        "docs/approval-schema.md",
        "docs/threat-model.md",
        "docs/apns-push.md",
    ]

    // The private development handoff is intentionally absent from the
    // generic public export. Scan it when present without making that
    // internal-only document a requirement of the public source tree.
    let privateHandoff = "docs/HANDOFF_CURRENT.md"
    if FileManager.default.fileExists(atPath: repo.appendingPathComponent(privateHandoff).path) {
        identityFiles.append(privateHandoff)
    }

    // Keep the retired identity split in this source. The public export
    // rewrites private instance names in ordinary product text; a contiguous
    // literal here would be rewritten into the public default and make the
    // exported guard reject its own configured name.
    let retiredLocalPersonaPattern = #"\bJen"# + #"na\b"#

    var rules: [StaleInstructionRule] = identityFiles.map {
        StaleInstructionRule(
            id: "retired-identity",
            file: $0,
            pattern: retiredLocalPersonaPattern,
            message: "active public docs must not name the retired local persona identity"
        )
    }

    rules += [
        StaleInstructionRule(
            id: "retired-daemon-http",
            file: "AGENTS.md",
            pattern: #"127\.0\.0\.1:8765|/v1/consolidation/audit"#,
            message: "agent instructions must not call retired daemon HTTP endpoints"
        ),
        StaleInstructionRule(
            id: "retired-codex-environment",
            file: ".codex/environments/environment.toml",
            pattern: #"\bdaemon\b"#,
            message: "Codex environment actions must describe the Swift-native app"
        ),
        StaleInstructionRule(
            id: "retired-security-model",
            file: "SECURITY.md",
            pattern: #"daemon port|LAN with pairing token|LAN[^`]*daemon"#,
            message: "security policy must describe the current Swift/iCloud trust model"
        ),
        StaleInstructionRule(
            id: "retired-prune-owner",
            file: "docs/data-bounds.md",
            pattern: #"native_agentd\.py|_prune_unbounded_state\(\)|Same prune pass"#,
            message: "data bounds must attribute live retention to Swift app-owned paths"
        ),
        StaleInstructionRule(
            id: "retired-mobile-transport",
            file: "docs/mobile_companion.md",
            pattern: #"daemon forwarding|from daemon|daemon HTTP|/v1/missions` from daemon"#,
            message: "mobile companion docs must stay iCloud/Swift-runtime oriented"
        ),
        StaleInstructionRule(
            id: "retired-approval-runtime",
            file: "docs/approval-schema.md",
            pattern: #"Mac daemon|running daemon|native_agentd\.py|_internal_approval_token|daemon's live process|local loopback HTTP path"#,
            message: "approval docs must describe durable Swift-owned approval execution"
        ),
        StaleInstructionRule(
            id: "retired-ios-project-comment",
            file: "iOS/NativeAgentMobile/project.yml",
            pattern: #"LAN daemon|Tailscale.*server URL"#,
            message: "iOS project comments must not describe retired LAN daemon setup"
        ),
        StaleInstructionRule(
            id: "retired-ios-action-routing",
            file: "iOS/NativeAgentMobile/Sources/iCloudSyncEngine.swift",
            pattern: #"dispatches to daemon|daemon endpoint"#,
            message: "iOS sync comments must route to MacSyncEngine and Swift runtime"
        ),
        StaleInstructionRule(
            id: "retired-ios-action-routing",
            file: "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift",
            pattern: #"dispatches to daemon|daemon endpoint"#,
            message: "iOS action comments must route to MacSyncEngine and Swift runtime"
        ),
        StaleInstructionRule(
            id: "retired-ios-action-routing",
            file: "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Setup.swift",
            pattern: #"dispatches to daemon|daemon endpoint"#,
            message: "iOS setup comments must route to MacSyncEngine and Swift runtime"
        ),
        StaleInstructionRule(
            id: "retired-ios-action-routing",
            file: "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Snapshots.swift",
            pattern: #"dispatches to daemon|daemon endpoint"#,
            message: "iOS snapshot comments must route to MacSyncEngine and Swift runtime"
        ),
        StaleInstructionRule(
            id: "retired-ios-pairing-comment",
            file: "iOS/NativeAgentMobile/Sources/PairingStore.swift",
            pattern: #"<lan-ip>:8765|LAN daemon"#,
            message: "iOS pairing comments must not document retired LAN pairing as current setup"
        ),
        StaleInstructionRule(
            id: "retired-ios-kg-comment",
            file: "iOS/NativeAgentMobile/Sources/KnowledgeGraphView.swift",
            pattern: #"Mac daemon|old daemon /v1"#,
            message: "iOS knowledge graph comments must describe iCloud snapshots and retired envelopes accurately"
        ),
        StaleInstructionRule(
            id: "retired-ios-onboarding-comment",
            file: "iOS/NativeAgentMobile/Sources/NativeAgentMobileApp.swift",
            pattern: #"/v1/onboarding/start|now-dead daemon|post-wave-20 daemon"#,
            message: "iOS onboarding comments must not point to retired onboarding HTTP routes"
        ),
        StaleInstructionRule(
            id: "retired-ios-mac-integration-copy",
            file: "iOS/NativeAgentMobile/Sources/MacIntegrationView.swift",
            pattern: #"Mac daemon"#,
            message: "iOS Mac integration copy must describe the Swift runtime"
        ),
        StaleInstructionRule(
            id: "retired-ios-provider-routing",
            file: "iOS/NativeAgentMobile/Sources/ProviderSettingsView.swift",
            pattern: #"daemon /v1|daemon/native_agentd\.py"#,
            message: "iOS provider comments must point to Swift provider handlers"
        ),
        StaleInstructionRule(
            id: "retired-ios-http-runtime",
            // R26: the old Mac bridge facade was renamed to MacBridgeClient;
            // the rule keeps guarding the same file.
            file: "iOS/NativeAgentMobile/Sources/MacBridgeClient.swift",
            pattern: #"daemon HTTP server|Mac daemon returned HTTP"#,
            message: "iOS bridge facade must not describe a live daemon HTTP runtime"
        ),
        StaleInstructionRule(
            id: "retired-skill-manifest-runtime",
            file: "docs/skill_manifest_spec.md",
            pattern: #"(?i)\bdaemon\b|native_agentd\.py|daemon's venv Python|Daemon-Side"#,
            message: "skill manifest spec must describe the Swift runtime rather than daemon-owned skills"
        ),
        StaleInstructionRule(
            id: "retired-release-migration-instructions",
            file: "docs/release-migration.md",
            pattern: #"127\.0\.0\.1:8765|native_agentd\.py|Verify daemon started|Bundled Python hash verification"#,
            message: "release migration docs must not prescribe retired daemon/Python runtime checks"
        ),
        StaleInstructionRule(
            id: "retired-example-oauth-callback",
            file: "docs/example_manifests/slack.json",
            pattern: #"127\.0\.0\.1:8765"#,
            message: "example OAuth manifests must use current nativeagent:// callback URIs"
        ),
        StaleInstructionRule(
            id: "retired-example-oauth-callback",
            file: "docs/example_manifests/gmail.json",
            pattern: #"127\.0\.0\.1:8765"#,
            message: "example OAuth manifests must use current nativeagent:// callback URIs"
        ),
        StaleInstructionRule(
            id: "retired-example-oauth-callback",
            file: "docs/example_manifests/google_calendar.json",
            pattern: #"127\.0\.0\.1:8765"#,
            message: "example OAuth manifests must use current nativeagent:// callback URIs"
        ),
        StaleInstructionRule(
            id: "retired-example-oauth-callback",
            file: "docs/example_manifests/notion.json",
            pattern: #"127\.0\.0\.1:8765"#,
            message: "example OAuth manifests must use current nativeagent:// callback URIs"
        ),
    ]

    for rule in rules {
        try appendMatches(repo: repo, rule: rule, errors: &errors)
    }
}

func appendCognitiveTraceabilityErrors(repo: URL, errors: inout [String]) throws {
    let path = "docs/COGNITIVE_SUBSTRATE_TRACEABILITY.md"
    let url = repo.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        errors.append("cognitive substrate traceability ledger is missing: \(path)")
        return
    }

    let text = try String(contentsOf: url, encoding: .utf8)
    let phaseRequirements: [(phase: String, deliverables: ClosedRange<Int>, acceptances: ClosedRange<Int>)] = [
        ("P0", 1...6, 1...4),
        ("P1", 1...15, 1...5),
        ("P2", 1...6, 1...5),
        ("P3", 1...6, 1...5),
        ("P4", 1...6, 1...6),
        ("P5", 1...6, 1...4),
        ("P6", 1...5, 1...5),
        ("P7", 1...6, 1...5),
        ("P8", 1...6, 1...4),
        ("P9", 1...7, 1...5),
        ("P10", 1...6, 1...3),
    ]

    var requiredMarkers: [String] = []
    for requirement in phaseRequirements {
        requiredMarkers += requirement.deliverables.map { "CCS-\(requirement.phase)-D\($0)" }
        requiredMarkers += requirement.acceptances.map { "CCS-\(requirement.phase)-A\($0)" }
    }
    requiredMarkers += (1...9).map { "CCS-X\($0)" }
    requiredMarkers += ["Status Rules", "Next Execution Order"]

    for marker in requiredMarkers where !text.contains(marker) {
        errors.append("cognitive substrate traceability ledger missing required marker: \(marker)")
    }
}

func appendTransitionShadowAuthorizationOwnershipErrors(repo: URL, errors: inout [String]) throws {
    let sourcesRoot = repo.appendingPathComponent("Modules/NativeAgentCore/Sources", isDirectory: true)
    let forbidden = [
        "PersistenceCore/OperationalTransitionShadowModel.swift",
        "ApprovalInbox/ApprovalInbox+TransitionShadowAuthorization.swift",
    ]
    for relative in forbidden where FileManager.default.fileExists(
        atPath: sourcesRoot.appendingPathComponent(relative).path
    ) {
        errors.append("retired transition-shadow machinery reintroduced: \(relative)")
    }
    guard let enumerator = FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        errors.append("cannot enumerate NativeAgentCore sources for transition-shadow authorization ownership")
        return
    }
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        let relative = String(url.path.dropFirst(sourcesRoot.path.count + 1))
        for symbol in ["OperationalTransitionShadow", "personal_trace_shadow"]
        where text.contains(symbol) {
            errors.append("retired transition-shadow symbol reintroduced in \(relative): \(symbol)")
        }
    }
}

func appendRetiredProductionMetacognitiveShadowErrors(repo: URL, errors: inout [String]) throws {
    let forbidden: [(path: String, needles: [String])] = [
        (
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+StructuredChat.swift",
            ["MetacognitiveShadowEvaluator.recommend", "metacognitiveShadow:"]
        ),
        (
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+TextCompatibility.swift",
            ["MetacognitiveShadowEvaluator.recommend", "metacognitiveShadow:"]
        ),
        (
            "Modules/NativeAgentCore/Sources/ChatOrchestration/TurnPlanning.swift",
            ["metacognitiveShadow", "turn.plan.shadow"]
        ),
    ]

    for entry in forbidden {
        let url = repo.appendingPathComponent(entry.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errors.append("production metacognitive-shadow guard references missing file: \(entry.path)")
            continue
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        for needle in entry.needles where text.contains(needle) {
            errors.append("retired production metacognitive shadow reintroduced in \(entry.path): \(needle)")
        }
    }
}

func appendRetiredProductionAdaptiveEffortErrors(repo: URL, errors: inout [String]) throws {
    let productionBoundaryFiles = [
        "Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox.swift",
        "Modules/NativeAgentCore/Sources/ChatDrive/main.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+Client.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestration+ToolLoop.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+Factories.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+MessagePersistence.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+StructuredChat.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+TextCompatibility.swift",
        "Sources/NativeAgentApp/AppChatToolDispatcher.swift",
        "Sources/NativeAgentApp/AppModel.swift",
        "Sources/NativeAgentApp/AppModel+ViewClientOps.swift",
        "Sources/NativeAgentApp/ChatBrainControlBar.swift",
        "Sources/NativeAgentApp/ChatView+SlashCommands.swift",
        "Sources/NativeAgentApp/NativeClient+ApprovalExecutors.swift",
        "Sources/NativeAgentApp/NativeClient+CutoverSeams.swift",
    ]
    for path in productionBoundaryFiles {
        let url = repo.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errors.append("production adaptive-effort retirement guard references missing file: \(path)")
            continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        if source.localizedCaseInsensitiveContains("adaptiveReasoningEffort")
            || source.contains("AdaptiveReasoningEffort") {
            errors.append("retired adaptive-effort production path reintroduced in \(path)")
        }
    }
    let forbiddenFiles = [
        "Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox+AdaptiveReasoningEffort.swift",
        "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+AdaptiveReasoningEffort.swift",
        "Modules/NativeAgentCore/Sources/PersistenceCore/AdaptiveReasoningEffortStore.swift",
    ]
    for path in forbiddenFiles where FileManager.default.fileExists(
        atPath: repo.appendingPathComponent(path).path
    ) {
        errors.append("retired adaptive-effort machinery reintroduced: \(path)")
    }
}

func appendResidentMindConvergenceErrors(repo: URL, errors: inout [String]) throws {
    let contracts: [(path: String, required: [String], forbidden: [String])] = [
        (
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+Client.swift",
            ["checkedRouteAdmission"],
            []
        ),
        (
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+StreamFacade.swift",
            ["checkedRouteAdmission"],
            []
        ),
        (
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestration+TurnEngine.swift",
            ["provider.admissionReused"],
            []
        ),
        (
            "Modules/NativeAgentCore/Sources/WorkshopExecution/WorkshopExecution+PlannerLLM.swift",
            ["checkedRoutingSnapshot"],
            ["computeModelPreferences"]
        ),
        (
            "Modules/NativeAgentCore/Sources/CognitiveSubstrate/CognitiveSubstrate+Workspace.swift",
            ["persistMaintenanceTransition"],
            ["try await persistSnapshot(", "try await persistThoughtSeedFamily(", "try await recordReceiptChecked("]
        ),
        (
            "Modules/NativeAgentCore/Sources/PersistenceCore/TurnTrace.swift",
            ["_PersistPump", "capacity: 4096"],
            []
        ),
        (
            "Modules/NativeAgentCore/Sources/PersistenceCore/InstalledPhysiologySoak.swift",
            [
                "minimumLatencySampleCount = 20",
                "currentMeasurementEpoch = \"resident-live-latency-v3\"",
                "acceptanceP95 >= 25",
                "microcycleP95 >= 25",
                "qualifiesForResidentLatency",
                "qualifiesForOrdinaryTurnLatency",
                "retention capacity was saturated",
                "fewer than 20 ordinary chat latency samples",
                "cognitiveSubstrateAcceptanceMilliseconds",
                "somaticAcceptanceMilliseconds",
                "residualSchedulingAcceptanceMilliseconds",
            ],
            []
        ),
    ]

    for contract in contracts {
        let url = repo.appendingPathComponent(contract.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errors.append("resident-mind convergence guard references missing file: \(contract.path)")
            continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        for marker in contract.required where !source.contains(marker) {
            errors.append("resident-mind convergence contract missing in \(contract.path): \(marker)")
        }
        for marker in contract.forbidden where source.contains(marker) {
            errors.append("retired resident-mind path reintroduced in \(contract.path): \(marker)")
        }
    }

    let sourcesRoot = repo.appendingPathComponent("Modules/NativeAgentCore/Sources", isDirectory: true)
    if let enumerator = FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("WorkshopTerminalOutcomeInterpreter") {
                let relative = String(url.path.dropFirst(sourcesRoot.path.count + 1))
                errors.append("retired Workshop terminal interpreter reintroduced in \(relative)")
            }
        }
    } else {
        errors.append("cannot enumerate NativeAgentCore sources for retired Workshop interpreter")
    }
}

func actualFamilyFiles(repo: URL, family: Family) throws -> Set<String> {
    let dir = repo.appendingPathComponent(family.directory, isDirectory: true)
    let urls = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    return Set(urls
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(family.prefix) }
        .map(\.lastPathComponent))
}

let options = parseOptions()
let repo = options.repo.standardizedFileURL
let blueprint = repo
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("ARCHITECTURE_BLUEPRINT.md")
let text = try String(contentsOf: blueprint, encoding: .utf8)
let tableFiles = try markdownTableSwiftFiles(in: text)

let sourceRoots = [
    repo.appendingPathComponent("Sources", isDirectory: true),
    repo.appendingPathComponent("Modules/NativeAgentCore/Sources", isDirectory: true),
    repo.appendingPathComponent("iOS/NativeAgentMobile/Sources", isDirectory: true),
]
let fileIndex = swiftFilesByBasename(under: sourceRoots)

let enforcedFamilies: [Family] = [
    Family(label: "AppDelegate", directory: "Sources/NativeAgentApp", prefix: "AppDelegate+"),
    Family(label: "AppModel", directory: "Sources/NativeAgentApp", prefix: "AppModel+"),
    Family(label: "BackgroundLoopsAssembly", directory: "Sources/NativeAgentApp", prefix: "BackgroundLoopsAssembly+"),
    Family(label: "NativeClient", directory: "Sources/NativeAgentApp", prefix: "NativeClient+"),
    Family(label: "SchedulerDueJobRunner", directory: "Sources/NativeAgentApp", prefix: "SchedulerDueJobRunner+"),
    Family(label: "NativeOAuthFlow", directory: "Sources/NativeAgentApp", prefix: "NativeOAuthFlow+"),
    Family(label: "MacSyncEngine", directory: "Sources/NativeAgentApp", prefix: "MacSyncEngine+"),
    Family(label: "MacAppleScriptBridge", directory: "Sources/NativeAgentApp", prefix: "MacAppleScriptBridge+"),
    Family(label: "ChatView", directory: "Sources/NativeAgentApp", prefix: "ChatView+"),
    Family(label: "KnowledgeGraphView", directory: "Sources/NativeAgentApp", prefix: "KnowledgeGraphView+"),
    Family(label: "TrustCenter", directory: "Modules/NativeAgentCore/Sources/TrustCenter", prefix: "TrustCenter+"),
    Family(label: "SecurityCenter", directory: "Modules/NativeAgentCore/Sources/TrustCenter", prefix: "SecurityCenter+"),
    Family(label: "TelegramPollLoop", directory: "Modules/NativeAgentCore/Sources/TelegramBot", prefix: "TelegramPollLoop+"),
    Family(label: "ChatOrchestrationClient", directory: "Modules/NativeAgentCore/Sources/ChatOrchestration", prefix: "ChatOrchestrationClient+"),
    Family(label: "Research", directory: "Modules/NativeAgentCore/Sources/Research", prefix: "Research+"),
    Family(label: "SwiftToolDispatcher", directory: "Modules/NativeAgentCore/Sources/ChatOrchestration", prefix: "SwiftToolDispatcher+"),
]

var errors: [String] = []

for file in tableFiles.sorted() where fileIndex[file] == nil {
    errors.append("blueprint table row names missing file: \(file)")
}

for family in enforcedFamilies {
    let actual = try actualFamilyFiles(repo: repo, family: family)
    let documented = Set(tableFiles.filter { $0.hasPrefix(family.prefix) })
    let missingRows = actual.subtracting(documented).sorted()
    let staleRows = documented.subtracting(actual).sorted()
    for file in missingRows {
        errors.append("\(family.label): file exists but has no blueprint table row: \(file)")
    }
    for file in staleRows {
        errors.append("\(family.label): blueprint table row has no matching file: \(file)")
    }
}

try appendStaleInstructionErrors(repo: repo, errors: &errors)
try appendCognitiveTraceabilityErrors(repo: repo, errors: &errors)
try appendTransitionShadowAuthorizationOwnershipErrors(repo: repo, errors: &errors)
try appendRetiredProductionMetacognitiveShadowErrors(repo: repo, errors: &errors)
try appendRetiredProductionAdaptiveEffortErrors(repo: repo, errors: &errors)
try appendResidentMindConvergenceErrors(repo: repo, errors: &errors)

if errors.isEmpty {
    print("[blueprint] architecture blueprint and active-instruction drift check passed (\(enforcedFamilies.count) families, \(tableFiles.count) Swift table rows)")
} else {
    fputs("[blueprint] ERROR: architecture blueprint or active-instruction drift detected\n", stderr)
    for error in errors.sorted() {
        fputs("  - \(error)\n", stderr)
    }
    exit(1)
}
