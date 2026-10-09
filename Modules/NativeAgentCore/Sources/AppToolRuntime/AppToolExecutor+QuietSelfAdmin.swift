import AppToolRuntime
import ChatOrchestration
import Dispatcher
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter

/// The `app` door's posture, page read and setting set.
///
/// Core owns admission, catalog reads and receipts. The mounted window,
/// page rendering and visible controls remain behind the presentation ports.
extension AppToolExecutor {
    /// Consume the self-window handoff inside the original tool call, through
    /// the `app` door's own read or action (and its posture checks), as a
    /// direct `app` call runs them (`runSelfAppRoute`).
    public static func performMacSelfAppRoute(
        _ result: JSONValue,
        run: ([String: JSONValue]) async -> JSONValue
    ) async -> JSONValue {
        guard case .object(let payload) = result,
              case .object(let detail) = payload["detail"],
              detail["status"] == .string("in_process_route"),
              detail["execute_in_process"] == .bool(true),
              case .object(let next) = detail["next_action"],
              next["tool"] == .string("app"),
              case .object(let input) = next["input"] else { return result }
        let outcome = await run(input)
        // Page inspection is supplementary after a verified app focus. Its
        // availability must not turn completed navigation into a retry.
        if input["action"] == nil, payload["ok"] == .bool(true) {
            var response = payload
            response["in_process_observation"] = outcome
            var observationDetail = detail
            observationDetail.removeValue(forKey: "next_action")
            observationDetail.removeValue(forKey: "execute_in_process")
            response["detail"] = .object(observationDetail)
            return .object(response)
        }
        guard case .object(var response) = outcome else { return outcome }
        response["ok"] = .bool(response["status"] == .string("ok"))
        return .object(response)
    }

    // MARK: - Posture

    /// Safe, Work mode, Builder, Full Mac — read back off the saved policy.
    ///
    /// `permissionLevel` alone cannot tell Work from Builder: the two presets
    /// write the SAME level ("balanced") and differ by how files outside the
    /// workspace are treated ("deny" vs "ask"), so that is the axis that
    /// decides (TrustCenterView.TrustPolicyPreset.plan).
    ///
    /// `changesAllowed` is about THIS APP's own settings, not about the Mac.
    /// The agent administers the app under every posture but Safe: a knowledge
    /// graph switch or a thinking level is not a Mac effect, not a file the
    /// person owns, and not a send. Work mode's fence is where files may be
    /// written, and it still stands — it was never a fence around the app's own
    /// controls. What stays the person's, under every posture, is raising the
    /// Trust posture, macOS permission grants, and provider and connector
    /// secrets; those are fenced by `ownerOnly` and `fullMacOnly`, for what
    /// they ARE rather than for the mode the session is in.
    public struct QuietPosture: Sendable {
        public let name: String
        let changesAllowed: Bool
    }

    /// The one mode that is wide open (User, 2026-09-13). Named once so the
    /// catalog's `writable` and the set's refusal cannot drift apart.
    public static let fullMacModeName = "Full Mac"

