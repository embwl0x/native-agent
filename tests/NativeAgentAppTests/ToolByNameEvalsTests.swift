import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

// ─────────────────────────────────────────────────────────────────────────────
// ToolByName evals (wave B, fence tools.byname, 2026-08-23)
//
// Every test drives the REAL SwiftToolDispatcher.dispatch through the same
// switch the chat turn uses, against a hermetic data root, and asserts the
// envelope/throw that actually reaches the caller. The pinned shapes were
// captured from a live probe run of all 95 keeper-baseline `tool:` entries
// (not assumed from source), so these tests bite when:
//   - a fail-closed gate (canonical-body, lazy catalog, permission store,
//     bridge wiring) silently opens or its refusal envelope drifts into
//     something a model would read as success;
//   - a non-throwing connector impl (gmail/notion/calendar/agentmail) starts
//     returning an empty-success object instead of its polite failure
//     envelope;
//   - a throwing impl (github_*, desk validation, skill lookup) starts
//     swallowing its throw into a fabricated success.
//
// No test here touches the live data root, the network, or process-global
// credentials: dispatchers are constructed with allowProcessGlobalTools: false
// so the canonical-body-only tools fail closed by design.
// ─────────────────────────────────────────────────────────────────────────────

private func makeHermeticRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("toolbyname-evals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Each direct dispatch in this file represents one canonical chat call. The
/// real lazy-tool gate requires both that session identity and a loadout in
/// the dispatcher's exact ActiveToolsStore; without them, broad envelope evals
/// stop at `missing_session_id` or `not_loaded` before reaching their named
/// connector/validation/bridge contract.
private struct ToolByNameAuthorizedDispatcher {
    let dispatcher: SwiftToolDispatcher
    let sessionID: String

    init(root: URL) {
        dispatcher = SwiftToolDispatcher(
            dataRoot: root,
            allowProcessGlobalTools: false,
            agentBridgeConfigRoot: root.appendingPathComponent("agent-bridge-config", isDirectory: true)
        )
        sessionID = "toolbyname-evals-\(UUID().uuidString)"
    }

    func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        // Normal calls carry the canonical session exactly as chat does. A
        // test that intentionally supplies a malformed target session (the
        // scratchpad traversal case) retains that field for the handler, but
        // gets the canonical session in the dispatch-only slot so it can
        // reach that handler's own validation boundary.
        var authorizedInput = input
        if input["session_id"] == nil && input["sessionId"] == nil {
            authorizedInput["session_id"] = .string(sessionID)
        } else {
            authorizedInput["__session_id"] = .string(sessionID)
        }
        _ = try await dispatcher.activeToolsStore.addLoaded(
            sessionId: sessionID,
            names: Set([tool])
        )
        return try await dispatcher.dispatch(tool: tool, input: authorizedInput, surface: surface)
    }
}

private func makeDispatcher(root: URL) -> ToolByNameAuthorizedDispatcher {
    ToolByNameAuthorizedDispatcher(root: root)
}

private func asObject(_ value: JSONValue, tool: String) -> [String: JSONValue]? {
    guard case .object(let object) = value else {
        Issue.record("\(tool) returned a non-object envelope: \(value)")
        return nil
    }
    return object
}

private func stringValue(_ value: JSONValue?) -> String? {
    if case .string(let s)? = value { return s }
    return nil
}

