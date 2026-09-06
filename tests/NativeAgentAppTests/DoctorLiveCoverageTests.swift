import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Doctor live coverage")
struct DoctorLiveCoverageTests {
    @Test("optional disabled systems are covered without false failure")
    func disabledOptionalSystemsAreHealthy() {
        let telegram = TelegramStatus(
            enabled: false,
            tokenConfigured: false,
            allowedChatIds: [],
            allowedUserIds: [],
            requireMention: false,
            model: nil,
            reasoningEffort: nil,
            pollerEnabled: false,
            lastSeenUpdateId: nil,
            lastSeenAt: nil,
            lastReplyAt: nil,
            lastError: nil,
            pollBackoffFailures: nil,
            lastPollAt: nil,
            voiceTranscription: nil,
            receipts: [],
            blocked: [],
            errors: []
        )
        let autonomy = AutonomyKernelSummary(
            status: "disabled",
            mode: "supervised",
            enabled: false,
            processEnabled: true,
            trustEnabled: false,
            disabledReason: "Trust Center autonomy is disabled",
            guardrails: [],
            approvalClasses: [],
            runningImprovements: 0,
            createdAt: nil
        )

        #expect(NativeClient.telegramDoctorCoverageCheck(telegram).status == "ok")
        #expect(NativeClient.searchDoctorCoverageCheck("").status == "ok")
        #expect(NativeClient.autonomyDoctorCoverageCheck(autonomy).status == "ok")
        #expect(NativeClient.toolsDoctorCoverageCheck([]).status == "ok")
    }

    @Test("enabled but broken systems cannot contribute global OK")
    func brokenEnabledSystemsAreVisible() {
        var telegram = TelegramStatus(
            enabled: true,
            tokenConfigured: false,
            allowedChatIds: [],
            allowedUserIds: [],
            requireMention: false,
            model: nil,
            reasoningEffort: nil,
            pollerEnabled: false,
            lastSeenUpdateId: nil,
            lastSeenAt: nil,
            lastReplyAt: nil,
            lastError: nil,
            pollBackoffFailures: nil,
            lastPollAt: nil,
            voiceTranscription: nil,
            receipts: [],
            blocked: [],
            errors: []
        )
        #expect(NativeClient.telegramDoctorCoverageCheck(telegram).status == "fail")
        telegram.tokenConfigured = true
        let telegramToken = "123456789:AAEabcdefghijklmnopqrstuvwxyz_123456789"
        telegram.lastError = "https://api.telegram.org/bot\(telegramToken)/getUpdates failed under /Users/private-owner/NativeAgent "
            + String(repeating: "x", count: 400)
        let telegramError = NativeClient.telegramDoctorCoverageCheck(telegram)
        #expect(telegramError.status == "warn")
        #expect(telegramError.detail.count < 300)
        #expect(!telegramError.detail.contains(telegramToken))
        #expect(!telegramError.detail.contains("private-owner"))
        #expect(NativeClient.searchDoctorCoverageCheck("not a URL").status == "fail")
    }

    /// FIX-5c (2026-09-01): `live.search` is a URL-SYNTAX check wearing the
    /// name "Search" — Doctor makes no request — and `live.tools` returned
    /// "ok" on every non-throwing path. Neither may render green for
    /// something it did not verify.
    @Test("unprobed and degraded live subsystems never render as verified")
    func unverifiedLiveSubsystemsAreNotGreen() {
        let search = NativeClient.searchDoctorCoverageCheck("https://searx.example/search")
        #expect(search.status == "warn")
        #expect(search.detail.contains("syntax only, no request made"))

        let record = { (name: String, status: String?) in
            ToolRecord(
                id: name, name: name, description: "", triggers: [],
                language: nil, entrypoint: nil, permissions: nil, status: status,
                phase: nil, autoCreated: nil, autoPromote: nil, autoRun: nil,
                autoPromotable: nil, validationStatus: nil, validationErrors: nil,
                proposalPath: nil, activePath: nil, quarantinePath: nil,
                quarantineReason: nil, sourceRunId: nil, createdAt: nil,
                updatedAt: nil, useCount: nil, lastUsedAt: nil
            )
        }
        // Every path says what was actually verified: the registry file read.
        #expect(NativeClient.toolsDoctorCoverageCheck([]).detail.contains("invoked no tool"))

        let allActive = NativeClient.toolsDoctorCoverageCheck([record("a", "active"), record("b", nil)])
        #expect(allActive.status == "ok")
        #expect(allActive.detail.contains("2 active"))
        #expect(allActive.detail.contains("invoked no tool"))

        // A pending proposal is the self-building lane working, not a finding.
        let proposed = NativeClient.toolsDoctorCoverageCheck([record("a", "active"), record("draft", "proposed")])
        #expect(proposed.status == "ok")

        // A registry holding a quarantined tool used to read identically to a
        // clean one.
        let degraded = NativeClient.toolsDoctorCoverageCheck([record("a", "active"), record("broken", "quarantined")])
        #expect(degraded.status == "warn")
        #expect(degraded.detail.contains("1 quarantined: broken"))
    }