    /// A posture the saved policy actually spells out, or nothing.
    ///
    /// Nothing is a refusal, never a default: a level this does not recognise
    /// (an older spelling, a hand-edited file) used to fall through to the
    /// outside-workspace axis and read as Builder, which is the permissive
    /// answer — exactly the wrong way for an unknown to fail.
    public static func quietPosture(permissionLevel: String, outsideWorkspaceDefault: String) -> QuietPosture? {
        switch permissionLevel.trimmingCharacters(in: .whitespaces).lowercased() {
        case "strict", "locked_down":
            return QuietPosture(name: "Safe", changesAllowed: false)
        case "full_mac_os", "wide_open_receipts":
            return QuietPosture(name: "Full Mac", changesAllowed: true)
        case "balanced":
            switch outsideWorkspaceDefault.trimmingCharacters(in: .whitespaces).lowercased() {
            case "ask", "allow":
                return QuietPosture(name: "Builder", changesAllowed: true)
            case "deny":
                return QuietPosture(name: "Work mode", changesAllowed: true)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The posture as saved RIGHT NOW, read through the same checked authority
    /// seam the security gates use (`loadTrustPolicyChecked`).
    ///
    /// `appModel.engine.trust.policy` is a cached projection that a page refreshes when
    /// it feels like it, and a permissively decoded one: a policy saved as Work
    /// mode in another window kept authorizing writes here until something
    /// happened to reload it. Damaged or unreadable authority throws, and a
    /// throw is a refusal.
    public static func freshQuietPosture(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> QuietPosture? {
        guard let policy = try? await SwiftNativeTrustCenter(dataRoot: dataRoot)
            .loadTrustPolicyChecked() else { return nil }
        guard case .string(let level)? = policy["permissionLevel"] else { return nil }
        var outside = ""
        if case .object(let filePolicy)? = policy["filePolicy"],
           case .string(let raw)? = filePolicy["outsideWorkspaceDefault"] {
            outside = raw
        }
        return quietPosture(permissionLevel: level, outsideWorkspaceDefault: outside)
    }

    /// Full Mac as ONE locked authority generation spells it.
    ///
    /// `freshQuietPosture` answers for the moment it is called; a write that
    /// carries Full Mac authority re-asks this question inside the transaction
    /// that writes, against the generation it is merging into
    /// (`applyPolicyPatchChecked(_:guardedByLockedPolicy:)`). Anything the saved
    /// policy does not plainly say is not Full Mac.
    public static func lockedPolicyIsFullMac(_ policy: [String: JSONValue]) -> Bool {
        guard case .string(let level)? = policy["permissionLevel"] else { return false }
        var outside = ""
        if case .object(let filePolicy)? = policy["filePolicy"],
           case .string(let raw)? = filePolicy["outsideWorkspaceDefault"] {
            outside = raw
        }
        return quietPosture(permissionLevel: level, outsideWorkspaceDefault: outside)?.name
            == fullMacModeName
    }

    static func unreadablePostureFailure(extra: [String: JSONValue] = [:]) -> JSONValue {
        failure(
            "trust_mode_unreadable",
            "The saved Trust policy does not say which mode this Mac is in, so nothing is changed. "
            + "The person can set the mode in Trust.",
            extra: extra
        )
    }

    /// The posture gate setting.set stands behind, for the app's other
    /// writes (Doctor repair, upkeep). Nil when changes are allowed.
    static func quietChangesRefusal() async -> JSONValue? {
        guard let posture = await freshQuietPosture() else { return unreadablePostureFailure() }
        return posture.changesAllowed ? nil : readOnlyFailure(posture)
    }

    static func readOnlyFailure(_ posture: QuietPosture) -> JSONValue {
        failure(
            "trust_mode_read_only",
            "\(posture.name) is the posture that changes nothing at all, and only the person lifts it. "
            + "Ask them to choose Work mode or above in Trust.",
            extra: ["trust_mode": .string(posture.name)]
        )
    }

    public static func failure(_ reason: String, _ detail: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var body: [String: JSONValue] = [
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
        ]
        // The code, status and detail stand: extra never overwrites them.
        body.merge(extra) { own, _ in own }
        return .object(body)
    }

    public static func unattachedFailure() -> JSONValue {
        failure(
            "app_window_unavailable",
            "The app's own pages are not available in this process — there is no live window to read."
        )
    }

    public static func unknownPageFailure(_ raw: String, pages: [String]) -> JSONValue {
        failure(
            "unknown_page",
            "No page is called that.",
            extra: ["requested": .string(raw), "pages": .array(pages.map { .string($0) })]
        )
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chat

    /// User, 10-02: no rule is only for when he is at the Mac, and under Full
    /// Mac all of it is hers. Below Full Mac, a turn User started himself from
    /// any door (no out-of-band origin, no agent lane; Mac chat, his paired
    /// phone, or Telegram or Slack from a sender allowlisted by user id) may
    /// move his screen, speak, and touch a conversation he is in. Any other
    /// turn leaves all of that alone.
    static func reachesUser(surface: String, fullMac: Bool, dataRoot: URL) async -> Bool {
        if fullMac { return true }
        let envelope = TurnEnvelope.current(surface: surface)
        let door = envelope.surface.lowercased()
        var user = ChatPersistenceContext.originProvenance == nil && envelope.agent == nil
            && ["chat", "app", "mac", "ios", "telegram", "slack"].contains(door)
        if user, ["telegram", "slack"].contains(door) {
            user = await SwiftNativeSecurityCenter(dataRoot: dataRoot).remoteSenderIsAllowlisted(.currentTurn(
                verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface))
        }
        return user
    }

    /// One chat action (`runFolded`): Safe has already refused it. The
    /// posture is read again for the receipt; the conversation-level fences
    /// (User's screen, User is in it, her own conversation) are the app's.
    @MainActor
    func runChatSessionAction(
        verb: String, input: [String: JSONValue], surface: String, host: any QuietToolHost
    ) async -> JSONValue {
        guard let posture = await Self.freshQuietPosture(
            dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ) else { return Self.unreadablePostureFailure() }
        guard posture.changesAllowed else { return Self.readOnlyFailure(posture) }
        let reachesUser = await Self.reachesUser(surface: surface, fullMac: posture.name == Self.fullMacModeName,
                                               dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let answer = await host.runChatSession(verb: verb, input: input, reachesUser: reachesUser)
        guard case .object(var body) = answer else {
            return Self.failure("chat_session_failed", "The app gave no answer for that verb.")
        }
        body["verb"] = .string(verb)
        body["trust_mode"] = .string(posture.name)
        body["surface"] = .string(surface)
        body["decided_by"] = .string("agent")
        return .object(body)
    }

    // MARK: - Page read

    public static func pageReadResult(page: String, fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging([
            "page": .string(page),
            "page_read": .bool(true),
            "page_shown_by_this_call": .bool(false),
        ]) { _, receipt in receipt })
    }

    /// The `app` door's page read: each setting row also carries its type,
    /// choices and note, so the read is all `setting.set` needs.
    @MainActor
    func runAppPageRead(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        if requested.lowercased() == "context" { return await presentation.contextReceiptRead(input: input) }
        if requested.lowercased() == "agent_view" { return await presentation.agentViewRead(input: input) }
        let current = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "current"
        guard let page = current ? presentation.currentPage : presentation.page(named: requested) else {
            if current {
                return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("app_window_unavailable"),
                                "detail": .string("No app window is showing a page right now; name the page instead of current.")])
            }
            return Self.unknownPageFailure(requested, pages: presentation.pages.map(\.id))
        }
        guard let appModel = quietHost() else { return Self.unattachedFailure() }

        let content = await appModel.pageRead(page)
        let posture = await Self.freshQuietPosture()
        let fullMac = posture?.name == Self.fullMacModeName
        var settingRows: [JSONValue] = []
        for setting in QuietSettings.settings(forPage: page.id, host: quietHost()) {
            var row: [String: JSONValue] = [
                "id": .string(setting.id),
                "label": .string(setting.label),
                "value": await setting.read(appModel),
                "writable": .bool(setting.writable(fullMac: fullMac)),
            ]
            if setting.ownerOnly { row["owner_only"] = .bool(true) }
            if setting.fullMacOnly {
                row["full_mac_only"] = .bool(true)
                if !fullMac { row["refusal"] = .string(QuietSettings.belowFullMacRefusal) }
            }
            if case .object(let listed) = await setting.catalogRow(fullMac: fullMac, host: { self.quietHost() }) {
                for key in ["type", "choices", "note"] { row[key] = listed[key] }
            }
            settingRows.append(.object(row))
        }

        return Self.pageReadResult(page: page.id, fields: [
            "status": .string("ok"),
            "title": .string(page.title),
            "about": .string(page.summary),
            "settings": .array(settingRows),
            // What the page SAYS, built from the records the page draws from.
            "content": .array(content),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "changes_allowed": .bool(posture?.changesAllowed ?? false),
        ])
    }

    // MARK: - Setting set

    /// A set every check before the row's own rule has let through.
    private struct GatedSetting {
        let setting: QuietSetting
        let host: any QuietToolHost
        let posture: QuietPosture
        let value: JSONValue
        let request: String?
        let restoresPrevious: Bool
        let write: @MainActor @Sendable (any QuietSettingsHost, JSONValue) async throws -> Void
    }

    /// The setting, the posture and its rows' fences (owner-only, Safe,
    /// Full-Mac-only), and that there is a value to write.
    @MainActor
    private func settingGate(input: [String: JSONValue]) async -> Result<GatedSetting, GateRefusal> {
        func refuse(_ answer: JSONValue) -> Result<GatedSetting, GateRefusal> { .failure(GateRefusal(answer: answer)) }
        let requestedPage = Self.text(input["page"])
        let requestedSetting = Self.text(input["setting"])
        guard !requestedSetting.isEmpty else {
            return refuse(Self.failure("missing_setting", "Name the setting. Its page read (app {page}) has the names."))
        }
        guard let appModel = quietHost() else { return refuse(Self.unattachedFailure()) }

        guard let setting = QuietSettings.setting(id: requestedSetting, host: quietHost()) else {
            let known = requestedPage.isEmpty
                ? QuietSettings.all(host: quietHost())
                : QuietSettings.settings(forPage: presentation.page(named: requestedPage)?.id ?? "", host: quietHost())
            return refuse(Self.failure(
                "unknown_setting",
                "No setting is called that. Read its page first for the names (app {page}) rather than guessing one.",
                extra: [
                    "requested": .string(requestedSetting),
                    "known": .array(known.map { .string($0.id) }),
                ]
            ))
        }
        if !requestedPage.isEmpty,
           let page = presentation.page(named: requestedPage), page.id != setting.page {
            return refuse(Self.failure(
                "wrong_page",
                "That setting lives on a different page.",
                extra: ["setting": .string(setting.id), "page": .string(setting.page)]
            ))
        }

        // The person's own posture. Refused for what it IS, not for the mode
        // the session is in — this one does not open up under Full Mac.
        if setting.ownerOnly {
            return refuse(Self.failure(
                "owner_only",
                QuietSettings.ownerOnlyRefusal,
                extra: [
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "label": .string(setting.label),
                    "requested_value": input["value"] ?? .null,
                    "current_value": await setting.read(appModel),
                ]
            ))
        }

        var request: String?
        var restoresPrevious = false
        if ChatTurnRuntimeContext.current != nil {
            request = Self.text(input["because"])
            guard let request, request.split(whereSeparator: \.isWhitespace).count >= 3,
                  let restores = await ChatToolSessionContext.settingRequestEvidence?(setting.id, input["value"] ?? .null, await setting.read(appModel), request) else {
                return refuse(Self.failure("setting_not_requested",
                    "No one asked to change \(setting.id); quote the request in because. Nothing changed.",
                    extra: ["setting": .string(setting.id), "effects": .string("none"), "changed": .bool(false)]))
            }
            restoresPrevious = restores
        }

        guard let posture = await Self.freshQuietPosture() else {
            return refuse(Self.unreadablePostureFailure(extra: [
                "setting": .string(setting.id),
                "page": .string(setting.page),
                "requested_value": input["value"] ?? .null,
                "current_value": await setting.read(appModel),
            ]))
        }
        guard posture.changesAllowed else {
            return refuse(Self.failure(
                "trust_mode_read_only",
                "\(posture.name) is the posture that changes nothing at all — it is the person's "
                + "standing choice to be read from and not written to, and only they lift it.",
                extra: [
                    "trust_mode": .string(posture.name),
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "requested_value": input["value"] ?? .null,
                    "current_value": await setting.read(appModel),
                ]
            ))
        }
        // Full Mac is wide open, and only there may the agent move the Trust
        // fence — down, never up. Below it these read and refuse, saying the
        // one thing that never changes: turning Full Mac ON is the person's.
        if setting.fullMacOnly, posture.name != Self.fullMacModeName {
            return refuse(Self.failure(
                "trust_posture_needs_full_mac",
                QuietSettings.belowFullMacRefusal,
                extra: [
                    "trust_mode": .string(posture.name),
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "requested_value": input["value"] ?? .null,
                    "current_value": await setting.read(appModel),
                ]
            ))
        }
        guard let write = setting.write else {
            return refuse(Self.failure(
                "not_writable",
                "That one is shown, not set.",
                extra: ["setting": .string(setting.id), "page": .string(setting.page)]
            ))
        }
        guard let requestedValue = input["value"], requestedValue != .null else {
            return refuse(Self.failure(
                "missing_value", "Pass the new value.",
                extra: ["setting": .string(setting.id), "type": .string(setting.kind.rawValue)]
            ))
        }
        return .success(GatedSetting(setting: setting, host: appModel, posture: posture, value: requestedValue, request: request, restoresPrevious: restoresPrevious, write: write))
    }

    /// Every check that refuses a set before anything is written, the row's
    /// own value rule (`QuietSetting.check`: lower-only, narrow-only) last.
    /// Reads only, so the door's preview asks it and refuses what the set
    /// would; the set meets the same row rule again inside its write.
    @MainActor
    func settingRefusal(input: [String: JSONValue]) async -> JSONValue? {
        switch await settingGate(input: input) {
        case .failure(let refusal): return refusal.answer
        case .success(let gated):
            guard let refused = await QuietSettings.$fullMac.withValue(gated.posture.name == Self.fullMacModeName, operation: {
                await QuietSettings.$restoringPreviousValue.withValue(gated.restoresPrevious) {
                    await gated.setting.check?(gated.host, gated.value)
                }
            }) else { return nil }
            return await Self.settingWriteFailure(refused, gated.setting, gated.value, host: gated.host)
        }
    }

    /// A write the row refused or that failed, with what was asked and what
    /// it reads now. A value that would raise Trust is User's: `users_call`.
    @MainActor
    private static func settingWriteFailure(
        _ error: Error, _ setting: QuietSetting, _ requestedValue: JSONValue, host: any QuietToolHost,
        detail: [String: JSONValue] = [:]
    ) async -> JSONValue {
        var extra: [String: JSONValue] = [
            "setting": .string(setting.id),
            "page": .string(setting.page),
            "requested_value": requestedValue,
            "current_value": await setting.read(host),
        ]
        for (key, value) in detail { extra[key] = value }
        let code = if case QuietSettingError.users = error { "users_call" } else { "write_refused" }
        return failure(code, error.localizedDescription, extra: extra)
    }

    @MainActor
    func runAppSettingSet(input: [String: JSONValue], surface: String) async -> JSONValue {
        let gated: GatedSetting
        switch await settingGate(input: input) {
        case .failure(let refusal): return refusal.answer
        case .success(let ready): gated = ready
        }
        let (setting, appModel, posture, requestedValue, write) = (gated.setting, gated.host, gated.posture, gated.value, gated.write)

        // The receipt's "before" is read from the page's own state, immediately
        // before the write, so it is what the person would have seen.
        let before = await setting.read(appModel)
        // A raise: the row's own rule refuses it below Full Mac. Under Full
        // Mac it is hers, and User sees it as a decided row.
        var raise = false
        if posture.name == Self.fullMacModeName, case QuietSettingError.users? = await setting.check?(appModel, requestedValue) {
            raise = true
        }
        let writeDetail = QuietWriteDetail()
        do {
            try await QuietWriteDetail.$current.withValue(writeDetail) {
                try await QuietSettings.$fullMac.withValue(posture.name == Self.fullMacModeName) {
                    try await QuietSettings.$restoringPreviousValue.withValue(gated.restoresPrevious) {
                        try await write(appModel, requestedValue)
                    }
                }
            }
        } catch {
            // A write that touches several surfaces says which ones it had
            // already changed before it failed and rolled them back, so the
            // receipt cannot quietly under-report its own reach.
            let touched = writeDetail.take()
            return await Self.settingWriteFailure(error, setting, requestedValue, host: appModel, detail: touched)
        }
        let detail = writeDetail.take()
        let after = await setting.read(appModel)
        if raise {
            HarnessDecidedRow.post(requester: "Full Mac", tool: "setting.set \(setting.id)",
                                   sessionID: Self.inputString(input["__session_id"]),
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        }

        // This IS the receipt. A tool result is what appendToolMessage writes
        // into the transcript, so page/setting/old/new land in the same trail
        // every other tool call leaves — no second ledger to disagree with it.
        var receipt: [String: JSONValue] = [
            "status": .string("ok"),
            "changed": .bool(before != after),
            "page": .string(setting.page),
            "setting": .string(setting.id),
            "label": .string(setting.label),
            "old_value": before,
            "new_value": after,
            "trust_mode": .string(posture.name),
            "surface": .string(surface),
            "note": .string(
                "Set through the same in-process action the page's own control takes, so the page shows it now. "
                + "Nothing was brought forward and no click was synthesized."),
        ]
        for (key, value) in detail { receipt[key] = value }
        if let request = gated.request {
            receipt["user_request"] = .string(request)
            receipt["decided_by"] = .string("agent")
        }
        return .object(receipt)
    }
}
