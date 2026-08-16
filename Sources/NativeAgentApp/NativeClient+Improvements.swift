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
import CommandPalette
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

// W-H Band (U5 decomposition, move-only): improvement gauntlet + capability
// pack install/rollback cluster, relocated verbatim into a same-module
// extension. Two documented private→internal lifts in the root (general
// process helpers shared with the git/backup paths that stay there):
// runProcess, processDetail.
extension NativeClient {
    func runImprovementGauntlet() async throws -> ImprovementGauntletRun {
        // Swift-only manual gauntlet. This keeps the existing
        // improvements/gauntlet/runs.json contract that getImprovementGauntlet()
        // reads, but executes the "swift" promotion class checks locally instead
        // of routing through the retired daemon endpoint.
        let startedAt = Date()
        let repoRoot = PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        let appPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("NativeAgent.app", isDirectory: true)
        let smokeScript = repoRoot
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("smoke_all.sh")

        let checks: [GauntletCheck] = [
            try await Self.runGauntletProcessCheck(
                id: "swift_build",
                title: "Swift package builds",
                executable: "/usr/bin/swift",
                arguments: ["build"],
                currentDirectory: repoRoot,
                timeout: 180
            ),
            try await Self.runGauntletProcessCheck(
                id: "isolated_smoke",
                title: "Native smoke sweep passes",
                executable: "/bin/zsh",
                arguments: [smokeScript.path],
                currentDirectory: repoRoot,
                timeout: 240
            ),
            try await Self.runGauntletProcessCheck(
                id: "app_verify",
                title: "Installed app verifies",
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appPath.path],
                currentDirectory: repoRoot,
                timeout: 60
            ),
        ]

