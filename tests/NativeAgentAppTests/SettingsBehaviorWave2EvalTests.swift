import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Skills
import Testing
import ToolExecution
import ToolRegistry
@testable import NativeAgentApp

/// High-risk Settings actions must change the authority their next owner reads.
/// These tests intentionally use actual production stores under isolated roots;
/// no view-source inspection or substitute in-memory state is used here.
@Suite("app.settings · canonical authority behavior wave 2")
struct SettingsBehaviorWave2EvalTests {
    private func tempRoot(_ name: String = "settings-behavior") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func toolRow(
        id: String = "tool-a",
        status: String = "active",
        activePath: String? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "name": id,
            "description": "hermetic test tool",
            "triggers": ["test"],
            "status": status,
            "phase": status,
            "createdAt": "2026-08-24T00:00:00Z",
            "updatedAt": "2026-08-24T00:00:00Z",
            "validationStatus": "valid",
        ]
        if let activePath { row["activePath"] = activePath }
        return row
    }

    /// The Tools toggle changes a privileged execution policy. A fresh reader
    /// must see the exact value, and damaged authority bytes must remain
    /// untouched instead of being silently replaced by an empty registry.
    @Test func toolAutoRunMutationSurvivesColdReadAndFailsClosedOnDamagedRegistry() async throws {
        let root = try tempRoot("tool-auto-run")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("tools/registry.json")
        try writeJSON([toolRow(), toolRow(id: "tool-b")], to: registry)

        let updated = try await NativeClient.updateTool(id: "tool-a", autoRun: true, dataRoot: root)
        #expect(updated.id == "tool-a")
        #expect(updated.autoRun == true)

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [[String: Any]]
        #expect(persisted.first(where: { ($0["id"] as? String) == "tool-a" })?["autoRun"] as? Bool == true)
        #expect(persisted.first(where: { ($0["id"] as? String) == "tool-b" })?["autoRun"] == nil)

        let corrupt = Data("{ definitely-not-json".utf8)
        try corrupt.write(to: registry, options: .atomic)
        await #expect(throws: (any Error).self) {
            _ = try await NativeClient.updateTool(id: "tool-a", autoRun: false, dataRoot: root)
        }
        #expect(try Data(contentsOf: registry) == corrupt)
    }

    /// Quarantine is a kill switch, so the next registry reader must no longer
    /// find the tool active and the retained body must exist under quarantine.
    @Test func toolQuarantineMovesTheReadableBodyAndRemovesItFromActiveInventory() async throws {
        let root = try tempRoot("tool-quarantine")
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("tools/active/tool-a", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data("print(\"safe\")\n".utf8).write(to: active.appendingPathComponent("tool.swift"))
        try writeJSON([toolRow(activePath: active.path)], to: root.appendingPathComponent("tools/registry.json"))

        let writer = SwiftNativeToolRegistry(root: root)
        let quarantined = try await writer.quarantine(id: "tool-a", reason: "operator requested")
        #expect(quarantined.status == "quarantined")

        let afterRestart = SwiftNativeToolRegistry(root: root)
        #expect(try await afterRestart.listTools(filter: .status("active")).isEmpty)
        let reread = try #require(try await afterRestart.getTool(id: "tool-a"))
        #expect(reread.status == "quarantined")
        let registryJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("tools/registry.json"))
        ) as! [[String: Any]]
        #expect(registryJSON.first?["quarantineReason"] as? String == "operator requested")
        let copied = root.appendingPathComponent("tools/quarantine/tool-a/tool.swift")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "print(\"safe\")\n")
    }

    /// The Approve control must activate only a validated proposal and publish
    /// a runnable registry entry that survives a fresh execution owner.
    @Test func approvedSafeToolBecomesTheFreshExecutorsActiveTool() async throws {
        let root = try tempRoot("tool-approve")
        defer { try? FileManager.default.removeItem(at: root) }
        let execution = SwiftNativeToolExecution(root: root)
        _ = try await execution.createProposal(.object([
            "id": .string("approved-tool"),
            "name": .string("Approved Tool"),
            "permissions": .array([.string("app_data_read")]),
        ]))
        let proposal = root.appendingPathComponent("tools/proposals/approved-tool", isDirectory: true)
        try Data("print(\"{\\\"ok\\\":true}\")\n".utf8).write(to: proposal.appendingPathComponent("tool.swift"))
        try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8).write(to: proposal.appendingPathComponent("tests.json"))

        let validation = try await execution.validateProposal(id: "approved-tool", promote: false)
        #expect(validation.valid)
        #expect(validation.autoPromotable)
        let promoted = try await execution.promote(id: "approved-tool", allowRisky: false)
        #expect(promoted.status == "active")

        let fresh = SwiftNativeToolExecution(root: root)
        let result = try await fresh.runTool(id: "approved-tool", input: .object([:]))
        guard case .object(let envelope) = result else {
            Issue.record("fresh executor did not return an envelope")
            return
        }
        #expect(envelope["status"] == .string("ok"))
        #expect(envelope["toolId"] == .string("approved-tool"))
    }

    /// Install/disable uses the Skills registry state machine rather than a
    /// view-local badge; a new client must see the exact state after each tap.
    @Test func skillInstallAndDisableRoundTripThroughTheCanonicalRegistry() async throws {
        let root = try tempRoot("skill-install")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy-manifest.json")
        let client = SwiftNativeSkillsClient(root: root, legacyManifestPath: legacy)
        _ = try await client.createSkill(body: .object([
            "name": .string("incident-response"),
            "description": .string("Handle a safe incident response"),
            "triggers": .array([.string("incident")]),
            "content": .string("# Incident response\n\nCollect the facts before acting.\n"),
        ]))
        _ = try await client.enableSkill(name: "incident-response")

        let afterInstall = SwiftNativeSkillsClient(root: root, legacyManifestPath: legacy)
        let installedRows = try await afterInstall.listSkills()
        var installed: JSONValue?
        for row in installedRows {
            guard case .object(let object) = row,
                  case .string(let name)? = object["name"],
                  name == "incident-response" else {
                continue
            }
            installed = row
            break
        }
        guard let installed else {
            Issue.record("fresh skill reader lost the installed skill")
            return
        }
        guard case .object(let installedObject) = installed else {
            Issue.record("fresh skill reader returned a non-object row")
            return
        }
        #expect(installedObject["status"] == .string("active"))

        _ = try await afterInstall.disableSkill(name: "incident-response")
        let afterDisable = SwiftNativeSkillsClient(root: root, legacyManifestPath: legacy)
        let disabledRows = try await afterDisable.listSkills()
        var disabled: JSONValue?
        for row in disabledRows {
            guard case .object(let object) = row,
                  case .string(let name)? = object["name"],
                  name == "incident-response" else {
                continue
            }
            disabled = row
            break
        }
        guard let disabled else {
            Issue.record("fresh skill reader lost the disabled skill")
            return
        }
        guard case .object(let disabledObject) = disabled else {
            Issue.record("fresh skill reader returned a non-object row")
            return
        }
        #expect(disabledObject["status"] == .string("disabled"))
    }

    /// Both Settings approval surfaces must resolve the one canonical record;
    /// a duplicate tap cannot turn the same approval into a second decision.
    @Test func approvalDecisionIsDurableAndCannotBeResolvedTwice() async throws {
        let root = try tempRoot("approval-control")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.create(.object([
            "title": .string("Approve safe task"),
            "action": .string("file.write"),
            "risk": .string("medium"),
            "payload": .object(["path": .string("notes.txt")]),
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
        ]))
        let resolved = try await inbox.resolve(
            pending.id,
            decision: .approved,
            provenance: .local(decidedBy: "settings")
        )
        #expect(resolved.status == "resolved")
        #expect(resolved.decision == "approved")
        #expect(resolved.resolutionProvenance == .local(decidedBy: "settings"))

        let afterRestart = SwiftNativeApprovalInbox(root: root)
        let reread = try await afterRestart.get(pending.id)
        #expect(reread.decision == "approved")
        await #expect(throws: (any Error).self) {
            _ = try await afterRestart.resolve(
                pending.id,
                decision: .denied,
                provenance: .local(decidedBy: "settings")
            )
        }
    }

    /// The policy simulator must read the just-persisted Trust policy, not a
    /// default-root or view-local copy. This exercises writer → preview →
    /// actual SecurityCenter evaluation end to end.
    @Test func policySimulatorObservesTheSamePersistedTrustPolicyAsTheGate() async throws {
        let root = try tempRoot("policy-simulator")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await NativeClient.applyTrustPolicyPatch(
            body: [
                "permissionLevel": "full_mac_os",
                "fullMacNeverExpires": true,
                "fullMacExpiresAt": "never",
                "filePolicy": ["outsideWorkspaceDefault": "allow"],
                "toolAutonomy": ["default": "auto", "write_file": "auto"],
            ],
            dataRoot: root
        )
        let preview = try await NativeClient.simulatePolicy(
            action: "file_write", path: root.appendingPathComponent("outside.txt").path, dataRoot: root
        )
        #expect(preview.action == "file_write")
        #expect(preview.allowed)
        #expect(!preview.requiresApproval)
    }

    /// Provider auth-mode and model pickers land in the shared routing store.
    /// A fresh routing owner must observe both settings together.
    @Test func providerAuthAndModelChoicesRoundTripThroughRoutingOwner() async throws {
        let root = try tempRoot("provider-settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        _ = try await routing.configureProvider(
            id: "openrouter",
            config: .object([
                "auth_mode": .string("api_key"),
                "api_key": .string("sk-hermetic-key"),
                "default_model": .string("openai/gpt-5.5"),
            ])
        )
        _ = try await routing.saveModelConfig(.object([
            "surface": .string("chat"),
            "model": .string("gpt-5.5"),
            "reasoning_effort": .string("high"),
            "service_tier": .string("priority"),
        ]))

        let afterRestart = SwiftNativeProviderRouting(dataRoot: root)
        let provider = try await afterRestart.getProvider(id: "openrouter")
        #expect(provider.configured == true)
        let preferences = try await afterRestart.computeModelPreferences()
        guard let preference = preferences["chat"] else {
            Issue.record("fresh provider routing reader lost the chat preference")
            return
        }
        // GPT-5.5 is a persisted legacy selection. The shared routing
        // boundary upgrades it before a fresh owner exposes the preference,
        // so no surface silently downgrades from the current primary model.
        #expect(preference.model == "gpt-5.6-sol")
        #expect(preference.reasoningEffort == "high")
        #expect(preference.serviceTier == "priority")
    }
}
