import ChatTurnContracts
import ChatToolRuntime
import ChatToolParsing
import ChatSessionWork
import Dispatcher
import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Privacy
import TrustCenter
// Blueprint: | `AppToolExecutor+QuietSelfAdmin.swift` | `AppToolExecutor`, `performMacSelfAppRoute`, `behind`, `quietPosture`, `freshQuietPosture`; posture |

/// Core owns admission, catalog reads and receipts; mounted rendering and controls stay behind presentation ports.
extension AppToolExecutor {
    /// Finish self-window handoffs inside the originating gated call through the same app-door checks as direct calls.
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
        // Only a verified navigation keeps its success when its subsequent look fails.
        if input["action"] == nil, case .object(let navigation)? = detail["navigation"], navigation["ok"] == .bool(true) {
            var response = payload
            response["ok"] = .bool(true)
            response["in_process_observation"] = outcome
            var observationDetail = detail
            observationDetail.removeValue(forKey: "next_action")
            observationDetail.removeValue(forKey: "execute_in_process")
            response["detail"] = .object(observationDetail)
            return .object(response)
        }
        guard case .object(var response) = outcome else { return outcome }
        response["ok"] = .bool(response["status"] == .string("ok"))
        // Self-window look retains the app behind it so observation does not lose the user's context.
        if case .string(let behind)? = detail["behind"] { response["behind"] = .string(behind) }
        return .object(response)
    }

    // MARK: - Posture

    /// Work and Builder share balanced permissionLevel; outside-workspace writes (deny/ask) distinguish them.
    /// App settings admission uses ownerOnly/fullMacOnly independently of Mac effects and workspace fences.
    /// Permission acquisition follows docs/TOOL_LOADING.md#authority-and-receipts.
    public struct QuietPosture: Sendable {
        public let name: String
        let changesAllowed: Bool
    }

    /// One Full Mac name keeps catalog writability and write refusals aligned.
    public static let fullMacModeName = "Full Mac"

    /// Name the saved PermissionLaw posture; Work with outside-workspace writes on ask is Builder.
    public static func quietPosture(_ policy: [String: JSONValue]) -> QuietPosture {
        switch PermissionLaw.posture(policy) {
        case .fullMac: return QuietPosture(name: fullMacModeName, changesAllowed: true)
        case .readOnly: return QuietPosture(name: "Safe", changesAllowed: false)
        case .work:
            let outside: JSONValue? = if case .object(let file)? = policy["filePolicy"] { file["outsideWorkspaceDefault"] } else { nil }
            return QuietPosture(name: outside == .string("ask") ? "Builder" : "Work mode", changesAllowed: true)
        }
    }

    /// Read checked saved authority at the gate boundary; cached UI projections cannot authorize writes. Unreadable authority refuses.
    public static func freshQuietPosture(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> QuietPosture? {
        guard let policy = try? await SwiftNativeTrustCenter(dataRoot: dataRoot)
            .loadTrustPolicyChecked() else { return nil }
        return quietPosture(policy)
    }

    /// Authority-bearing writes recheck Full Mac inside the transaction against the exact locked generation they merge into.
    public static func lockedPolicyIsFullMac(_ policy: [String: JSONValue]) -> Bool {
        PermissionLaw.posture(policy) == .fullMac
    }

    static func unreadablePostureFailure(extra: [String: JSONValue] = [:]) -> JSONValue {
        failure(
            "trust_mode_unreadable",
            "The saved Trust policy does not say which mode this Mac is in, so nothing is changed. "
            + "The person can set the mode in Trust.",
            extra: extra
        )
    }

    /// Other app writes share setting.set's posture gate; nil means changes are allowed.
    static func readOnlyFailure(_ posture: QuietPosture) -> JSONValue {
        failure(
            "trust_mode_read_only",
            "\(posture.name) is the posture that changes nothing at all, and only the person lifts it. "
            + "Ask them to choose Work mode or above in Trust.",
            extra: ["trust_mode": .string(posture.name)]
        )
    }

    /// Refusals run nothing; a caller that already acted supplies its own effects in extra.
    public static func failure(_ reason: String, _ detail: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var body: [String: JSONValue] = [
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
        ]
        // The code, status and detail stand: extra never overwrites them.
        body.merge(extra) { own, _ in own }
        return ChatToolOutcome.refusedBeforeRunning(.object(body))
    }

    public static func unattachedFailure() -> JSONValue {
        doorRefusal(
            "app_window_unavailable",
            "The app's own pages are not available in this process — there is no live window to read.",
            remedy: "correct_arguments", "Call app from the installed app's chat tool chain; supplying a session id cannot attach a live window."
        )
    }

    public static func unknownPageFailure(_ raw: String, pages: [String]) -> JSONValue {
        doorRefusal("unknown_page", "No page is called that.", remedy: "read_index",
            "Read the page index, then select a listed page id.", next: [:],
            extra: ["requested": .string(raw), "pages": .array(pages.map { .string($0) })])
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chat

    /// Full Mac permits user effects. Below it, only verified user-started turns may move their screen, speak or touch their conversation.
    static func reachesUser(surface: String, fullMac: Bool, dataRoot: URL, turn: Turn) async throws -> Bool {
        if fullMac { return true }
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        let door = envelope.surface.lowercased()
        var user = turn.origin == nil && envelope.agent == nil
            && MyQueue.Door(rawValue: door) != nil
        if user, ["telegram", "slack"].contains(door) {
            user = try await SwiftNativeSecurityCenter(dataRoot: dataRoot).remoteSenderIsAllowlisted(.currentTurn(
                turn: turn, surface: surface))
        }
        return user
    }

    /// Chat actions re-read posture for receipts; app-owned screen and conversation fences still apply.
    @MainActor
    func runChatSessionAction(
        verb: String, input: [String: JSONValue], surface: String, host: any QuietToolHost, turn: Turn
    ) async -> JSONValue {
        guard let posture = await Self.freshQuietPosture(
            dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ) else { return Self.unreadablePostureFailure() }
        guard posture.changesAllowed else { return Self.readOnlyFailure(posture) }
        let reachesUser: Bool
        do { reachesUser = try await Self.reachesUser(surface: surface, fullMac: posture.name == Self.fullMacModeName,
                                               dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot(), turn: turn) }
        catch { return ChatToolOutcome.failure(error: error, tool: "chat_session", effects: ToolFailureError.Effects.none) }
        let answer = await host.runChatSession(verb: verb, input: input, reachesUser: reachesUser, turn: turn)
        guard case .object(var body) = answer else {
            return Self.doorRefusal("handler_result_missing", "The conversation handler returned no structured result; its effects are unknown.",
                remedy: "inspect", "Read the conversation's current state before another change.",
                next: ["page": .string("chat"), "item": input["session_id"] ?? .string("")], extra: ["effects": .string("unknown"), "verb": .string(verb)])
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

    /// Setting rows carry types, choices and notes so page reads supply the complete setting.set contract.
    @MainActor
    func runAppPageRead(input: [String: JSONValue], turn: Turn) async -> JSONValue {
        let requested = Self.text(input["page"])
        if requested.lowercased() == "context" { return await presentation.contextReceiptRead(input: input) }
        if requested.lowercased() == "agent_view" { return await presentation.agentViewRead(input: input) }
        let current = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "current"
        guard let page = current ? presentation.currentPage : presentation.page(named: requested) else {
            if current {
                return Self.doorRefusal("app_window_unavailable", "No app window is showing a page right now.",
                    remedy: "select_page", "Read the page index and name a page instead of current.", next: [:])
            }
            do { return Self.unknownPageFailure(requested, pages: try presentation.pages.map(\.id)) }
            catch { return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none) }
        }
        guard let appModel = quietHost() else { return Self.unattachedFailure() }

        let content = await appModel.pageRead(page, turn: turn)
        let posture = await Self.freshQuietPosture()
        let fullMac = posture?.name == Self.fullMacModeName
        var settingRows: [JSONValue] = []
        let settings: [QuietSetting]
        do { settings = try QuietSettings.settings(forPage: page.id, host: quietHost()) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none) }
        for setting in settings {
            do {
                if case .object(let listed) = try await setting.catalogRow(fullMac: fullMac, host: { self.quietHost() }) {
                    var row = listed.filter { ["id", "label", "type", "choices", "note", "writable", "owner_only", "full_mac_only"].contains($0.key) }
                    if setting.readsAnotherDevice {
                        row["read_with"] = .object(["action": .string("setting.get"),
                            "args": .object(["setting": .string(setting.id)])])
                    } else {
                        row["value"] = try await setting.read(appModel)
                    }
                    if setting.fullMacOnly && !fullMac { row["refusal"] = listed["refusal"] }
                    settingRows.append(.object(row))
                }
            } catch {
                // A row in the list is that setting, unavailable: it keeps its id like its siblings.
                settingRows.append(.object(["id": .string(setting.id),
                    "unavailable": Self.settingReadFailure(error, setting: setting)]))
            }
        }

        return Self.pageReadResult(page: page.id, fields: [
            "status": .string("ok"),
            "title": .string(page.title),
            "about": .string(page.summary),
            "settings": .array(settingRows),
            // Build text from the same records the page draws.
            "content": .array(content),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "changes_allowed": .bool(posture?.changesAllowed ?? false),
        ])
    }

    // MARK: - Setting set

    private struct GatedSetting {
        let setting: QuietSetting
        let host: any QuietToolHost
        let posture: QuietPosture?
        let value: JSONValue
        let request: String?
        let restoresPrevious: Bool
        let write: @MainActor @Sendable (any QuietSettingsHost, JSONValue, QuietSettingWrite) async throws -> Void
    }

    /// Resolve settings, posture, row fences and value before mutation.
    @MainActor
    private func settingGate(input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> Result<GatedSetting, GateRefusal> {
        func refuse(_ answer: JSONValue) -> Result<GatedSetting, GateRefusal> { .failure(GateRefusal(answer: answer)) }
        let requestedPage = Self.text(input["page"])
        let requestedSetting = Self.text(input["setting"])
        guard !requestedSetting.isEmpty else {
            return refuse(Self.failure("missing_setting", "Name the setting. Its page read (app {page}) has the names."))
        }
        guard let appModel = quietHost() else { return refuse(Self.unattachedFailure()) }

        let checked: QuietSetting?
        do { checked = try await QuietSettings.setting(id: requestedSetting, host: quietHost()) }
        catch { return refuse(Self.settingReadFailure(error, requestedSetting: requestedSetting)) }
        guard let setting = checked else {
            let known: [QuietSetting]
            do {
                known = try requestedPage.isEmpty
                    ? QuietSettings.all(host: quietHost())
                    : QuietSettings.settings(forPage: presentation.page(named: requestedPage)?.id ?? "", host: quietHost())
            } catch { return refuse(ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)) }
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

        let currentValue: JSONValue
        do { currentValue = try await setting.read(appModel) }
        catch { return refuse(Self.settingReadFailure(error, setting: setting)) }

        // User-owned posture controls remain user-only regardless of session mode or Full Mac.
        if setting.ownerOnly {
            return refuse(Self.failure(
                "owner_only",
                QuietSettings.ownerOnlyRefusal,
                extra: [
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "label": .string(setting.label),
                    "requested_value": input["value"] ?? .null,
                    "current_value": currentValue,
                ]
            ))
        }

        var request: String?
        var restoresPrevious = false
        if case .object(let receipt) = execution.undoReceipt {
            guard receipt["setting"] == .string(setting.id), receipt["old_value"] == input["value"],
                  receipt["new_value"] == currentValue else {
                return refuse(Self.failure("stale_setting", "The setting changed after that receipt. Read its page again. Nothing was written."))
            }
            request = Self.text(receipt["user_request"])
            restoresPrevious = true
        } else if !setting.mindOwned, turn.runtime != nil,
                  await Self.freshQuietPosture()?.name != Self.fullMacModeName {
            // Under Full Mac the agent's own dials are its own (owner-only rows refused above); below it a change needs the person's words.
            request = Self.text(input["because"])
            guard let request, request.split(whereSeparator: \.isWhitespace).count >= 3,
                  let restores = await turn.settingRequestEvidence?(setting.id, input["value"] ?? .null, currentValue, request) else {
                return refuse(Self.failure("setting_not_requested",
                    "No one asked to change \(setting.id); quote the request in because. Nothing changed.",
                    extra: ["setting": .string(setting.id), "effects": .string("none"), "changed": .bool(false)]))
            }
            restoresPrevious = restores
        }

        var posture: QuietPosture?
        if !setting.mindOwned {
            guard let checkedPosture = await Self.freshQuietPosture() else {
                return refuse(Self.unreadablePostureFailure(extra: [
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "requested_value": input["value"] ?? .null,
                    "current_value": currentValue,
                ]))
            }
            posture = checkedPosture
        }
        if let posture, !posture.changesAllowed {
            return refuse(Self.failure(
                "trust_mode_read_only",
                "\(posture.name) is the posture that changes nothing at all — it is the person's "
                + "standing choice to be read from and not written to, and only they lift it.",
                extra: [
                    "trust_mode": .string(posture.name),
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "requested_value": input["value"] ?? .null,
                    "current_value": currentValue,
                ]
            ))
        }
        // Only Full Mac may lower Trust; raising to Full Mac always requires the person.
        if setting.fullMacOnly, posture?.name != Self.fullMacModeName {
            return refuse(Self.failure(
                "trust_posture_needs_full_mac",
                QuietSettings.belowFullMacRefusal,
                extra: [
                    "trust_mode": .string(posture?.name ?? "unreadable"),
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "requested_value": input["value"] ?? .null,
                    "current_value": currentValue,
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
        if setting.id.hasPrefix("providers."), setting.id != "providers.routing_repair" {
            do {
                _ = try await SwiftNativeProviderRouting(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()).checkedRoutingSnapshot()
            } catch {
                return refuse(await Self.settingWriteFailure(error, setting, requestedValue, host: appModel, detail: ["effects": .string("none")]))
            }
        }
        return .success(GatedSetting(setting: setting, host: appModel, posture: posture, value: requestedValue, request: request,
            restoresPrevious: restoresPrevious, write: write))
    }

    /// Preview shares every pre-write check; each write rechecks its lower/narrow-only value rule against current state.
    @MainActor
    func settingRefusal(input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue? {
        switch await settingGate(input: input, turn: turn, execution: execution) {
        case .failure(let refusal): return refusal.answer
        case .success(let gated):
            let admitted = turn.with(\.settingFullMac, gated.posture?.name == Self.fullMacModeName)
                .with(\.restoresPreviousSetting, gated.restoresPrevious)
            guard let refused = await gated.setting.check?(gated.host, gated.value, admitted) else { return nil }
            return await Self.settingWriteFailure(refused, gated.setting, gated.value, host: gated.host, detail: ["effects": .string("none")])
        }
    }

    @MainActor
    private static func settingReadFailure(_ error: Error, setting: QuietSetting? = nil, requestedSetting: String? = nil) -> JSONValue {
        var extra: [String: JSONValue] = ["effects": .string("none")]
        if let setting {
            extra["setting"] = .string(setting.id)
            extra["page"] = .string(setting.page)
        } else if let requestedSetting {
            extra["setting"] = .string(requestedSetting)
        }
        if let failure = error as? ToolFailureError, let owner = failure.owner {
            extra["remedy"] = Repair.remedy(owner: owner,
                nextCall: failure.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }, tap: failure.tap)
        }
        return failure("read_unavailable", error.localizedDescription, extra: extra)
    }

    /// Failed settings writes retain requested/current values; Trust raises below Full Mac remain owners_call.
    @MainActor
    private static func settingWriteFailure(
        _ error: Error, _ setting: QuietSetting, _ requestedValue: JSONValue, host: any QuietToolHost,
        detail: [String: JSONValue] = [:]
    ) async -> JSONValue {
        var extra: [String: JSONValue] = [
            "setting": .string(setting.id),
            "page": .string(setting.page),
            "requested_value": requestedValue,
        ]
        do { extra["current_value"] = try await setting.read(host) }
        catch { extra["readback_failure"] = settingReadFailure(error, setting: setting) }
        switch error {
        case QuietSettingError.badValue, QuietSettingError.users: break
        default: extra["effects"] = .string("unknown")
        }
        for (key, value) in detail { extra[key] = value }
        if let failure = error as? ToolFailureError, let owner = failure.owner {
            extra["effects"] = .string(failure.effects.rawValue)
            extra["remedy"] = Repair.remedy(owner: owner,
                nextCall: failure.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }, tap: failure.tap)
        }
        let code = if case QuietSettingError.users = error { "owners_call" } else { "write_refused" }
        return failure(code, error.localizedDescription, extra: extra)
    }

    /// setting.get reads the same page-owned state and names as setting.set.
    @MainActor
    func runAppSettingGet(input: [String: JSONValue], turn: Turn) async -> JSONValue {
        let requested = Self.text(input["setting"])
        guard !requested.isEmpty else {
            return Self.failure("missing_setting", "Name the setting. Its page read (app {page}) has the names.")
        }
        guard let appModel = quietHost() else { return Self.unattachedFailure() }
        do {
        guard let setting = try await QuietSettings.setting(id: requested, host: appModel) else {
            return Self.failure("unknown_setting",
                "No setting is called that. Read its page first for the names (app {page}) rather than guessing one.",
                extra: ["requested": .string(requested), "known": .array(try QuietSettings.all(host: appModel).map { .string($0.id) })])
        }
        do {
            var reply: [String: JSONValue] = ["status": .string("ok"), "effects": .string("none"), "read_only": .bool(true),
                            "setting": .string(setting.id), "page": .string(setting.page), "label": .string(setting.label),
                            "kind": .string(setting.kind.rawValue), "value": try await setting.read(appModel)]
            if setting.kind == .boolean { reply["accepted_values"] = .array([.bool(false), .bool(true)]) }
            let posture = setting.mindOwned ? nil
                : await Self.freshQuietPosture(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            if case .object(let catalog) = try await setting.catalogRow(
                fullMac: posture?.name == Self.fullMacModeName, host: { self.quietHost() }
            ) {
                for key in ["choices", "note", "writable", "owner_only", "full_mac_only", "refusal"] {
                    reply[key] = catalog[key]
                }
            }
            if setting.mindOwned {
                reply["writable"] = .bool(setting.writable(fullMac: false))
            } else if let posture {
                if !posture.changesAllowed {
                    reply["writable"] = .bool(false)
                    reply["refusal"] = .string("\(posture.name) permits reads only. The person changes this in Trust.")
                }
            } else {
                reply["writable"] = .bool(false)
                reply["refusal"] = .string("The saved Trust policy is unreadable; no setting change is authorized.")
            }
            return .object(reply)
        } catch { return Self.settingReadFailure(error, setting: setting) }
        } catch { return Self.settingReadFailure(error, requestedSetting: requested) }
    }

    @MainActor
    func runAppSettingSet(input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async -> JSONValue {
        let gated: GatedSetting
        switch await settingGate(input: input, turn: turn, execution: execution) {
        case .failure(let refusal): return refusal.answer
        case .success(let ready): gated = ready
        }
        let (setting, appModel, posture, requestedValue, write) = (gated.setting, gated.host, gated.posture, gated.value, gated.write)

        // The receipt's "before" is read from the page's own state, immediately before the write, so it is what the person would have seen.
        let before: JSONValue
        do { before = try await setting.read(appModel) }
        catch { return Self.settingReadFailure(error, setting: setting) }
        // Below Full Mac, the row refuses raises; Full Mac permits them with a decided row for the user.
        var raise = false
        if posture?.name == Self.fullMacModeName,
           case QuietSettingError.users? = await setting.check?(appModel, requestedValue, turn) {
            raise = true
        }
        let writeDetail = QuietWriteDetail()
        let admitted = turn.with(\.settingFullMac, posture?.name == Self.fullMacModeName)
            .with(\.restoresPreviousSetting, gated.restoresPrevious)
        do {
            if case .object(let receipt) = execution.undoReceipt,
               receipt["new_value"] != (try await setting.read(appModel)) {
                throw QuietSettingError.unavailable("The setting changed after that receipt. Read its page again. Nothing was written.")
            }
            try await write(appModel, requestedValue, QuietSettingWrite(turn: admitted, detail: writeDetail))
        } catch {
            // Multi-surface failures report every surface already touched so rollback cannot understate actual reach.
            let touched = writeDetail.take()
            return await Self.settingWriteFailure(error, setting, requestedValue, host: appModel, detail: touched)
        }
        let detail = writeDetail.take()
        let after: JSONValue
        do { after = try await setting.read(appModel) }
        catch {
            return await Self.settingWriteFailure(error, setting, requestedValue, host: appModel,
                detail: detail.merging(["effects": .string("unknown")]) { _, new in new })
        }
        if raise {
            HarnessDecidedRow.post(turn: turn, requester: "Full Mac", tool: "setting.set \(setting.id)",
                                   sessionID: input["__session_id"]?.scalarText,
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        }

        // The tool result is the receipt persisted in the transcript; a second ledger would diverge.
        var receipt: [String: JSONValue] = [
            "status": .string("ok"),
            "changed": .bool(before != after),
            "page": .string(setting.page),
            "setting": .string(setting.id),
            "label": .string(setting.label),
            "old_value": before,
            "new_value": after,
            "surface": .string(surface),
            "note": .string(
                "Set through the same in-process action the page's own control takes, so the page shows it now. "
                + "Nothing was brought forward and no click was synthesized."),
        ]
        if let posture { receipt["trust_mode"] = .string(posture.name) }
        for (key, value) in detail { receipt[key] = value }
        if let request = gated.request {
            receipt["user_request"] = .string(request)
            receipt["decided_by"] = .string("agent")
        }
        return .object(receipt)
    }
}
