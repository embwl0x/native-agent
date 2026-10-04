import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

extension NativeClient {
    func runImprovementGauntlet(
        processRunner: GauntletProcessRunner? = nil
    ) async throws -> ImprovementGauntletRun {
        // Swift-only manual gauntlet. This keeps the existing
        // improvements/gauntlet/runs.json contract that getImprovementGauntlet()
        // reads, but executes the "swift" promotion class checks locally instead
        // of routing through the retired daemon endpoint.
        let startedAt = Date()
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let repoRoot = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot)
        let appPath = Bundle.main.bundleURL
        var checks: [GauntletCheck] = []
        var unavailableIDs: Set<String> = []
        func unavailable(_ id: String, _ title: String, _ detail: String) {
            unavailableIDs.insert(id)
            checks.append(GauntletCheck(
                id: id, title: "\(title) (unavailable)", passed: false, detail: detail
            ))
        }

        if let repoRoot {
            checks.append(try await Self.runGauntletProcessCheck(
                id: "swift_build",
                title: "Swift package builds",
                executable: "/usr/bin/swift",
                arguments: ["build"],
                currentDirectory: repoRoot,
                timeout: 180,
                processRunner: processRunner
            ))
            let smokeScript = repoRoot.appendingPathComponent("script/smoke_all.sh")
            if FileManager.default.fileExists(atPath: smokeScript.path) {
                checks.append(try await Self.runGauntletProcessCheck(
                    id: "isolated_smoke",
                    title: "Native smoke sweep passes",
                    executable: "/bin/zsh",
                    arguments: [smokeScript.path],
                    currentDirectory: repoRoot,
                    timeout: 240,
                    processRunner: processRunner
                ))
            } else {
                unavailable("isolated_smoke", "Native smoke sweep passes", "The checkout has no smoke check script.")
            }
        } else {
            unavailable("swift_build", "Swift package builds", "No validated NativeAgent checkout is available.")
            unavailable("isolated_smoke", "Native smoke sweep passes", "No validated NativeAgent checkout is available.")
        }
        if appPath.pathExtension == "app" {
            checks.append(try await Self.runGauntletProcessCheck(
                id: "app_verify",
                title: "Installed app verifies",
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appPath.path],
                currentDirectory: appPath.deletingLastPathComponent(),
                timeout: 60,
                processRunner: processRunner
            ))
        } else {
            unavailable("app_verify", "Installed app verifies", "This process is not running from an app bundle.")
        }

        let failed = checks.contains { !$0.passed && !unavailableIDs.contains($0.id) }
        let run = ImprovementGauntletRun(
            id: "gauntlet-\(UUID().uuidString.lowercased())",
            objective: "Manual Swift-native promotion gauntlet",
            promotionClass: "swift",
            status: failed ? "failed" : (unavailableIDs.isEmpty ? "passed" : "unavailable"),
            dryRun: false,
            checks: checks,
            createdAt: ISO8601DateFormatter().string(from: startedAt)
        )
        try await Self.persistImprovementGauntletRun(run, dataRoot: dataRoot)
        return run
    }

    private static func runGauntletProcessCheck(
        id: String,
        title: String,
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval,
        processRunner: GauntletProcessRunner?
    ) async throws -> GauntletCheck {
        let result: (status: Int32, stdout: String, stderr: String)
        if let processRunner {
            result = try await processRunner(executable, arguments, currentDirectory, timeout)
        } else {
            result = try await runProcess(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                timeout: timeout
            )
        }
        return GauntletCheck(
            id: id,
            title: title,
            passed: result.status == 0,
            detail: processDetail(result)
        )
    }

    private static func persistImprovementGauntletRun(
        _ run: ImprovementGauntletRun,
        dataRoot: URL
    ) async throws {
        let data = try JSONEncoder().encode(run)
        let row = try JSONValue.parse(data)
        let path = dataRoot
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("gauntlet", isDirectory: true)
            .appendingPathComponent("runs.json")
        try await Self.appendBoundedRun(row, to: path)
    }

    func installDemoCapabilityPack() async throws -> CapabilityPackInstall {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let signer = SwiftNativeCapabilityPackSigner(dataRoot: root, persistence: persistence)
        let signed = try await signer.sign(Self.demoCapabilityPack(nowISO: nowISO))
        return try await installCapabilityPack(signed)
    }

    /// Installs an acquired catalog pack only after the canonical signer has
    /// verified its signature and trusted signing identity. This is the same
    /// boundary used by the visible signed-demo action, and validation happens
    /// before any pack, catalog item, or install receipt is persisted.
    func installCapabilityPack(_ pack: [String: JSONValue]) async throws -> CapabilityPackInstall {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let receipt = try await Self.installCapabilityPack(pack, root: root, persistence: persistence, nowISO: nowISO)
        let data = try JSONValue.object(receipt).serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityPackInstall.self, from: data)
    }

    func rollbackCapabilityPack(id: String) async throws -> CapabilityPackInstall {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "rollbackCapabilityPack: empty install id"
            ])
        }
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let persistence = SwiftNativePersistenceCore()
        let rolledBack = try await Self.rollbackCapabilityPackInstall(id: trimmed, root: root, persistence: persistence)
        let data = try JSONValue.object(rolledBack).serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityPackInstall.self, from: data)
    }

    private static func demoCapabilityPack(nowISO: String) -> [String: JSONValue] {
        let packID = "nativeagent-demo-operator-pack"
        let workflowID = "demo-pack-memory-capture"
        let skillID = "demo-capability-pack"
        let catalogID = "catalog:\(packID)"
        return [
            "id": .string(packID),
            "name": .string("NativeAgent Demo Operator Pack"),
            "version": .string("1.0.0"),
            "description": .string("Local signed demo pack proving Swift-native capability install and rollback."),
            "provenance": .object([
                "source": .string("nativeagent-local-demo"),
                "createdAt": .string(nowISO),
            ]),
            "items": .object([
                "catalog": .array([
                    .object([
                        "id": .string(catalogID),
                        "name": .string("NativeAgent Demo Operator Pack"),
                        "kind": .string("capability_pack"),
                        "status": .string("installed"),
                        "description": .string("Signed local demo pack installed by the Swift capability-pack path."),
                        "riskClass": .string("low"),
                        "autoload": .bool(false),
                    ]),
                ]),
                "workflows": .array([
                    .object([
                        "id": .string(workflowID),
                        "name": .string("Demo Pack Memory Capture"),
                        "description": .string("Route an objective, write a memory-shaped note, and record a trace receipt."),
                        "status": .string("active"),
                        "trigger": .string("demo pack memory"),
                        "steps": .array([
                            .object([
                                "id": .string("route"),
                                "title": .string("Route objective"),
                                "kind": .string("router"),
                                "requiresApproval": .bool(false),
                            ]),
                            .object([
                                "id": .string("trace"),
                                "title": .string("Record trace receipt"),
                                "kind": .string("trace"),
                                "requiresApproval": .bool(false),
                            ]),
                        ]),
                    ]),
                ]),
                "skills": .array([
                    .object([
                        "id": .string(skillID),
                        "name": .string("Demo Capability Pack"),
                        "description": .string("Procedure installed by the Swift signed capability-pack demo."),
                        "triggers": .array([.string("demo capability pack"), .string("signed pack")]),
                        "content": .string("# Demo Capability Pack\n\nUse this to confirm signed capability packs install and roll back through Swift-owned registries.\n"),
                    ]),
                ]),
            ]),
        ]
    }

    private static func installCapabilityPack(
        _ pack: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        nowISO: String
    ) async throws -> [String: JSONValue] {
        // Keep admission and replacement in the same registry lock epoch.
        try await persistence.withFileLock(capabilityPackInstallsPath(root: root)) {
            try await persistence.withFileLock(root.appendingPathComponent("catalog/registry.json")) {
                try await persistence.withFileLock(root.appendingPathComponent("workflows/registry.json")) {
                    try await persistence.withFileLock(root.appendingPathComponent("skills/registry.json")) {
                        try await installCapabilityPackLocked(pack, root: root, persistence: persistence, nowISO: nowISO)
                    }
                }
            }
        }
    }

    private static func installCapabilityPackLocked(
        _ pack: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        nowISO: String
    ) async throws -> [String: JSONValue] {
        let signer = SwiftNativeCapabilityPackSigner(dataRoot: root, persistence: persistence)
        let validation = try await signer.validate(pack)
        guard case .bool(true)? = validation["valid"] else {
            let errors: String = {
                if case .array(let rows)? = validation["errors"] {
                    let messages = rows.compactMap { value -> String? in
                        if case .string(let message) = value { return message }
                        return nil
                    }
                    if !messages.isEmpty { return messages.joined(separator: "; ") }
                }
                return "unknown validation failure"
            }()
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack validation failed: \(errors)"
            ])
        }

        let packID = jsonString(pack, "id")
        guard !packID.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack missing id."
            ])
        }
        let installID = "install:\(packID)"
        let packName = jsonString(pack, "name")
        let version = jsonString(pack, "version")
        let signature = jsonString(pack, "signature")
        let itemIDs = capabilityPackItemIDs(pack)
        let skills = SwiftNativeSkillsClient(root: root, persistence: persistence)
        let skillItems = capabilityPackObjects(pack, category: "skills")
        let installs = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: capabilityPackInstallsPath(root: root))
        let previousItemIDs = try installs.first(where: { jsonString($0, "id") == installID })
            .map { try installedItemIDs(from: $0) }
        try await preflightPackItems(capabilityPackObjects(pack, category: "catalog"),
            path: root.appendingPathComponent("catalog/registry.json"), installID: installID, persistence: persistence)
        try await preflightPackItems(capabilityPackObjects(pack, category: "workflows"),
            path: root.appendingPathComponent("workflows/registry.json"), installID: installID, persistence: persistence)
        try skills.preflightPackSkills(skillItems, installID: installID, packID: packID)
        let packPath = root
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("packs", isDirectory: true)
            .appendingPathComponent("\(packID).json")
        try await persistence.withFileLock(packPath) {
            try await persistence.writeJSON(.object(pack), to: packPath)
        }
        try await installCatalogItems(
            capabilityPackObjects(pack, category: "catalog"),
            root: root,
            persistence: persistence,
            installID: installID,
            packID: packID,
            nowISO: nowISO
        )
        try await installWorkflowItems(
            capabilityPackObjects(pack, category: "workflows"),
            root: root,
            persistence: persistence,
            installID: installID,
            packID: packID,
            nowISO: nowISO
        )
        try await skills.installPackSkills(
            skillItems,
            installID: installID,
            packID: packID,
            nowISO: nowISO
        )
        if let previousItemIDs {
            let omittedCatalog = previousItemIDs.catalog.filter { !itemIDs.catalog.contains($0) }
            let omittedWorkflows = previousItemIDs.workflows.filter { !itemIDs.workflows.contains($0) }
            let skillIDs = Set(itemIDs.skills.map { $0.lowercased() })
            let omittedSkills = previousItemIDs.skills.filter { !skillIDs.contains($0.lowercased()) }
            // Empty removal lists mean all owned items, so only pass omissions.
            if !omittedCatalog.isEmpty {
                try await removePackCatalogItems(omittedCatalog, installID: installID, packID: packID, root: root, persistence: persistence)
            }
            if !omittedWorkflows.isEmpty {
                try await removePackWorkflowItems(omittedWorkflows, installID: installID, packID: packID, root: root, persistence: persistence)
            }
            if !omittedSkills.isEmpty {
                try await skills.removePackSkills(omittedSkills, installID: installID, packID: packID)
            }
        }
        let receipt: [String: JSONValue] = [
            "id": .string(installID),
            "packId": .string(packID),
            "name": .string(packName.isEmpty ? packID : packName),
            "version": .string(version),
            "status": .string("installed"),
            "signature": signature.isEmpty ? .null : .string(signature),
            "installedAt": .string(nowISO),
            "rolledBackAt": .null,
            "packPath": .string(packPath.path),
            "itemIds": .object([
                "catalog": .array(itemIDs.catalog.map { .string($0) }),
                "workflows": .array(itemIDs.workflows.map { .string($0) }),
                "skills": .array(itemIDs.skills.map { .string($0) }),
            ]),
        ]
        try await upsertCapabilityPackInstallReceipt(receipt, root: root, persistence: persistence)
        try await reconcileSkillEvolutionRecall(
            memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root,
            personaRoot: defaultPersonaRoot(dataRoot: root))
        try await appendCapabilityPackTrace(
            kind: "capability.pack.install",
            title: packName.isEmpty ? packID : packName,
            payload: [
                "installId": .string(installID),
                "packId": .string(packID),
                "status": .string("installed"),
            ],
            root: root,
            persistence: persistence
        )
        return receipt
    }

    private static func rollbackCapabilityPackInstall(
        id: String,
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws -> [String: JSONValue] {
        let installsPath = capabilityPackInstallsPath(root: root)
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let target = try await persistence.withFileLock(installsPath) {
            var rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: installsPath)
            guard let idx = rows.firstIndex(where: { jsonString($0, "id") == id }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install '\(id)' not found."
                ])
            }
            var row = rows[idx]
            let packID = jsonString(row, "packId")
            let itemIDs = try installedItemIDs(from: row)
            try await removePackCatalogItems(itemIDs.catalog, installID: id, packID: packID, root: root, persistence: persistence)
            try await removePackWorkflowItems(itemIDs.workflows, installID: id, packID: packID, root: root, persistence: persistence)
            try await SwiftNativeSkillsClient(root: root, persistence: persistence).removePackSkills(itemIDs.skills, installID: id, packID: packID)
            row["status"] = .string("rolled_back")
            row["rolledBackAt"] = .string(nowISO)
            rows[idx] = row
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: installsPath)
            return row
        }
        let packID = jsonString(target, "packId")
        try await reconcileSkillEvolutionRecall(
            memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root,
            personaRoot: defaultPersonaRoot(dataRoot: root))
        try await appendCapabilityPackTrace(
            kind: "capability.pack.rollback",
            title: jsonString(target, "name").isEmpty ? packID : jsonString(target, "name"),
            payload: [
                "installId": .string(id),
                "packId": .string(packID),
                "status": .string("rolled_back"),
            ],
            root: root,
            persistence: persistence
        )
        return target
    }

    private static func capabilityPackObjects(_ pack: [String: JSONValue], category: String) -> [[String: JSONValue]] {
        guard case .object(let items)? = pack["items"],
              case .array(let values)? = items[category] else { return [] }
        return values.compactMap {
            if case .object(let obj) = $0 { return obj }
            return nil
        }
    }

    private static func capabilityPackItemIDs(_ pack: [String: JSONValue]) -> (catalog: [String], workflows: [String], skills: [String]) {
        (
            catalog: capabilityPackObjects(pack, category: "catalog").map { jsonString($0, "id") }.filter { !$0.isEmpty },
            workflows: capabilityPackObjects(pack, category: "workflows").map { jsonString($0, "id") }.filter { !$0.isEmpty },
            skills: capabilityPackObjects(pack, category: "skills").map { SwiftNativeSkillsClient.packSkillID($0) }.filter { !$0.isEmpty }
        )
    }

    private static func installedItemIDs(from receipt: [String: JSONValue]) throws -> (catalog: [String], workflows: [String], skills: [String]) {
        guard case .string(let packID)? = receipt["packId"], !packID.isEmpty,
              case .object(let itemIds)? = receipt["itemIds"] else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack install receipt is invalid."
            ])
        }
        func strings(_ key: String) throws -> [String] {
            guard case .array(let values)? = itemIds[key] else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install receipt has invalid \(key) IDs."
                ])
            }
            return try values.map {
                guard case .string(let s) = $0, !s.isEmpty else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                        NSLocalizedDescriptionKey: "Capability pack install receipt has invalid \(key) IDs."
                    ])
                }
                return s
            }
        }
        return try (strings("catalog"), strings("workflows"), strings("skills"))
    }

    private static func preflightPackItems(
        _ items: [[String: JSONValue]], path: URL, installID: String, persistence: SwiftNativePersistenceCore
    ) async throws {
        let rows = try await readObjectArray(path, persistence: persistence)
        let ids = Set(items.map { jsonString($0, "id") })
        guard items.allSatisfy({
                  if case .string(let id)? = $0["id"] {
                      return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }
                  return false
              }), ids.count == items.count,
              !rows.contains(where: {
                  ids.contains(jsonString($0, "id")) && jsonString($0, "capabilityPackInstallId") != installID
              }) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack items collide with existing entries or have invalid IDs in \(path.lastPathComponent)."
            ])
        }
    }

    private static func installCatalogItems(
        _ items: [[String: JSONValue]],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        installID: String,
        packID: String,
        nowISO: String
    ) async throws {
        guard !items.isEmpty else { return }
        let path = root.appendingPathComponent("catalog/registry.json")
        try await persistence.withFileLock(path) {
            var rows = try await readObjectArray(path, persistence: persistence)
            let ids = Set(items.map { jsonString($0, "id") }.filter { !$0.isEmpty })
            rows.removeAll { ids.contains(jsonString($0, "id")) }
            for item in items {
                var row = item
                row["status"] = .string(jsonString(row, "status").isEmpty ? "installed" : jsonString(row, "status"))
                row["installed"] = .bool(true)
                row["installedAt"] = .string(nowISO)
                row["updatedAt"] = .string(nowISO)
                if row["createdAt"] == nil { row["createdAt"] = .string(nowISO) }
                row["installedByPack"] = .string(packID)
                row["capabilityPackInstallId"] = .string(installID)
                rows.append(row)
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func installWorkflowItems(
        _ items: [[String: JSONValue]],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        installID: String,
        packID: String,
        nowISO: String
    ) async throws {
        guard !items.isEmpty else { return }
        let path = root.appendingPathComponent("workflows/registry.json")
        try await persistence.withFileLock(path) {
            var rows = try await readObjectArray(path, persistence: persistence)
            let ids = Set(items.map { jsonString($0, "id") }.filter { !$0.isEmpty })
            rows.removeAll { ids.contains(jsonString($0, "id")) }
            for item in items {
                var row = item
                row["status"] = .string(jsonString(row, "status").isEmpty ? "active" : jsonString(row, "status"))
                row["createdAt"] = row["createdAt"] ?? .string(nowISO)
                row["updatedAt"] = .string(nowISO)
                row["installedByPack"] = .string(packID)
                row["capabilityPackInstallId"] = .string(installID)
                rows.append(row)
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func removePackCatalogItems(
        _ ids: [String],
        installID: String,
        packID: String,
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        try await removeMarkedRows(path: root.appendingPathComponent("catalog/registry.json"), ids: ids, installID: installID, packID: packID, persistence: persistence)
    }

    private static func removePackWorkflowItems(
        _ ids: [String],
        installID: String,
        packID: String,
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        try await removeMarkedRows(path: root.appendingPathComponent("workflows/registry.json"), ids: ids, installID: installID, packID: packID, persistence: persistence)
    }

    private static func removeMarkedRows(
        path: URL,
        ids: [String],
        installID: String,
        packID: String,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        try await persistence.withFileLock(path) {
            var rows = try await readObjectArray(path, persistence: persistence)
            rows.removeAll { row in
                let marked = jsonString(row, "capabilityPackInstallId") == installID || jsonString(row, "installedByPack") == packID
                let matches = ids.isEmpty || ids.contains(jsonString(row, "id"))
                return marked && matches
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func upsertCapabilityPackInstallReceipt(
        _ receipt: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        let path = capabilityPackInstallsPath(root: root)
        let id = jsonString(receipt, "id")
        try await persistence.withFileLock(path) {
            var rows = try CapabilityCatalogStoreReader.loadCapabilityPackInstallsChecked(at: path)
            rows.removeAll { jsonString($0, "id") == id }
            rows.append(receipt)
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    private static func appendCapabilityPackTrace(
        kind: String,
        title: String,
        payload: [String: JSONValue],
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        let path = root.appendingPathComponent("traces/events.jsonl")
        var eventPayload = payload
        if eventPayload["status"] == nil { eventPayload["status"] = .string("ok") }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string(kind),
            "title": .string(title),
            "status": eventPayload["status"] ?? .string("ok"),
            "payload": .object(eventPayload),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(Date())),
        ])
        try await appendPathOwnedJSONL(
            event,
            to: path,
            using: persistence,
            logLabel: "NativeClient.capabilityPackTrace"
        )
    }

    private static func capabilityPackInstallsPath(root: URL) -> URL {
        root.appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("installs.json")
    }

    private static func readObjectArray(_ path: URL, persistence: SwiftNativePersistenceCore) async throws -> [[String: JSONValue]] {
        let raw = try await persistence.readJSON(path, ifMissing: .array([]))
        guard case .array(let rows) = raw else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack registry must be an array: \(path.path)"
            ])
        }
        var seenIDs: Set<String> = []
        return try rows.map {
            guard case .object(let obj) = $0, case .string(let id)? = obj["id"],
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenIDs.insert(id).inserted else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack registry contains an invalid entry: \(path.path)"
                ])
            }
            return obj
        }
    }

    private static func jsonString(_ obj: [String: JSONValue], _ key: String) -> String {
        switch obj[key] {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return ""
        }
    }

}
