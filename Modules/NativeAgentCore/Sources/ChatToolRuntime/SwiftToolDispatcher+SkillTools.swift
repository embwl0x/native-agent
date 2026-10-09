import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
import Skills
import ChatTurnContracts

// MARK: - Skill body tools

extension SwiftToolDispatcher {
    private var canonicalSkillBodyDirectories: [URL] {
        [
            dataRoot.appendingPathComponent("skills/bodies", isDirectory: true),
            personaRootForTools().appendingPathComponent("skills/bodies", isDirectory: true),
        ]
    }

    private var skillRegistryURL: URL {
        dataRoot.appendingPathComponent("skills/registry.json")
    }

    private var skillPointerSyncReceiptURL: URL {
        dataRoot.appendingPathComponent("skills/.pointer_sync_receipt.json")
    }

    func impl_list_skills(input: [String: JSONValue]) async throws -> JSONValue {
        let rows = InstalledSkillInventory.list(
            dataRoot: dataRoot,
            sourceRoot: rootForRead,
            personaRoot: personaRootForTools()
        )
        return .array(rows)
    }

    func impl_read_skill(input: [String: JSONValue]) async throws -> JSONValue {
        let name = try requireString(input, "name")
        let entries = try InstalledSkillInventory.entries(
            dataRoot: dataRoot, sourceRoot: rootForRead, personaRoot: personaRootForTools())
        // Exact registered spelling wins; stripping is legacy fallback only.
        // A registered row wins over a built-in of the same name: her version, on or not.
        let registered = entries.filter { $0.row["source"] == .string("runtime_registry") }
        let find = { (handle: String) in
            InstalledSkillInventory.match(handle, in: registered) ?? InstalledSkillInventory.match(handle, in: entries)
        }
        let entry = find(name) ?? (name.hasSuffix(".md") ? find(String(name.dropLast(3))) : nil)
        if entry == nil, name.contains("/") || name.contains("..") || name.hasPrefix(".") {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: invalid skill name '\(name)'")
        }
        guard let url = entry?.bodyURL, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: skill body not found for '\(name)'")
        }
        let violations = SkillBodyHygiene.violations(in: text)
        guard violations.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: skill body hygiene failed for '\(name)': \(SkillBodyHygiene.failureMessage(for: violations))")
        }
        let body: String
        if data.count > Self.maxFileBytes {
            let headText = String(data: data.prefix(Self.maxFileBytes), encoding: .utf8) ?? text
            body = headText + "\n... [truncated, \(data.count) bytes total]"
        } else {
            body = text
        }
        // Bookkeeping failures are reported alongside the usable body.
        func recordUse() async -> JSONValue? {
            if let entry, entry.row["source"] == .string("runtime_registry") {
                do { try await SwiftNativeSkillsClient(root: dataRoot).recordUse(id: entry.id) }
                catch { return .string(error.localizedDescription) }
            }
            return nil
        }
        // A script skill reads with its script: header, source (at most 8 KB),
        // digest, and whether it is on and admitted for that digest; and its
        // current, previous and last clean versions.
        // Her version of a built-in reads as hers, with its status and the way back to the built-in.
        let status = entry?.row["status"] ?? .null
        let word = if case .string(let text) = status, !text.isEmpty { text.lowercased() } else { "draft" }
        let on = entry.map { InstalledSkillInventory.isAvailable($0.row) } ?? false
        let overrides: [String: JSONValue] = entry?.row["overrides"] == .string("built_in") ? [
            "overrides": .string("built_in"),
            "note": .string(on ? "This is your version of a built-in skill; it replaces the built-in for you. "
                + "skill.rollback drops yours and the built-in shows again."
                : "This is your \(word) version of a built-in skill; the built-in is still in use until you enable it."),
        ] : [:]
        guard let row = entry?.row, case .object(var script)? = row["script"] else {
            var result = overrides.merging(["content": .string(body), "status": .string("ok"), "skill_status": status]) { $1 }
            if let row = entry?.row, row["source"] == .string("runtime_registry"), overrides.isEmpty {
                do { result["versions"] = try await SwiftNativeSkillsClient(root: dataRoot).guidanceVersions(row) }
                catch { result["versions_error"] = .string(error.localizedDescription) }
            }
            if let error = await recordUse() { result["usage_error"] = error }
            return .object(result)
        }
        script["digest"] = SkillScript.digest(row["script"]).map(JSONValue.string) ?? .null
        script["status"] = row["status"] ?? .null
        script["runnable"] = .bool(SkillScript.isRunnable(row))
        script["admission"] = row["admission"] ?? .null
        script["params_arrive_as"] = .string("input, frozen (e.g. input.name); args is the same object")
        if let suspended = row["suspended"] { script["suspended"] = suspended }
        let versions = await SwiftNativeSkillsClient(root: dataRoot).scriptVersions(row)
        var result = overrides.merging(["content": .string(body), "status": .string("ok"), "skill_status": status, "script": .object(script),
                                        "versions": versions]) { $1 }
        if let error = await recordUse() { result["usage_error"] = error }
        return .object(result)
    }

    /// Canonical conversational skill writer. This deliberately reuses the
    /// Skills module that owns the Mac UI lifecycle instead of teaching the
    /// model registry paths or file formats.
    /// A `script` makes it repeatable: it lands drafted, with the origin of
    /// who steered this turn, hers or the peers' (`PeerDataTaint.carried`).
    func impl_save_skill(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let name = try requireString(input, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = try requireString(input, "description").trimmingCharacters(in: .whitespacesAndNewlines)
        var content = try requireString(input, "content").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty, !content.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "save_skill requires non-empty name, description, and content"
            )
        }
        // A body that opens with guidance instead of a heading is normalised,
        // not refused (2026-09-11: Agent's glass/material skill was rejected
        // for exactly this and the text was lost). The heading is the name.
        if !content.hasPrefix("#") {
            content = "# \(name)\n\n" + content
        }
        guard content.utf8.count <= 64 * 1024 else {
            throw AutonomyGateError.toolDenied(reason: "save_skill content exceeds 65536 UTF-8 bytes")
        }
        let triggers: [JSONValue]
        if case .array(let values)? = input["triggers"] {
            triggers = values.compactMap { value in
                guard case .string(let raw) = value else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .string(String(trimmed.prefix(160)))
            }
        } else {
            triggers = []
        }

        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        do {
            let saved = try await SwiftNativeSkillsClient(root: dataRoot).createSkill(body: .object([
                "name": .string(name),
                "description": .string(description),
                "triggers": .array(triggers),
                "content": .string(content),
                // Agent-authored skills are immediately discoverable but do
                // not gain any tool, approval, or TrustCenter authority.
                "autoCreated": .bool(true),
                "status": .string("active"),
                "script": input["script"] ?? .null,
            ]), steer: SkillScript.origin(steeredBy: steer.sources + steer.elevated))
            guard case .object(let record) = saved else { return saved }
            var receipt: [String: JSONValue] = [
                "status": .string("saved"),
                "skill": .object(record.filter { !["bodyPath", "script", "admission"].contains($0.key) }),
                "body_verified": .bool(true),
                "loading": .string("lazy; read it with app skill.read only when this skill is relevant"),
                "authority": .string("guidance_only; TrustCenter, approvals, and effect-time validation remain authoritative"),
            ]
            if let entries = try? InstalledSkillInventory.entries(
                dataRoot: dataRoot, sourceRoot: rootForRead, personaRoot: personaRootForTools()),
               InstalledSkillInventory.match(name, in: entries)?.row["overrides"] == .string("built_in") {
                receipt["overrides"] = .string("built_in")
                receipt["note"] = .string(InstalledSkillInventory.isAvailable(record)
                    ? "Saved as your version of the built-in \(name); it replaces the built-in for you. "
                        + "skill.rollback drops yours and the built-in shows again."
                    : "Saved as your draft version of the built-in \(name); the built-in is still in use until you enable it.")
            }
            if let script = record["script"] {
                receipt["script"] = .object([
                    "digest": .string(SkillScript.digest(script) ?? ""),
                    "runnable": .bool(SkillScript.isRunnable(record)),
                    "note": .string(SkillScript.isRunnable(record) ? "unchanged and still on"
                        : "drafted: it runs only once skill.enable turns it on (User's for a peer's or a pack's script, or below Full Mac)"),
                ])
            }
            do {
                let sync = try await memoryV2.syncSkillPointersRecordingReceipt(
                    bodiesDirs: canonicalSkillBodyDirectories,
                    runtimeRegistryURL: skillRegistryURL,
                    receiptURL: skillPointerSyncReceiptURL
                )
                receipt["recall_pointer"] = .string("reconciled")
                receipt["pointer_sync"] = .object([
                    "added": .int(Int64(sync.added)),
                    "updated": .int(Int64(sync.updated)),
                    "removed": .int(Int64(sync.removed)),
                    "unchanged": .int(Int64(sync.unchanged)),
                ])
            } catch {
                // The canonical body and registry row are already committed.
                // Report the partial outcome honestly rather than inviting a
                // duplicate save retry or pretending automatic recall is live.
                receipt["recall_pointer"] = .string("reconciliation_failed")
                receipt["pointer_sync_error"] = .string(
                    String(String(describing: error).prefix(500))
                )
            }
            return .object(receipt)
        } catch let error as SkillsError {
            throw AutonomyGateError.toolDenied(reason: "save_skill failed: \(String(describing: error))")
        }
    }
}
