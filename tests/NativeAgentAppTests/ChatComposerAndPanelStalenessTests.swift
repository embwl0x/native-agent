import Foundation
import Observation
import Testing
@testable import NativeAgentApp

// Covers the H4 / H5 / M12 chat-performance + honesty wave (2026-07-09).
//
// H5: the composer's draft moved to view-local @State; `chatDrafts` is now
//     written only through commitChatDraft / injectChatDraft.
// H4: the post-turn refresh applies a disk snapshot without re-fetching the
//     session list, the trust policy, or health — and without writing the
//     observed message slot when nothing changed.
// M12: refreshForSidebarItem records which endpoints failed so the UI can say
//     "showing last-known data" instead of rendering stale rows as current.

/// `withObservationTracking`'s onChange is an escaping @Sendable closure, so it
/// cannot capture a local `var`. This box carries the flag out.
private final class Flag: @unchecked Sendable {
    var fired = false
}

private func msg(_ id: String, role: String = "assistant", content: String = "hi") -> ChatMessage {
    ChatMessage(id: id, sessionId: "s1", role: role, content: content)
}

@MainActor
private func syntheticErrorBubble(_ suffix: String = "a") -> ChatMessage {
    ChatMessage(
        id: AppModel.syntheticErrorIDPrefix + suffix,
        sessionId: "s1",
        role: "assistant",
        content: "Provider unavailable."
    )
}

// MARK: - Slow-turn notice placement

@Test
func slowTurnNotice_routesToTheChatTopLane() {
    #expect(ChatTurnNoticePresentation.destination(for: "slow_turn") == .chatTop)
}

@Test
func timeoutAndOrdinaryTurnNotices_keepTheirGlobalSeverityLanes() {
    #expect(ChatTurnNoticePresentation.destination(for: "tool_timeout") == .globalWarning)
    #expect(ChatTurnNoticePresentation.destination(for: "tool_started") == .globalInfo)
}

@Test
func slowTurnNotice_isStructurallyOwnedByTheTopOfTheMessageViewport() throws {
    let chat = try AppSourceScraping.appSource("ChatView.swift")
    let content = try AppSourceScraping.appSource("ContentView.swift")

    #expect(chat.contains("SystemToastBar(center: turnNoticeToasts, placement: .top)"))
    #expect(chat.contains(".overlay(alignment: .top)"))
    #expect(content.contains(".overlay(alignment: .bottom)"))
}

// MARK: - H5: draft commit / inject

@MainActor
@Test
func commitChatDraft_filesTextUnderItsOwnSession_notTheActiveOne() {
    let model = AppModel()
    model.activeChatSessionId = "session-B"

    // The composer commits the text it was holding for session-A even though
    // the active session has already moved on — this is exactly the ordering
    // that happens on a session switch.
    model.commitChatDraft("half-typed thought", sessionId: "session-A")

    #expect(model.chatDraft(for: "session-A") == "half-typed thought")
    #expect(model.chatDraft(for: "session-B") == "")
    #expect(model.chatDraftLastTouched["session-A"] != nil)
}

@MainActor
@Test
func commitChatDraft_empty_removesTheKeyAndItsLRUEntry() {
    let model = AppModel()
    model.commitChatDraft("something", sessionId: "s1")
    #expect(model.chatDrafts["s1"] != nil)

    // An empty draft is an absent draft — otherwise a sent message's dead
    // session stays pinned in the 50-entry LRU forever.
    model.commitChatDraft("", sessionId: "s1")
    #expect(model.chatDrafts["s1"] == nil)
    #expect(model.chatDraftLastTouched["s1"] == nil)
}

@MainActor
@Test
func commitChatDraft_ignoresEmptySessionId() {
    let model = AppModel()
    model.commitChatDraft("orphan", sessionId: "")
    #expect(model.chatDrafts[""] == nil)
}

@MainActor
@Test
func injectChatDraft_bumpsGeneration_butCommitDoesNot() {
    let model = AppModel()
    let start = model.chatDraftInjectionGeneration

    // A commit is the composer handing back text it already has. Bumping the
    // generation here would echo it straight back into the field it came from.
    model.commitChatDraft("typed by the user", sessionId: "s1")
    #expect(model.chatDraftInjectionGeneration == start)

    // An inject is text the composer has never seen; it must be told.
    model.injectChatDraft("Create a skill from this conversation: ", sessionId: "s1")
    #expect(model.chatDraftInjectionGeneration == start + 1)
    #expect(model.chatDraft(for: "s1") == "Create a skill from this conversation: ")
}