        let passed = checks.allSatisfy(\.passed)
        let run = ImprovementGauntletRun(
            id: "gauntlet-\(UUID().uuidString.lowercased())",
            objective: "Manual Swift-native promotion gauntlet",
            promotionClass: "swift",
            status: passed ? "passed" : "failed",
            dryRun: false,
            checks: checks,
            createdAt: ISO8601DateFormatter().string(from: startedAt)
        )
        try await Self.persistImprovementGauntletRun(run)
        return run
    }

    private static func runGauntletProcessCheck(
        id: String,
        title: String,
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> GauntletCheck {
        let result = try await runProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
        return GauntletCheck(
            id: id,
            title: title,
            passed: result.status == 0,
            detail: processDetail(result)
        )
    }

    private static func persistImprovementGauntletRun(_ run: ImprovementGauntletRun) async throws {
        let data = try JSONEncoder().encode(run)
        let row = try JSONValue.parse(data)
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("gauntlet", isDirectory: true)
            .appendingPathComponent("runs.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            var rows: [JSONValue]
            if case .array(let existing) = raw {
                rows = existing
            } else {
                rows = []
            }
            rows.append(row)
            if rows.count > 200 {
                rows = Array(rows.suffix(200))
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

    func installDemoCapabilityPack() async throws -> CapabilityPackInstall {
        let root = PersistenceCore.defaultDataRoot()
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let signer = SwiftNativeCapabilityPackSigner(dataRoot: root, persistence: persistence)
        let signed = try await signer.sign(Self.demoCapabilityPack(nowISO: nowISO))
        let validation = try await signer.validate(signed)
        guard case .bool(true)? = validation["valid"] else {
            let errors: String = {
                if case .array(let rows)? = validation["errors"] {
                    return rows.compactMap {
                        if case .string(let s) = $0 { return s }
                        return nil
                    }.joined(separator: "; ")
                }
                return "unknown validation failure"
            }()
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Demo capability pack failed validation: \(errors)"
            ])
        }
        let receipt = try await Self.installCapabilityPack(signed, root: root, persistence: persistence, nowISO: nowISO)
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
        let root = PersistenceCore.defaultDataRoot()
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
        try await installSkillItems(
            capabilityPackObjects(pack, category: "skills"),
            root: root,
            persistence: persistence,
            installID: installID,
            packID: packID,
            nowISO: nowISO
        )
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
            let raw = await persistence.readJSON(installsPath, defaultValue: .array([]))
            var rows: [[String: JSONValue]] = []
            if case .array(let existing) = raw {
                rows = existing.compactMap {
                    if case .object(let obj) = $0 { return obj }
                    return nil
                }
            }
            guard let idx = rows.firstIndex(where: { jsonString($0, "id") == id }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack install '\(id)' not found."
                ])
            }
            var row = rows[idx]
            row["status"] = .string("rolled_back")
            row["rolledBackAt"] = .string(nowISO)
            rows[idx] = row
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: installsPath)
            return row
        }
        let packID = jsonString(target, "packId")
        let itemIDs = installedItemIDs(from: target)
        try await removePackCatalogItems(itemIDs.catalog, installID: id, packID: packID, root: root, persistence: persistence)
        try await removePackWorkflowItems(itemIDs.workflows, installID: id, packID: packID, root: root, persistence: persistence)
        try await removePackSkillItems(itemIDs.skills, installID: id, packID: packID, root: root, persistence: persistence)
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
            skills: capabilityPackObjects(pack, category: "skills").map { skillPackID($0) }.filter { !$0.isEmpty }
        )
    }

    private static func installedItemIDs(from receipt: [String: JSONValue]) -> (catalog: [String], workflows: [String], skills: [String]) {
        guard case .object(let itemIds)? = receipt["itemIds"] else { return ([], [], []) }
        func strings(_ key: String) -> [String] {
            guard case .array(let values)? = itemIds[key] else { return [] }
            return values.compactMap {
                if case .string(let s) = $0, !s.isEmpty { return s }
                return nil
            }
        }
        return (strings("catalog"), strings("workflows"), strings("skills"))
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
            var rows = await readObjectArray(path, persistence: persistence)
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
            var rows = await readObjectArray(path, persistence: persistence)
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

    private static func installSkillItems(
        _ items: [[String: JSONValue]],
        root: URL,
        persistence: SwiftNativePersistenceCore,
        installID: String,
        packID: String,
        nowISO: String
    ) async throws {
        guard !items.isEmpty else { return }
        let path = root.appendingPathComponent("skills/registry.json")
        let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true)
        try await persistence.withFileLock(path) {
            var rows = await readObjectArray(path, persistence: persistence)
            let ids = Set(items.map { skillPackID($0) }.filter { !$0.isEmpty })
            rows.removeAll { ids.contains(jsonString($0, "id")) }
            try FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
            for item in items {
                let skillID = skillPackID(item)
                guard !skillID.isEmpty else { continue }
                let name = jsonString(item, "name").isEmpty ? skillID : jsonString(item, "name")
                let description = jsonString(item, "description").isEmpty
                    ? "Installed by capability pack \(packID)."
                    : jsonString(item, "description")
                let content = jsonString(item, "content").isEmpty
                    ? "# \(name)\n\n\(description)\n"
                    : jsonString(item, "content")
                let bodyPath = bodiesDir.appendingPathComponent("\(skillID).md")
                try Data(content.utf8).write(to: bodyPath, options: .atomic)
                var triggers: [JSONValue] = [.string(name)]
                if case .array(let rawTriggers)? = item["triggers"], !rawTriggers.isEmpty {
                    triggers = rawTriggers
                }
                rows.append([
                    "id": .string(skillID),
                    "name": .string(name),
                    "description": .string(description),
                    "triggers": .array(triggers),
                    "kind": .string(jsonString(item, "kind").isEmpty ? "skill" : jsonString(item, "kind")),
                    "status": .string(jsonString(item, "status").isEmpty ? "active" : jsonString(item, "status")),
                    "autoCreated": .bool(false),
                    "sourceRunId": .null,
                    "bodyPath": .string(bodyPath.path),
                    "createdAt": .string(nowISO),
                    "updatedAt": .string(nowISO),
                    "useCount": .int(0),
                    "lastUsedAt": .null,
                    "installedByPack": .string(packID),
                    "capabilityPackInstallId": .string(installID),
                ])
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

    private static func removePackSkillItems(
        _ ids: [String],
        installID: String,
        packID: String,
        root: URL,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        let path = root.appendingPathComponent("skills/registry.json")
        let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true).standardizedFileURL
        try await persistence.withFileLock(path) {
            var rows = await readObjectArray(path, persistence: persistence)
            var removedBodyPaths: [URL] = []
            rows.removeAll { row in
                let marked = jsonString(row, "capabilityPackInstallId") == installID || jsonString(row, "installedByPack") == packID
                let matches = ids.isEmpty || ids.contains(jsonString(row, "id"))
                guard marked && matches else { return false }
                let body = jsonString(row, "bodyPath")
                if !body.isEmpty {
                    let bodyURL = URL(fileURLWithPath: body).standardizedFileURL
                    if bodyURL.path == bodiesDir.path || bodyURL.path.hasPrefix(bodiesDir.path + "/") {
                        removedBodyPaths.append(bodyURL)
                    }
                }
                return true
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
            for bodyPath in removedBodyPaths {
                try? FileManager.default.removeItem(at: bodyPath)
            }
        }
    }

    private static func removeMarkedRows(
        path: URL,
        ids: [String],
        installID: String,
        packID: String,
        persistence: SwiftNativePersistenceCore
    ) async throws {
        try await persistence.withFileLock(path) {
            var rows = await readObjectArray(path, persistence: persistence)
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
            var rows = await readObjectArray(path, persistence: persistence)
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
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(event, to: path)
        }
    }

    private static func capabilityPackInstallsPath(root: URL) -> URL {
        root.appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("installs.json")
    }

    private static func readObjectArray(_ path: URL, persistence: SwiftNativePersistenceCore) async -> [[String: JSONValue]] {
        let raw = await persistence.readJSON(path, defaultValue: .array([]))
        guard case .array(let rows) = raw else { return [] }
        return rows.compactMap {
            if case .object(let obj) = $0 { return obj }
            return nil
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

    private static func skillPackID(_ item: [String: JSONValue]) -> String {
        let explicit = jsonString(item, "id")
        if !explicit.isEmpty { return explicit }
        let name = jsonString(item, "name")
        return swiftCatalogSlugify(name)
    }
}