// All ToolByName suites are nested under one .serialized parent so at most
// one of these dispatcher-driving tests runs at a time: each spins a real
// SwiftToolDispatcher with synchronous file I/O, and 17 at once measurably
// starves timing-sensitive neighbor tests in this target.
@Suite(.serialized) struct ToolByNameEvals {

@Suite("ToolByName: canonical-body fail-closed gate")
struct ToolByNameCanonicalBodyEvals {
    /// Tools whose real impls reach process-global credentials/app lifecycle.
    /// On a synthetic body (allowProcessGlobalTools: false) each MUST fail
    /// closed before its impl runs. If a name silently falls out of
    /// `canonicalBodyOnlyToolNames`, a test/alternate body would reach the
    /// user's real X/Slack/market credentials.
    @Test func canonicalBodyToolsFailClosedOnSyntheticRoots() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let gated = [
            "market_status", "market_watchlists", "market_quote", "tradingview_watchlist",
            "x_search", "x_timeline", "x_user_tweets",
            "slack_status", "slack_list_channels", "slack_search_messages", "slack_post_message",
        ]
        for tool in gated {
            let result = try await dispatcher.dispatch(tool: tool, input: [:], surface: "chat")
            guard let object = asObject(result, tool: tool) else { continue }
            #expect(object["status"] == .string("failed"), "\(tool) must fail closed")
            #expect(object["reason"] == .string("canonical_body_unavailable"), "\(tool) wrong reason")
            #expect(object["tool"] == .string(tool), "\(tool) must echo its own name")
        }
        // Negative control: the gate is per-name, not a blanket kill switch —
        // an ungated hermetic tool still succeeds on the same dispatcher.
        let control = try await dispatcher.dispatch(tool: "desk_read", input: [:], surface: "chat")
        guard let controlObject = asObject(control, tool: "desk_read") else { return }
        #expect(controlObject["status"] == .string("ok"))
    }
}

@Suite("ToolByName: cloud connectors fail closed, never fabricate")
struct ToolByNameCloudConnectorEvals {
    /// These impls are NON-throwing (`await impl_...`, no `try`): every
    /// internal error is flattened into a polite {status: failed} envelope.
    /// The eval pins that a disconnected hermetic root yields the explicit
    /// not_connected failure — not an empty success a model would read as
    /// "no mail / no events / no pages".
    @Test func disconnectedConnectorsReturnExplicitNotConnected() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let expectations: [(tool: String, connector: String)] = [
            ("gmail_status", "gmail"),
            ("gmail_search", "gmail"),
            ("google_calendar_status", "calendar"),
            ("google_calendar_list", "calendar"),
            ("notion_status", "notion"),
            ("notion_search", "notion"),
        ]
        for expectation in expectations {
            let result = try await dispatcher.dispatch(tool: expectation.tool, input: [:], surface: "chat")
            guard let object = asObject(result, tool: expectation.tool) else { continue }
            #expect(object["status"] == .string("failed"), "\(expectation.tool) must not fabricate success")
            #expect(object["error"] == .string("not_connected"), "\(expectation.tool) wrong error code")
            #expect(object["connector"] == .string(expectation.connector))
            #expect((stringValue(object["detail"]) ?? "").isEmpty == false, "\(expectation.tool) must carry a fix hint")
        }
    }

    /// Input validation precedes the connection check and stays a polite
    /// envelope too (same swallowed-throw lane).
    @Test func connectorReadsValidateInputBeforeConnection() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        for tool in ["gmail_read", "notion_read_page"] {
            let result = try await dispatcher.dispatch(tool: tool, input: [:], surface: "chat")
            guard let object = asObject(result, tool: tool) else { continue }
            #expect(object["status"] == .string("failed"))
            #expect(object["error"] == .string("invalid_input"), "\(tool) must refuse a missing id explicitly")
        }
    }
}

@Suite("ToolByName: GitHub tools throw, never polite-succeed")
struct ToolByNameGitHubEvals {
    /// All 17 github_* chat tools route through GitHubConnectorActions, which
    /// THROWS typed errors (invalidInput / harness refusal) instead of
    /// returning envelopes. The eval pins that a hermetic, unconfigured call
    /// always surfaces as a thrown error to the tool loop — if the dispatch
    /// case ever started swallowing the throw into an empty success, the
    /// model would treat "no repos / no issues / no notifications" as truth.
    @Test func githubToolsThrowOnHermeticUnconfiguredCalls() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let tools = [
            "github_status", "github_list_repos", "github_list_notifications",
            "github_get_repository", "github_read_repository_content", "github_list_commits",
            "github_list_issues", "github_search", "github_list_pull_requests",
            "github_get_issue", "github_get_pull_request", "github_pull_request_files",
            "github_pull_request_activity", "github_discover_tracking", "github_project_digest",
            "github_mutate", "github_set_repo_visibility",
        ]
        for tool in tools {
            do {
                let result = try await dispatcher.dispatch(tool: tool, input: [:], surface: "chat")
                Issue.record("\(tool) returned \(result) instead of throwing on a hermetic unconfigured call")
            } catch {
                // Expected: typed GitHubConnector error reaches the caller.
            }
        }
    }
}