// MARK: - H4: post-turn message application

@MainActor
@Test
func applyLoadedChatMessages_preservesSyntheticErrorBubbleMissingFromDisk() {
    let model = AppModel()
    model.activeChatSessionId = "s1"
    let bubble = syntheticErrorBubble()
    model.chatMessagesBySession["s1"] = [msg("u1", role: "user"), bubble]

    // Disk's tail is the user's turn — the failure still stands, so the
    // in-memory-only notice must survive the swap.
    model.applyLoadedChatMessages([msg("u1", role: "user")], for: "s1")

    #expect(model.chatMessagesBySession["s1"]?.count == 2)
    #expect(model.chatMessagesBySession["s1"]?.last?.id == bubble.id)
}

@MainActor
@Test
func applyLoadedChatMessages_dropsSyntheticBubbleWhenARealReplyLanded() {
    let model = AppModel()
    model.activeChatSessionId = "s1"
    model.chatMessagesBySession["s1"] = [msg("u1", role: "user"), syntheticErrorBubble()]

    // A completed assistant reply on disk supersedes the notice — otherwise a
    // stale error floats BELOW a newer real answer.
    model.applyLoadedChatMessages(
        [msg("u1", role: "user"), msg("a1", role: "assistant", content: "real reply")],
        for: "s1"
    )

    let ids = model.chatMessagesBySession["s1"]?.map(\.id) ?? []
    #expect(ids == ["u1", "a1"])
}

@MainActor
@Test
func applyLoadedChatMessages_isIdempotent() {
    let model = AppModel()
    model.activeChatSessionId = "s1"
    let bubble = syntheticErrorBubble()
    model.chatMessagesBySession["s1"] = [msg("u1", role: "user"), bubble]
    let disk = [msg("u1", role: "user")]

    model.applyLoadedChatMessages(disk, for: "s1")
    model.applyLoadedChatMessages(disk, for: "s1")

    // The preserved bubble is carried over, never appended twice.
    #expect(model.chatMessagesBySession["s1"]?.count == 2)
}

/// Structural guard, no wall clock: an unchanged snapshot must not write the
/// observed slot at all. `chatMessagesBySession` drives the message list, the
/// sidebar badges and the scroll coordinator — an equal-value write still
/// invalidates every one of them.
@MainActor
@Test
func applyLoadedChatMessages_equalSnapshot_doesNotTouchObservedState() {
    let model = AppModel()
    model.activeChatSessionId = "s1"
    let rows = [msg("u1", role: "user"), msg("a1")]
    model.chatMessagesBySession["s1"] = rows

    let flag = Flag()
    withObservationTracking {
        _ = model.chatMessagesBySession
    } onChange: {
        flag.fired = true
    }
    model.applyLoadedChatMessages(rows, for: "s1")
    #expect(flag.fired == false, "an identical snapshot must not invalidate observers")

    // ...and the tracking is real: a genuinely different snapshot does fire.
    let flag2 = Flag()
    withObservationTracking {
        _ = model.chatMessagesBySession
    } onChange: {
        flag2.fired = true
    }
    model.applyLoadedChatMessages(rows + [msg("a2")], for: "s1")
    #expect(flag2.fired == true)
}

// MARK: - M12: panel staleness

@MainActor
@Test
func recordPanelRefresh_cleanRefresh_isNotStaleAndHasNoNotice() {
    let model = AppModel()
    model.recordPanelRefresh(.chat, failedEndpoints: [])

    #expect(model.isPanelStale(.chat) == false)
    #expect(model.panelStaleNotice(for: .chat) == nil)
    #expect(model.panelRefreshStatus[.chat]?.lastSuccessAt != nil)
}

@MainActor
@Test
func recordPanelRefresh_failedEndpoints_produceANoticeNamingThem() {
    let model = AppModel()
    model.recordPanelRefresh(.chat, failedEndpoints: ["trust policy", "model catalog"])

    #expect(model.isPanelStale(.chat) == true)
    let notice = try? #require(model.panelStaleNotice(for: .chat))
    #expect(notice?.contains("trust policy") == true)
    #expect(notice?.contains("model catalog") == true)
    // Never had a clean refresh this run — say so rather than invent an age.
    #expect(notice?.contains("Nothing has loaded yet") == true)
}

