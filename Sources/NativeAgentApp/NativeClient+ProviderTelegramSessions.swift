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

extension NativeClient {
    // Swift-owned Codex device-auth subprocess lifecycle.
    func getCodexDeviceLoginStatus() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.status(codexHome: Self.codexDeviceLoginHome())
    }

    func getLatestContextReceipt(sessionId: String) async throws -> ContextReceipt {
        try await Self.getLatestContextReceipt(
            sessionId: sessionId,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    static func getLatestContextReceipt(
        sessionId: String,
        dataRoot: URL
    ) async throws -> ContextReceipt {
        try await RuntimeReadProjection.getLatestContextReceipt(sessionId: sessionId, dataRoot: dataRoot)
    }

    func verifyCodex() async throws -> CodexCheckResponse {
        try await Self.verifyCodex(dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func verifyCodex(dataRoot: URL) async throws -> CodexCheckResponse {
        try await ProviderReadProjection.verifyCodex(dataRoot: dataRoot)
    }

    func openCodexLoginInBrowser() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.start(codexHome: Self.codexDeviceLoginHome(), openBrowser: true)
    }

    @discardableResult
    func cancelCodexDeviceLogin() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.cancel(codexHome: Self.codexDeviceLoginHome())
    }

    @discardableResult
    func codexDeviceLoginClear() async throws -> CodexDeviceLogin {
        try await Self.codexDeviceLoginManager.clear(codexHome: Self.codexDeviceLoginHome())
    }

    static func codexDeviceLoginHome() -> URL {
        codexDeviceLoginHome(dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func codexDeviceLoginHome(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("codex_home", isDirectory: true)
    }

    func getCompiledPersonality(surface: String) async throws -> CompiledPersonality {
        // WAVE 35 W01 (§6.116 prereq #1): missing-doc default-value
        // PERSISTENCE on the compiled-packet path. The daemon's
        // `compiled_personality_packet`
        // calls `personality_doc_contents(create_missing=True)`, which
        // atomically WRITES the default body for any missing mutable fixed doc
        // once SOUL.md exists — BEFORE reading the file back to build the
        // packet. USER.md is skipped here because MemoryV2 owns it.
        //
        // The Swift `compiledPacket` read path (PersonaEngine+CompiledPacket.swift
        // `readPersonaDocContents`) is pure: a missing doc reads as "",
        // so its fingerprint diverges from the daemon's whenever SOUL.md
        // exists but a sibling doc is absent (documented divergence at
        // PersonaEngine+CompiledPacket.swift L115-124). Wave 34 W05 closed
        // this same gap on the `/v1/personality/docs` path; this mirrors
        // it on `/v1/personality/compiled`.
        //
        // Gate the WRITE on the dedicated `.personaEngineWrites` flag (NOT
        // the read flag `.personaEngine`), exactly as W05 does: a read must
        // never mutate disk while only the read flag is live. Scaffold
        // first, then build the packet, so the fingerprint reflects the
        // just-persisted default body — matching the daemon's
        // write-then-read order. A scaffold IO failure PROPAGATES (not
        // `try?`-swallowed): the daemon's `personality_doc_contents` calls
        // `_atomic_write_text` with no try/except, so a failed write fails
        // the compiled read; mirror that rather than silently returning an
        // in-memory packet over an un-scaffolded disk (which would let the
        // next daemon read scaffold UNLOCKED, the race this closes). When
        // the write flag is OFF the scaffold never runs and the compiled
        // read stays pure (production read-flag-only path unchanged).
        do {
            let writer: any PersonaEngineWriting = dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? makePersonaEngineWriter()
            try await writer.scaffoldMissingDocs()
        }
        return try await swiftCompiledPersonality(surface: surface)
    }

    // Wave 3 fixup: Core now exposes `listPersonaDocSpecs()` returning the
    // wire-shape DTO (id/title/filename/path/content/updatedAt), so the
    // .personaEngine flag covers doc listing too. The NativeClient adapter
    // (`swiftPersonalityDocs`) is a trivial field-for-field map from
    // PersonaDocSpec to NativeAgentShared.PersonalityDoc.
    func getPersonalityDocs() async throws -> PersonalityDocsResponse {
        // WAVE 34 W05: missing-doc default-value PERSISTENCE. The daemon's
        // `personality_docs()` calls `personality_doc_contents(create_missing=True)`,
        // which atomically WRITES the default body for any missing mutable fixed
        // doc once SOUL.md exists. USER.md is skipped because MemoryV2 owns it.
        // The Swift READ path only renders those defaults in-memory
        // (updatedAt nil) and never persists — so a
        // flipped write subsystem would leave the next DAEMON read to
        // scaffold them UNLOCKED, reopening the split-writer race. Mirror
        // the daemon's scaffold-on-read here, but gate the WRITE on the
        // dedicated `.personaEngineWrites` flag so it stays DORMANT on the
        // production read flag `.personaEngine` (a read must never mutate
        // disk while only the read flag is live). Scaffold first, then list,
        // so the returned `updatedAt` reflects the just-persisted file —
        // matching the daemon's read-then-stat order. A scaffold IO failure
        // PROPAGATES (not `try?`-swallowed): the daemon's
        // `personality_doc_contents` calls `_atomic_write_text` with no
        // try/except, so a failed write fails the `/v1/personality/docs`
        // read — we mirror that exactly rather than silently returning
        // in-memory defaults while leaving the disk un-scaffolded (which
        // would let the next daemon read scaffold UNLOCKED, the very race
        // this closes). When the write flag is OFF, the scaffold never runs
        // and the read is pure (production read-flag-only path unchanged).
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

    func getPrivacyMap(includeInventory: Bool = true) async throws -> PrivacyMap {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return PrivacyMap(
            dataRoot: dataRoot.path,
            categories: Self.privacyCategories(
                dataRoot: dataRoot,
                includeInventory: includeInventory
            ),
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
            let statuses = try await impl.runAll(repair: false, checkLLM: false).map(\.status)
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
    /// — NOTE the core `runAll` ignores its `checkLLM` flag (the `llm` check is
    /// always part of the offline pass), so it must NOT be excluded here (B2.6d).
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
    //  * personaFingerprint = first-16-hex of sha256(profile.name|profile.personaKind).
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