@Suite("ToolByName: Mac integration tools can never silently succeed unwired")
struct ToolByNameMacIntegrationEvals {
    /// Every Mac-integration tool routes through dispatchMacIntegrationTool:
    /// permission gate first (MacIntegrationPermissionStore), then the
    /// app-injected bridge. Headless dispatchers have NO bridge, so a call
    /// must come back as one of exactly two refusal envelopes — a permission
    /// denial or bridge_not_wired — each carrying a user-actionable fix.
    /// (Which of the two depends on the host permission store; write-sensitive
    /// integrations default OFF.) The eval bites if the deny envelope drifts
    /// into a success shape or a nil bridge stops being surfaced.
    @Test func unwiredIntegrationToolsReturnRefusalEnvelopes() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let tools = [
            "mac_calendar_list_upcoming", "mac_calendar_create_event", "mac_calendar_modify_event",
            "mac_reminders_list_due_today", "mac_reminders_create", "mac_reminders_complete",
            "mac_notify", "mobile_notify", "mac_spotlight_search",
            "contacts_search", "contacts_create_or_update", "contacts_delete",
            "mail_list_recent", "mail_search", "mail_send", "mail_mark_read",
            "mail_archive", "mail_delete", "mail_reply",
            "messages_recent_threads", "messages_send",
            "notes_search", "notes_create", "notes_update",
            "music_now_playing", "music_control", "music_search_library",
            "music_list_library", "music_list_playlists",
            "scheduler_list_jobs", "scheduler_create_job",
        ]
        let allowedStatuses: Set<String> = ["denied", "failed"]
        let allowedReasons: Set<String> = ["integration_permission_denied", "bridge_not_wired"]
        for tool in tools {
            let result = try await dispatcher.dispatch(tool: tool, input: [:], surface: "chat")
            guard let object = asObject(result, tool: tool) else { continue }
            let status = stringValue(object["status"]) ?? "<missing>"
            let reason = stringValue(object["reason"]) ?? "<missing>"
            #expect(allowedStatuses.contains(status), "\(tool) returned status \(status) — silent success with no bridge")
            #expect(allowedReasons.contains(reason), "\(tool) returned reason \(reason) — refusal envelope drifted")
            #expect((stringValue(object["fix"]) ?? "").isEmpty == false, "\(tool) refusal lost its fix hint")
            #expect((stringValue(object["integration"]) ?? "").isEmpty == false, "\(tool) refusal lost its integration id")
        }
    }
}

@Suite("ToolByName: required-argument validation throws through dispatch")
struct ToolByNameValidationEvals {
    /// Each of these tools throws AutonomyGateError.toolDenied when its
    /// required argument is missing. The throw IS the failure contract the
    /// tool loop records; a regression that converts it to an empty success
    /// would fabricate desk mutations, ledger posts, skill saves, or search
    /// results out of thin air. `scratchpad_read` intentionally is not here:
    /// the shared fixture supplies its canonical required session, and its
    /// explicit empty-read/traversal contracts are exercised below.
    @Test func missingRequiredArgumentsThrow() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let tools = [
            "desk_add_item", "desk_add_ref", "desk_blocked_on", "desk_breakdown",
            "desk_open_pursuit", "desk_set_cadence", "desk_set_notify",
            "desk_set_status", "desk_update_item", "desk_work_log",
            "task_ledger_post", "workshop_submit",
            "read_skill", "save_skill",
            "search_kg", "search_chat_history", "session_search",
        ]
        for tool in tools {
            do {
                let result = try await dispatcher.dispatch(tool: tool, input: [:], surface: "chat")
                Issue.record("\(tool) returned \(result) instead of throwing on missing required input")
            } catch {
                // Expected: validation throw reaches the caller.
            }
        }
    }
}