    @Test("a single poll interruption is not reported as a Telegram outage")
    func transientTelegramPollFailureDoesNotWarn() {
        var telegram = TelegramStatus(
            enabled: true,
            tokenConfigured: true,
            allowedChatIds: [],
            allowedUserIds: [],
            requireMention: false,
            model: nil,
            reasoningEffort: nil,
            pollerEnabled: true,
            lastSeenUpdateId: 42,
            lastSeenAt: "2026-07-27T23:00:00Z",
            lastReplyAt: "2026-07-27T23:00:01Z",
            lastError: "poll: unavailable",
            pollBackoffFailures: 1,
            lastPollAt: "2026-07-27T23:00:02Z",
            voiceTranscription: nil,
            receipts: [],
            blocked: [],
            errors: []
        )

        let transient = NativeClient.telegramDoctorCoverageCheck(telegram)
        #expect(transient.status == "ok")
        #expect(transient.detail.contains("retrying"))
        #expect(telegram.isOperational)
        #expect(telegram.actionableError == nil)

        telegram.pollBackoffFailures = 3
        #expect(!telegram.isOperational)
        #expect(telegram.actionableError == "poll: unavailable")
        #expect(NativeClient.telegramDoctorCoverageCheck(telegram).status == "warn")
    }

    @Test("live Doctor reconciliation clears a recovered stale warning")
    func liveDoctorReconciliationClearsRecoveredWarning() {
        let stale = DoctorReport(
            status: "warn",
            repaired: false,
            checks: [
                DoctorCheck(id: "storage", title: "Storage", status: "ok", detail: "healthy", repair: nil),
                DoctorCheck(
                    id: "live.telegram", title: "Telegram", status: "warn",
                    detail: "poll: unavailable", repair: nil
                ),
            ]
        )
        let recovered = DoctorCheck(
            id: "live.telegram", title: "Telegram", status: "ok",
            detail: "Telegram is configured and its poller is active.", repair: nil
        )

        let merged = NativeClient.mergeDoctorReport(stale, liveChecks: [recovered])
        #expect(merged.status == "ok")
        #expect(merged.checks.filter { $0.id == "live.telegram" }.count == 1)
        #expect(merged.checks.first { $0.id == "live.telegram" }?.status == "ok")
    }

    @Test("provider coverage requires at least one ready auth path")
    func providerReadinessIsAggregated() throws {
        let unreadyJSON = Data("""
        [{"provider_id":"p1","display_name":"P1","auth_modes":["oauth"],"auth_status":{"provider_id":"p1","state":"needs_oauth","detail":""},"models":[]}]
        """.utf8)
        let readyJSON = Data("""
        [{"provider_id":"p1","display_name":"P1","auth_modes":["oauth"],"auth_status":{"provider_id":"p1","state":"ready","detail":""},"models":[]}]
        """.utf8)
        let unready = try JSONDecoder().decode([ProviderInfo].self, from: unreadyJSON)
        let ready = try JSONDecoder().decode([ProviderInfo].self, from: readyJSON)

        #expect(NativeClient.providerDoctorCoverageCheck(unready).status == "warn")
        #expect(NativeClient.providerDoctorCoverageCheck(ready).status == "ok")
    }

    @Test("worst status and cached health merge cannot manufacture global OK")
    func rollupAndCacheMergePreserveLiveFailure() {
        #expect(NativeClient.doctorRollup(["ok", "warn"]) == "warn")
        #expect(NativeClient.doctorRollup(["ok", "error"]) == "fail")
        let cached = HealthCard(
            overall: "ok",
            subsystems: [
                HealthCardSubsystem(id: "storage", label: "Storage", status: "ok", detail: "healthy", fixAction: nil),
                HealthCardSubsystem(id: "live.telegram", label: "stale", status: "ok", detail: "stale", fixAction: nil),
            ],
            createdAt: "old"
        )
        let merged = NativeClient.mergeHealthCard(
            cached: cached,
            liveChecks: [DoctorCheck(id: "live.telegram", title: "Telegram", status: "fail", detail: "broken", repair: nil)],
            now: "new"
        )

        #expect(merged.overall == "fail")
        #expect(merged.subsystems.filter { $0.id == "live.telegram" }.count == 1)
        #expect(merged.subsystems.first { $0.id == "live.telegram" }?.detail == "broken")
    }

