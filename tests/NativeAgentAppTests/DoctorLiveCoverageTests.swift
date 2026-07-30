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
        #expect(DoctorView.categoryID(for: "live.tools") == "Tools")
        #expect(DoctorView.categoryID(for: "live.autonomy") == "Autonomy")
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