@MainActor
@Test
func recordPanelRefresh_failureAfterSuccess_keepsTheLastSuccessTimestamp() {
    let model = AppModel()
    model.recordPanelRefresh(.legacyWorkshop, failedEndpoints: [])
    let firstSuccess = model.panelRefreshStatus[.legacyWorkshop]?.lastSuccessAt

    model.recordPanelRefresh(.legacyWorkshop, failedEndpoints: ["missions"])

    // The rows on screen are from `firstSuccess`, and that is what the notice
    // must date them to — a failed attempt is not a refresh.
    #expect(model.panelRefreshStatus[.legacyWorkshop]?.lastSuccessAt == firstSuccess)
    #expect(model.isPanelStale(.legacyWorkshop) == true)
    let notice = try? #require(model.panelStaleNotice(for: .legacyWorkshop))
    #expect(notice?.contains("Showing data from") == true)
    #expect(notice?.contains("missions") == true)
}

@MainActor
@Test
func recordPanelRefresh_recoveringClearsStaleness() {
    let model = AppModel()
    model.recordPanelRefresh(.legacyWorkshop, failedEndpoints: ["missions"])
    #expect(model.isPanelStale(.legacyWorkshop) == true)

    model.recordPanelRefresh(.legacyWorkshop, failedEndpoints: [])
    #expect(model.isPanelStale(.legacyWorkshop) == false)
    #expect(model.panelStaleNotice(for: .legacyWorkshop) == nil)
}

@MainActor
@Test
func recordPanelRefresh_isScopedPerPanel() {
    let model = AppModel()
    model.recordPanelRefresh(.chat, failedEndpoints: ["health"])
    model.recordPanelRefresh(.legacyWorkshop, failedEndpoints: [])

    #expect(model.isPanelStale(.chat) == true)
    #expect(model.isPanelStale(.legacyWorkshop) == false)
    // An untouched panel has no opinion — it must not read as stale.
    #expect(model.isPanelStale(.trust) == false)
    #expect(model.panelStaleNotice(for: .trust) == nil)
}

@MainActor
@Test
func compactReaderFreshnessPreservesLastGoodAndCannotClearPanelState() {
    let model = AppModel()
    let first = Date(timeIntervalSince1970: 1_000)
    let clean = AppModel.nextRefreshStatus(previous: nil, failedEndpoints: [], at: first)
    let failed = AppModel.nextRefreshStatus(
        previous: clean,
        failedEndpoints: ["running work"],
        at: first.addingTimeInterval(60)
    )
    #expect(failed.isStale)
    #expect(failed.lastSuccessAt == first)

    model.recordPanelRefresh(.chat, failedEndpoints: ["health"])
    model.whatsRunningRefreshStatus = failed
    model.sidebarActivityRefreshStatus = clean
    #expect(model.isPanelStale(.chat))
    #expect(model.whatsRunningRefreshStatus?.isStale == true)
    #expect(model.sidebarActivityRefreshStatus?.isStale == false)
}

@MainActor
@Test
func whatsRunningPresentationReservesIdleForASuccessfulEmptyRead() {
    let checking = WhatsRunningPresentation.make(snapshot: nil, status: nil)
    #expect(checking.title == "Checking…")
    #expect(checking.title != "Idle")

    let successAt = Date(timeIntervalSince1970: 2_000)
    let clean = AppModel.nextRefreshStatus(previous: nil, failedEndpoints: [], at: successAt)
    let empty = WhatsRunningPresentation.make(snapshot: WhatsRunning(items: [], count: 0), status: clean)
    #expect(empty.title == "Idle")

    let row = WhatsRunningItem(
        id: "run-1", kind: "workflow", label: "Build", startedAt: nil,
        startsAt: nil, cancellable: false, cancelHint: nil
    )
    let failed = AppModel.nextRefreshStatus(
        previous: clean,
        failedEndpoints: ["running work"],
        at: successAt.addingTimeInterval(60)
    )
    let stale = WhatsRunningPresentation.make(
        snapshot: WhatsRunning(items: [row], count: 1),
        status: failed
    )
    #expect(stale.title == "Running: 1 · stale")
    #expect(stale.isStale)
}

@MainActor
@Test
func partialActivityBucketsKeepLastGoodValuesAndRemainUncertain() {
    #expect(AppModel.keepingLastGood([1, 2], fetched: Optional<[Int]>.none) == [1, 2])
    let replacement: [Int] = [3]
    let replaced: [Int] = AppModel.keepingLastGood([1, 2], fetched: replacement)
    #expect(replaced == replacement)
    let partial = AppModel.nextRefreshStatus(
        previous: nil,
        failedEndpoints: ["inbox"],
        at: Date(timeIntervalSince1970: 3_000)
    )
    #expect(partial.isStale)
    #expect(partial.lastSuccessAt == nil)
}