@Suite("ToolByName: desk lifecycle against the real store")
struct ToolByNameDeskEvals {
    @Test func deskAddReadMutateRoundtrip() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)

        // Empty desk still renders an honest projection (silent-empty shape).
        let empty = try await dispatcher.dispatch(tool: "desk_read", input: [:], surface: "chat")
        guard let emptyObject = asObject(empty, tool: "desk_read") else { return }
        #expect(emptyObject["status"] == .string("ok"))
        #expect((stringValue(emptyObject["projection"]) ?? "").contains("desk"))

        // Create → the success shape carries a real handle + alias.
        let created = try await dispatcher.dispatch(
            tool: "desk_add_item",
            input: [
                "kind": .string("plan"),
                "project": .string("toolbyname-eval"),
                "title": .string("ToolByName eval fixture item"),
            ],
            surface: "chat"
        )
        guard let createdObject = asObject(created, tool: "desk_add_item") else { return }
        #expect(createdObject["status"] == .string("ok"))
        let handle = stringValue(createdObject["handle"]) ?? ""
        #expect(handle.hasPrefix("desk_"), "desk_add_item must mint a desk_ handle, got '\(handle)'")
        #expect((stringValue(createdObject["alias"]) ?? "").isEmpty == false)

        // The write is visible through the read projection (state actually
        // reached the store, not just the envelope).
        let after = try await dispatcher.dispatch(tool: "desk_read", input: [:], surface: "chat")
        guard let afterObject = asObject(after, tool: "desk_read") else { return }
        #expect((stringValue(afterObject["projection"]) ?? "").contains("ToolByName eval fixture item"))

        // Mutations on the real handle succeed with confirmation envelopes.
        let statusSet = try await dispatcher.dispatch(
            tool: "desk_set_status",
            input: ["handle": .string(handle), "status": .string("now")],
            surface: "chat"
        )
        guard let statusObject = asObject(statusSet, tool: "desk_set_status") else { return }
        #expect(statusObject["status"] == .string("ok"))

        // desk_work_log is pursuit-only: on a plan item the DeskError is
        // caught into an HONEST {status: refused, reason} envelope — pin that
        // polite-refusal lane (a swallowed DeskError returning ok would
        // fabricate work receipts on non-pursuits).
        let logged = try await dispatcher.dispatch(
            tool: "desk_work_log",
            input: ["handle": .string(handle), "receipt": .string("eval receipt")],
            surface: "chat"
        )
        guard let loggedObject = asObject(logged, tool: "desk_work_log") else { return }
        #expect(loggedObject["status"] == .string("refused"))
        #expect((stringValue(loggedObject["reason"]) ?? "").isEmpty == false)

        // Unknown alias must throw, never silently mutate nothing.
        do {
            let bogus = try await dispatcher.dispatch(
                tool: "desk_set_status",
                input: ["handle": .string("999"), "status": .string("done")],
                surface: "chat"
            )
            Issue.record("desk_set_status on unknown alias returned \(bogus) instead of throwing")
        } catch {
            // Expected.
        }
    }
}

@Suite("ToolByName: task ledger lifecycle against the real store")
struct ToolByNameTaskLedgerEvals {
    @Test func taskLedgerPostThenListRoundtrip() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)

        // Empty ledger reads as an explicit ok+empty (silent-empty shape).
        let empty = try await dispatcher.dispatch(tool: "task_ledger_list", input: [:], surface: "chat")
        guard let emptyObject = asObject(empty, tool: "task_ledger_list") else { return }
        #expect(emptyObject["status"] == .string("ok"))
        #expect(emptyObject["tasks"] == .array([]))

        // Unknown kind throws (validation reaches the caller).
        do {
            _ = try await dispatcher.dispatch(
                tool: "task_ledger_post",
                input: ["kind": .string("definitely_not_a_kind")],
                surface: "chat"
            )
            Issue.record("task_ledger_post accepted an unknown kind")
        } catch {}

        // created → ok envelope minting a task id.
        let posted = try await dispatcher.dispatch(
            tool: "task_ledger_post",
            input: ["kind": .string("created"), "title": .string("ToolByName ledger fixture")],
            surface: "chat"
        )
        guard let postedObject = asObject(posted, tool: "task_ledger_post") else { return }
        #expect(postedObject["status"] == .string("ok"))
        let taskId = stringValue(postedObject["task_id"]) ?? ""
        #expect(!taskId.isEmpty)

        // The event is visible through the list read.
        let listed = try await dispatcher.dispatch(
            tool: "task_ledger_list",
            input: ["task_id": .string(taskId)],
            surface: "chat"
        )
        guard let listedObject = asObject(listed, tool: "task_ledger_list") else { return }
        #expect(listedObject["status"] == .string("ok"))

        // Unknown id is an explicit not_found envelope, not an empty success.
        let missing = try await dispatcher.dispatch(
            tool: "task_ledger_list",
            input: ["task_id": .string("no-such-task-id")],
            surface: "chat"
        )
        guard let missingObject = asObject(missing, tool: "task_ledger_list") else { return }
        #expect(missingObject["status"] == .string("not_found"))
    }
}