    @Test("live Doctor rows render in their owning categories")
    @MainActor
    func doctorCategoriesOwnLiveRows() {
        #expect(DoctorView.categoryID(for: "live.providers") == "Provider")
        #expect(DoctorView.categoryID(for: "live.telegram") == "Connectors")
        #expect(DoctorView.categoryID(for: "live.search") == "Connectors")
        #expect(DoctorView.categoryID(for: "live.background_loops") == "Runtime")
        // 2026-09-02: the two per-turn health rows. Pinned here so a rename
        // cannot quietly drop either into the "Release" catch-all, which is
        // where an unowned id goes to be ignored.
        #expect(DoctorView.categoryID(for: "prompt_prefix_health") == "Runtime")
        #expect(DoctorView.categoryID(for: "subconscious_vitals") == "Cognition")
        // 2026-09-06: cb9861ef ("Agent UI speaks the agent's name, never a gender")
        // replaced every hard-coded pronoun with AgentVoice. Cognition's title is
        // now the agent's possessive NAME plus "inner state" (DoctorView.swift:798),
        // so derive it from the same voice rather than re-pinning a literal, and
        // keep the invariant that moved it: no gendered pronoun in the copy.
        let cognitionTitle = DoctorPlainCopy.sectionTitle(for: "Cognition")
        #expect(cognitionTitle == "\(AgentVoice.live.possessive) inner state")
        #expect(!["her ", "his ", "their "].contains { cognitionTitle.lowercased().hasPrefix($0) })
        #expect(DoctorView.categoryID(for: "live.tools") == "Tools")
        #expect(DoctorView.categoryID(for: "live.autonomy") == "Autonomy")
    }

    /// 2026-09-02 live incident: the heartbeat read `doctor/latest.json`,
    /// counted two Doctor-only diagnostic rows among the failures, and pushed
    /// "Doctor has 2 failing checks: prompt_prefix_health and
    /// subconscious_vitals" to User's phone. Those rows grade a measurement
    /// window and belong to a person looking at Doctor. The sweep must skip
    /// them ENTIRELY — not counted in the totals, never the reason for an alert.
    @Test("the heartbeat sweep skips Doctor-only rows entirely")
    @MainActor
    func heartbeatSkipsIneligibleDoctorRows() {
        let rows: [[String: Any]] = [
            ["id": "storage", "status": "ok"],
            ["id": "prompt_prefix_health", "status": "fail"],
            ["id": "subconscious_vitals", "status": "fail"],
            ["id": "memory_store", "status": "warn"],
        ]
        let (eligible, skipped) = BackgroundLoopsAssembly.heartbeatEligibleDoctorRows(rows)
        #expect(skipped == 2)
        #expect(eligible.compactMap { $0["id"] as? String } == ["storage", "memory_store"])
        // The whole point: nothing here is failing as far as the heartbeat is
        // concerned, so no alert and no 3am push.
        #expect(!eligible.contains { ($0["status"] as? String) == "fail" })
    }

    @Test("a snapshot of nothing but Doctor-only rows is unverifiable, not healthy")
    @MainActor
    func heartbeatAllExcludedIsUnverifiable() {
        let rows: [[String: Any]] = [
            ["id": "prompt_prefix_health", "status": "fail"],
            ["id": "subconscious_vitals", "status": "warn"],
        ]
        let (eligible, skipped) = BackgroundLoopsAssembly.heartbeatEligibleDoctorRows(rows)
        #expect(skipped == 2)
        #expect(eligible.isEmpty)
    }

    @Test("unknown autonomy posture warns instead of pretending disabled")
    func unknownAutonomyWarns() {
        let autonomy = AutonomyKernelSummary(
            status: "unknown",
            mode: nil,
            enabled: nil,
            processEnabled: nil,
            trustEnabled: nil,
            disabledReason: nil,
            guardrails: [],
            approvalClasses: [],
            runningImprovements: nil,
            createdAt: nil
        )
        #expect(NativeClient.autonomyDoctorCoverageCheck(autonomy).status == "warn")
    }
}
