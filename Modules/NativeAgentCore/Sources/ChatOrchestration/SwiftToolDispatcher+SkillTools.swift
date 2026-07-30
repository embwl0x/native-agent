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
        .array(InstalledSkillInventory.list(
            dataRoot: dataRoot,
            sourceRoot: rootForRead,
            personaRoot: personaRootForTools()
        ))
    }

    func impl_read_skill(input: [String: JSONValue]) async throws -> JSONValue {
        let name = try requireString(input, "name")
        // Accept manifest display names or stable ids, but never a path.
        if name.contains("/") || name.contains("..") || name.hasPrefix(".") {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid skill name '\(name)'"
            )
        }
        var handles = [name]
        let requested = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        let registry = InstalledSkillInventory.list(
            dataRoot: dataRoot,
            sourceRoot: rootForRead,
            personaRoot: personaRootForTools()
        )
        if let match = registry.first(where: { row in
            guard case .object(let object) = row else { return false }
            let rowName: String = if case .string(let value)? = object["name"] { value } else { "" }
            let rowID: String = if case .string(let value)? = object["id"] { value } else { "" }
            return rowName.caseInsensitiveCompare(requested) == .orderedSame
                || rowID.caseInsensitiveCompare(requested) == .orderedSame
        }), case .object(let object) = match,
           case .string(let id)? = object["id"], !id.isEmpty {
            handles.insert(id, at: 0)
        }
        handles = handles.filter {
            !$0.contains("/") && !$0.contains("..") && !$0.hasPrefix(".")
        }
        var seen: Set<String> = []
        let fileNames = handles
            .map { $0.hasSuffix(".md") ? $0 : "\($0).md" }
            .filter { seen.insert($0.lowercased()).inserted }
        let bodyRoots = canonicalSkillBodyDirectories
        for fileName in fileNames {
            for bodyRoot in bodyRoots {
                let resolvedRoot = bodyRoot.standardizedFileURL.resolvingSymlinksInPath()
                let resolvedURL = bodyRoot
                    .appendingPathComponent(fileName)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"),
                      let data = try? Data(contentsOf: resolvedURL),
                      let text = String(data: data, encoding: .utf8) else {
                    continue
                }
                let hygieneViolations = SkillBodyHygiene.violations(in: text)
                if !hygieneViolations.isEmpty {
                    throw AutonomyGateError.toolDenied(
                        reason: "SwiftToolDispatcher: skill body hygiene failed for '\(name)': \(SkillBodyHygiene.failureMessage(for: hygieneViolations))"
                    )
                }
                if data.count > Self.maxFileBytes {
                    let head = data.prefix(Self.maxFileBytes)
                    let headText = String(data: head, encoding: .utf8) ?? text
                    return .string(headText + "\n... [truncated, \(data.count) bytes total]")
                }
                return .string(text)
            }
        }
        throw AutonomyGateError.toolDenied(
            reason: "SwiftToolDispatcher: skill body not found for '\(name)'"
        )
    }

    /// Canonical conversational skill writer. This deliberately reuses the
    /// Skills module that owns the Mac UI lifecycle instead of teaching the
    /// model registry paths or file formats.
    func impl_save_skill(input: [String: JSONValue]) async throws -> JSONValue {
        let name = try requireString(input, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = try requireString(input, "description").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = try requireString(input, "content").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty, !content.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "save_skill requires non-empty name, description, and content"
            )
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
            ]))
            guard case .object(let record) = saved else { return saved }
            var receipt: [String: JSONValue] = [
                "status": .string("saved"),
                "skill": .object(record.filter { $0.key != "bodyPath" }),
                "body_verified": .bool(true),
                "loading": .string("lazy; use read_skill only when this skill is relevant"),
                "authority": .string("guidance_only; TrustCenter, approvals, and effect-time validation remain authoritative"),
            ]
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