@Suite("ToolByName: skills save/read roundtrip")
struct ToolByNameSkillEvals {
    @Test func saveSkillThenReadSkillRoundtrip() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)

        // Unknown skill must throw "skill body not found" — an empty-string
        // success here would feed the model a blank skill silently.
        do {
            let result = try await dispatcher.dispatch(
                tool: "read_skill",
                input: ["name": .string("toolbyname-no-such-skill")],
                surface: "chat"
            )
            Issue.record("read_skill returned \(result) for a missing skill instead of throwing")
        } catch {}

        // Skill bodies must open with a markdown heading (SkillBodyHygiene).
        let marker = "Hermetic ToolByName eval skill body marker HTBN-1."
        let body = "# ToolByName eval skill\n\n\(marker)\n"
        let saved = try await dispatcher.dispatch(
            tool: "save_skill",
            input: [
                "name": .string("toolbyname-eval-skill"),
                "description": .string("Fixture skill for the ToolByName eval roundtrip."),
                "content": .string(body),
            ],
            surface: "chat"
        )
        guard let savedObject = asObject(saved, tool: "save_skill") else { return }
        #expect(savedObject["status"] == .string("saved"))

        let read = try await dispatcher.dispatch(
            tool: "read_skill",
            input: ["name": .string("toolbyname-eval-skill")],
            surface: "chat"
        )
        guard case .string(let body) = read else {
            Issue.record("read_skill returned a non-string body: \(read)")
            return
        }
        #expect(body.contains(marker), "read_skill must return the saved body")
    }
}