@MainActor
@Test
func compactReadPresentationNeverTurnsFailureIntoEmpty() {
    #expect(AppModel.compactReadPresentationState(hasContent: false, status: nil) == .loading)
    let failed = AppModel.nextRefreshStatus(
        previous: nil,
        failedEndpoints: ["messages"],
        at: Date(timeIntervalSince1970: 4_000)
    )
    #expect(AppModel.compactReadPresentationState(hasContent: false, status: failed) == .unavailable)
    #expect(AppModel.compactReadPresentationState(hasContent: true, status: failed) == .stale)
    let clean = AppModel.nextRefreshStatus(previous: nil, failedEndpoints: [], at: Date())
    #expect(AppModel.compactReadPresentationState(hasContent: false, status: clean) == .empty)
    #expect(AppModel.compactReadPresentationState(hasContent: true, status: clean) == .content)
}

@MainActor
@Test
func pruningSessionChatStateAlsoRemovesDetachedFreshness() {
    let model = AppModel()
    let stale = AppModel.nextRefreshStatus(
        previous: nil,
        failedEndpoints: ["messages"],
        at: Date()
    )
    model.detachedChatRefreshStatus["gone"] = stale
    model.detachedChatContextReceiptRefreshStatus["gone"] = stale

    model.pruneSessionChatState("gone")

    #expect(model.detachedChatRefreshStatus["gone"] == nil)
    #expect(model.detachedChatContextReceiptRefreshStatus["gone"] == nil)
}

@MainActor
@Test
func staleSessionSweepPrunesGoneSessionsButKeepsLiveAndReportedOnes() {
    let model = AppModel()
    model.activeChatSessionId = "active"
    model.chatMessagesBySession["gone"] = [msg("g1")]
    model.chatMessagesBySession["live"] = [msg("l1")]
    model.chatMessagesBySession["listed"] = [msg("s1")]
    model.streamingSessions.insert("live")
    model.pausedChatQueueSessions.insert("gone")
    model.detachedChatRefreshStatus["gone"] = AppModel.nextRefreshStatus(
        previous: nil,
        failedEndpoints: [],
        at: Date()
    )

    // 2026-07-21 audit fix: the sweep wired into the session-list refresh.
    // "gone" is no longer reported, so every per-session cache for it drops;
    // a streaming session is still being written even when the list missed
    // it, and a reported session keeps its cache.
    model.pruneStaleSessionChatState(knownSessionIds: ["active", "live", "listed"])

    #expect(model.chatMessagesBySession["gone"] == nil)
    #expect(model.detachedChatRefreshStatus["gone"] == nil)
    #expect(!model.pausedChatQueueSessions.contains("gone"))
    #expect(model.chatMessagesBySession["live"]?.count == 1)
    #expect(model.chatMessagesBySession["listed"]?.count == 1)
}

@MainActor
@Test
func detachedReceiptFailureDoesNotMakeAuthoritativeEmptyHistoryUnavailable() {
    let cleanHistory = AppModel.nextRefreshStatus(
        previous: nil,
        failedEndpoints: [],
        at: Date()
    )
    let failedReceipt = AppModel.nextRefreshStatus(
        previous: nil,
        failedEndpoints: ["context receipt"],
        at: Date()
    )

    #expect(AppModel.compactReadPresentationState(hasContent: false, status: cleanHistory) == .empty)
    #expect(failedReceipt.isStale == true)
    #expect(AppModel.detachedContextReceiptWarning(history: .empty, receiptStatus: failedReceipt)?.contains("history is still current") == true)
    #expect(AppModel.detachedContextReceiptWarning(history: .stale, receiptStatus: failedReceipt) == "Context details are also unavailable.")
    #expect(AppModel.detachedContextReceiptWarning(history: .unavailable, receiptStatus: failedReceipt) == "Context details are also unavailable.")
}

@MainActor
@Test
func approximateAgeDescription_bucketsCoarsely() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func age(_ secondsAgo: TimeInterval) -> String {
        AppModel.approximateAgeDescription(since: now.addingTimeInterval(-secondsAgo), now: now)
    }

    #expect(age(5) == "moments ago")
    #expect(age(59) == "moments ago")
    #expect(age(60) == "1m ago")
    #expect(age(90 * 60) == "1h ago")
    #expect(age(50 * 60 * 60) == "2d ago")
    // A clock skew (success stamped after the attempt) must not underflow.
    #expect(AppModel.approximateAgeDescription(since: now.addingTimeInterval(60), now: now) == "moments ago")
}
