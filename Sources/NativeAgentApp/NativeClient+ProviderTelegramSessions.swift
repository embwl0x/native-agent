import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import Transcripts
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
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
    func getCompiledPersonality(surface: String) async throws -> CompiledPersonality {
        // Scaffold missing fixed persona docs before compiling so the packet
        // reflects persisted defaults. PersonaEngine requires SOUL.md first,
        // skips USER.md (owned by MemoryV2), and locks each write. Scaffold
        // failures propagate; there are no rollout flags around this read.
        do {
            let writer: any PersonaEngineWriting = dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? makePersonaEngineWriter()
            try await writer.scaffoldMissingDocs()
        }
        return try await swiftCompiledPersonality(surface: surface)
    }

    func getPersonalityDocs() async throws -> PersonalityDocsResponse {
        // Scaffold before listing so content and updatedAt describe persisted
        // defaults. As with compiled reads, PersonaEngine gates on SOUL.md,
        // skips USER.md, locks each write, and propagates scaffold failures.
        do {
            let writer: any PersonaEngineWriting = dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? makePersonaEngineWriter()
            try await writer.scaffoldMissingDocs()
        }
        return try await swiftPersonalityDocs()
    }

    // WAVE 33 W06: write gate. When `.personaEngineWrites` is ON, route the
    // persona doc write through the native
    // `SwiftNativePersonaEngine.savePersonalityDoc` (PersonaEngine+Writes.swift)
    // instead of POST /v1/personality/docs. The native path enforces the SAME
    // onboarding-sentinel gate + 30K cap + atomic write, holds a cross-process
    // flock on the doc file, and returns the identical
    // `{**spec, path, content, updatedAt}` shape.
    //
    // DEDICATED WRITE FLAG (NOT `.personaEngine`): the read gates
    // (getPersonality / getPersonalityDocs) gate on `.personaEngine`, which is
    // already FLAG_FLIPPED / live in production (CUTOVER §6.55 W17). Gating the
    // WRITE path on `.personaEngine` too would make the native write LIVE the
    // instant the read flag is in the user's env — going live while pre-flip prereqs
    // are still OPEN. `.personaEngineWrites` is a SEPARATE default-OFF flag so
    // the write stays genuinely DORMANT until those prereqs close (CUTOVER §6.96):
    //   (1) all-writer flock — the 3 MUTATION writers (`persona_write`,
    //       `persona_append_section`, `append_personality_growth`) now share the
    //       cross-process lock (CLOSED this wave); RESIDUAL unlocked writers
    //       remain (`Runtime.personality()` rewrites profile.json unlocked on
    //       every read; doc auto-scaffold; Swift onboarding writes) — named as a
    //       pre-flip prereq in §6.96, NOT yet closed;
    //   (2) the W33-W03 NFKC persona-write-guard co-requisite (must land on the
    //       same integration branch);
    //   (3) the §6.76 item-B side-effect parity gap (`record_activity` Mac-side
    //       emission for the doc save) — still OPEN.
    // Persona writes now route through the Swift writer directly; unsupported
    // inputs fail closed inside PersonaEngine.
    func savePersonalityDoc(id: String, content: String) async throws -> PersonalityDoc {
        let engine: any PersonaEngineWriting = dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? makePersonaEngineWriter()
        let spec = try await engine.savePersonalityDoc(id: id, content: content)
        return PersonalityDoc(
            id: spec.id,
            title: spec.title,
            filename: spec.filename,
            path: spec.path,
            content: spec.content,
            updatedAt: spec.updatedAt
        )
    }

    func getPrivacyMap() async throws -> PrivacyMap {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return PrivacyMap(
            dataRoot: dataRoot.path,
            categories: Self.privacyCategories(dataRoot: dataRoot),
            generatedAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

    /// Build the Support Snapshot.
    ///
    /// 2026-07-23 B2.6d: `reusing` lets the caller hand in a still-fresh
    /// `DoctorReport` so we DON'T re-run the full offline Doctor pass just to
    /// compute the rollup. The reuse path reproduces the identical offline
    /// rollup by excluding exactly the app-added live-coverage checks (`live.*`)
    /// that `runAll` never produces — so the snapshot content is byte-identical
    /// to a cold run. The export path (and any stale-cache caller) passes
    /// nil → full run.
    func getSupportDiagnostics(reusing report: DoctorReport? = nil) async throws -> SupportDiagnostics {
        let doctorStatus: String
        if let report {
            doctorStatus = Self.supportSnapshotOfflineRollup(report.checks)
        } else {
            let impl = makeDoctorChecks()
            let statuses = try await impl.runAll(repair: false).map(\.status)
            doctorStatus = Self.supportSnapshotRollup(statuses)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return SupportDiagnostics(
            app: "NativeAgent",
            version: version,
            doctorStatus: doctorStatus,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// fail > warn > ok, matching the original inline Support Snapshot rollup.
    static func supportSnapshotRollup(_ statuses: [String]) -> String {
        DoctorStatusProjection.supportSnapshotRollup(statuses)
    }

    /// Rollup for the reuse path. `runDoctor` builds its report as
    /// `runAll(...)` (the offline core pass) PLUS the app's live-coverage
    /// checks (`live.*`). The cold Support Snapshot uses `runAll` alone, so
    /// dropping exactly the `live.*` checks reproduces its rollup byte-for-byte
    /// — the `llm` check is always part of the offline pass, so it must NOT
    /// be excluded here (B2.6d).
    static func supportSnapshotOfflineRollup(_ checks: [CheckResult]) -> String {
        DoctorStatusProjection.supportSnapshotOfflineRollup(checks)
    }

    // Wave 16 (2026-06-01): ChatOrchestration cutover. chat() and chatStream()
    // go straight through SwiftNativeChatOrchestrationClient.
    //
    // CARVES (documented):
    //  * Persona (per-chat pick via UserDefaults["chatPersona"]) is RECORDED on
    //    the persisted assistant turn's metadata.persona for downstream
    //    consolidation, but does NOT change which compiled persona the LLM sees
    //    on this turn. Default-persona users see no regression.
    //  * personaFingerprint hashes the persona documents admitted for the turn.
    //  * contextFingerprint = first-16-hex of sha256(sorted recalledIds join),
    //    nil when empty — opaque comparator, never raw record identity
    //    (packet-provenance 2026-07-11).
    //  * Tool dispatches: SwiftToolDispatcher refuses execution with a clear
    //    "not yet wired" error — the tool loop records the rejection rather
    //    than tearing down the turn (this matches the Swift module's docs).
    //  * If the Swift path throws, we rethrow — do NOT fall back to HTTP
    //    because the daemon is the wedge we're bypassing.

    static func adaptAttachments(_ shared: [NativeAgentShared.MultimodalAttachment]) -> [ChatOrchestration.MultimodalAttachment] {
        return shared.map { ChatOrchestration.MultimodalAttachment(id: $0.id, type: $0.type, base64: $0.base64, mime: $0.mime, name: $0.name, byteSize: $0.byteSize, path: $0.path) }
    }

}