@Suite("ToolByName: hermetic read tools report honest empties")
struct ToolByNameHermeticReadEvals {
    /// The silent-zero lane: on a fresh root each of these read tools must
    /// come back status-ok with an EXPLICIT empty (count 0 / found:false /
    /// hits []) — the eval pins the shape so an error-path regression that
    /// starts returning the same empty on a POPULATED store still has a
    /// contract to violate (and the roundtrip suites above prove the
    /// populated side).
    @Test func chatHistorySearchReportsZeroHitsHonestly() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        for tool in ["search_chat_history", "session_search"] {
            let result = try await dispatcher.dispatch(
                tool: tool,
                input: ["query": .string("toolbyname-eval-needle")],
                surface: "chat"
            )
            guard let object = asObject(result, tool: tool) else { continue }
            #expect(object["status"] == .string("ok"))
            #expect(object["tool"] == .string(tool), "\(tool) must echo the invoked alias")
            #expect(object["hit_count"] == .int(0))
            #expect(object["hits"] == .array([]))
        }
    }

    @Test func knowledgeGraphSearchReturnsResultsArray() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let result = try await dispatcher.dispatch(
            tool: "search_kg",
            input: ["query": .string("toolbyname-eval-needle")],
            surface: "chat"
        )
        guard let object = asObject(result, tool: "search_kg") else { return }
        #expect(object["results"] == .array([]), "empty graph must yield an explicit empty results array")
    }

    @Test func scratchpadReadReportsFoundFalseAndRejectsTraversal() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let result = try await dispatcher.dispatch(
            tool: "scratchpad_read",
            input: [:],
            surface: "chat"
        )
        guard let object = asObject(result, tool: "scratchpad_read") else { return }
        #expect(object["status"] == .string("ok"))
        #expect(object["found"] == .bool(false))
        #expect(object["keys"] == .array([]))

        // Path-traversal session ids must throw, not read outside the root.
        do {
            let escaped = try await dispatcher.dispatch(
                tool: "scratchpad_read",
                input: ["session_id": .string("../escape")],
                surface: "chat"
            )
            Issue.record("scratchpad_read accepted a traversal session_id: \(escaped)")
        } catch {}
    }

    @Test func traceSummaryReportsExplicitZero() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let result = try await dispatcher.dispatch(tool: "recent_trace_summary", input: [:], surface: "chat")
        guard let object = asObject(result, tool: "recent_trace_summary") else { return }
        #expect(object["status"] == .string("ok"))
        #expect(object["count"] == .int(0))
        #expect(object["traces"] == .array([]))
    }

    @Test func statusProjectionToolsReturnTheirContractShapes() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)

        let lookup = try await dispatcher.dispatch(tool: "context_lookup", input: [:], surface: "chat")
        guard let lookupObject = asObject(lookup, tool: "context_lookup") else { return }
        #expect(lookupObject["status"] == .string("ready"))
        guard case .array? = lookupObject["features"] else {
            Issue.record("context_lookup lost its features array: \(lookup)")
            return
        }

        let delegation = try await dispatcher.dispatch(tool: "delegation_status", input: [:], surface: "chat")
        guard let delegationObject = asObject(delegation, tool: "delegation_status") else { return }
        #expect(delegationObject["status"] == .string("ok"))
        #expect(delegationObject["count"] == .int(0))
        #expect(delegationObject["open_count"] == .int(0))

        let workshop = try await dispatcher.dispatch(tool: "workshop_status", input: [:], surface: "chat")
        guard let workshopObject = asObject(workshop, tool: "workshop_status") else { return }
        #expect(workshopObject["status"] == .string("ok"))
        #expect(workshopObject["active"] == .array([]))
        #expect(workshopObject["recent"] == .array([]))
    }
}

@Suite("ToolByName: staged/bridged sends refuse honestly")
struct ToolByNameSendPathEvals {
    /// workshop_submit routes unknown procedures to an explicit refusal that
    /// names the supported set — before any run is admitted to the store.
    @Test func workshopSubmitRefusesUnsupportedProcedure() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let result = try await dispatcher.dispatch(
            tool: "workshop_submit",
            input: ["text": .string("eval"), "procedure": .string("bogus_procedure_v9")],
            surface: "chat"
        )
        guard let object = asObject(result, tool: "workshop_submit") else { return }
        #expect(object["status"] == .string("failed"))
        #expect((stringValue(object["reason"]) ?? "").contains("unsupported Workshop procedure"))
        #expect(object["supported_procedures"] == .array([.string("local_file_copy_v1")]))
    }

    /// omp_message validates before touching any bridge config: an empty text
    /// is an explicit missing_text envelope, never a queued no-op.
    @Test func ompMessageRefusesEmptyText() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        let result = try await dispatcher.dispatch(tool: "omp_message", input: [:], surface: "chat")
        guard let object = asObject(result, tool: "omp_message") else { return }
        #expect(object["status"] == .string("failed"))
        #expect(object["reason"] == .string("missing_text"))
    }

    /// AgentMail impls are non-throwing: with no data/secrets config the
    /// whole family must surface agentmail_not_configured — an empty inbox
    /// success here would silently hide a broken mailbox forever.
    @Test func agentMailFamilySurfacesNotConfigured() async throws {
        let root = try makeHermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = makeDispatcher(root: root)
        for tool in ["agentmail_list", "agentmail_read", "agentmail_send"] {
            let result = try await dispatcher.dispatch(tool: tool, input: [:], surface: "chat")
            guard let object = asObject(result, tool: tool) else { continue }
            #expect(
                object["error"] == .string("agentmail_not_configured"),
                "\(tool) must name the missing config, got \(result)"
            )
        }
    }
}

}
