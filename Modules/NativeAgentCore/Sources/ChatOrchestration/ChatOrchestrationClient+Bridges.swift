import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

// MARK: - MacIntegrationToolBridge
//
// 2026-06-07 — Mac integration chat tools are gated by
// MacIntegrationPermissionStore (per-integration READ/WRITE bits the user controls
// from Settings → Mac Integration). The actual EventKit / notification /
// Spotlight backends live in the NativeAgentApp target (MacPIMConnectorActions,
// NativeClient.runMacNotify/.runMobileNotify/.runMacSpotlightSearch) and
// ChatOrchestration can't import them — Foundation/EventKit headers would pull
// the whole app surface into a leaf module.
//
// The app injects a conforming bridge during ChatOrchestrationClient init.
// The dispatch path first asks the permission store, THEN calls the bridge.
// If the bridge is nil (e.g. headless ChatDrive, or app-side init forgot to
// wire it), the tool returns a `bridge_not_wired` error envelope rather than
// throwing — keeping the chat turn intact for the LLM to recover from.
// MARK: - EvolutionToolBridge
//
// 2026-06-11 (U2b) — the three privileged self-evolution chat tools
// (evolution_propose / evolution_status / self_install) manipulate the
// EvolutionProposalStore and stage a self_evolution.apply approval card. The
// store lives in the SelfImprovement module and the stager in the
// NativeAgentApp target; ChatOrchestration is a leaf module that does NOT
// depend on SelfImprovement (verified — adding it would invert the module
// graph). So the seam mirrors MacIntegrationToolBridge: the app injects a
// conforming bridge at SwiftToolDispatcher init time, the dispatch cases
// gate on Full-Mac file_ops_allowed and then forward to the bridge, and a
// nil bridge returns a `bridge_not_wired` envelope (never throws — keep the
// turn intact for the LLM to recover).
//
// These tools do NOT spawn a Process (unlike the builder tools / restart_app):
// they are store mutations + an approval-card stage. self_install only STAGES
// a card a human still approves — it never calls systemRebuild or applies.
public protocol EvolutionToolBridge: Sendable {
    /// File a new evolution proposal into the store. Write.
    func evolutionPropose(input: [String: JSONValue]) async throws -> JSONValue
    /// Read a single proposal or list in-flight proposals. Read-only.
    func evolutionStatus(input: [String: JSONValue]) async throws -> JSONValue
    /// Validate a candidate_green proposal and STAGE its self_evolution.apply
    /// approval card (idempotent). Never installs — a human still approves.
    func evolutionStageInstall(input: [String: JSONValue]) async throws -> JSONValue
}

public protocol MacIntegrationToolBridge: Sendable {
    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue
    func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue
    func macNotify(input: [String: JSONValue]) async throws -> JSONValue
    func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue
    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue

    // ── Phase 2 (2026-06-07): Contacts + Mail + Messages + Notes + Music ──
    // Backends live in MacContactsActions (W1) and MacAppleScriptActions (W2);
    // the app wires a single MacIntegrationBridgeImpl that fans these out.

    /// Search the user's local Contacts (CNContactStore). Read.
    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue
    /// Create a new contact or update an existing one (identifier optional). Write.
    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue

    /// List recent messages from Apple Mail's primary inbox. Read.
    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue
    /// Search Apple Mail across mailboxes. Read.
    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue
    /// Compose and send an email through Apple Mail. Write.
    func mailSend(input: [String: JSONValue]) async throws -> JSONValue

    /// List recent iMessage threads. Read.
    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue
    /// Send an iMessage to a phone or email handle. Write.
    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue

    /// Search Apple Notes by query. Read.
    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue
    /// Create a new Apple Note in an optional folder. Write.
    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue

    /// Report what Apple Music is currently playing. Read.
    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue
    /// Control Apple Music playback (play / pause / toggle / next / previous). Write.
    func musicControl(input: [String: JSONValue]) async throws -> JSONValue

    // ── Phase 3 (2026-06-07): complete read+write coverage on every Mac
    // Integration toggle. the user said "complete complete" — every tab now has
    // both axes wired behind it. Sensitive writes (calendar create / reminders
    // create+complete / mail manage / notes update / contacts delete) stay
    // default-OFF in MacIntegrationPermissionStore per the existing matrix —
    // the user flips them in Settings → Mac Integration before they fire.
    // Scheduler is the one NEW MacIntegrationID surface here: list + create
    // jobs that the TriggerScheduler module already executes. Spec calls
    // both .write because scheduler.supportsRead is false.

    // EventKit writes
    /// Create a new EKEvent in the user's Calendar. Write.
    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue
    /// Modify an existing EKEvent (by EKEvent.eventIdentifier). Write.
    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue
    /// Create a new EKReminder in the user's Reminders. Write.
    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue
    /// Mark an EKReminder complete by EKReminder.calendarItemIdentifier. Write.
    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue

    // Mail manage (AppleScript-backed)
    /// Mark a Mail message read. Write.
    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue
    /// Archive a Mail message. Write.
    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue
    /// Delete a Mail message. Write.
    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue
    /// Reply to a Mail message. Write.
    func mailReply(input: [String: JSONValue]) async throws -> JSONValue

    // Notes update (AppleScript-backed)
    /// Update an existing Apple Note — set body, append, or rename. Write.
    func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue

    // Music library (read)
    /// Search the user's Apple Music library (track/artist/album). Read.
    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue
    /// Page through the user's Apple Music library tracks. Read.
    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue
    /// Page through the user's Apple Music playlists. Read.
    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue

    // Contacts delete
    /// Delete a contact by CNContact.identifier. Write.
    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue

    // Scheduler (NEW MacIntegrationID surface — list + create only, no read axis)
    /// List queued/scheduled TriggerScheduler jobs. Write (no read axis on scheduler).
    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue
    /// Create a new TriggerScheduler job. Write.
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue
}

/// Historical chat spelling for the shared non-digest trace/preview boundary.
/// This contract is deliberately stricter and non-correlatable compared with
/// the digest-bearing durable-receipt redactor.
typealias ChatSecretRedactor = TurnTraceRedactor
