import Dispatcher
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter

/// The six quiet self-administration tools.
///
/// They are app-owned (this dispatcher, like `doctor_status` and
/// `reflex_review`) because the thing they administer is the app: the live
/// `AppModel`, the rail's pages, and the controls those pages own. Core's
/// dispatcher knows nothing about any of it, and should not.
extension AppChatToolDispatcher {
    /// Consume the self-window handoff inside the original tool call, through
    /// the same app handlers (and posture checks) as direct self-administration.
    static func performMacSelfAppRoute(
        _ result: JSONValue,
        run: (String, [String: JSONValue]) async -> JSONValue
    ) async -> JSONValue {
        guard case .object(let payload) = result,
              case .object(let detail) = payload["detail"],
              detail["status"] == .string("in_process_route"),
              detail["execute_in_process"] == .bool(true),
              case .object(let next) = detail["next_action"],
              case .string(let tool) = next["tool"],
              ["interaction_act", "app_page_read"].contains(tool),
              case .object(let input) = next["input"] else { return result }
        let outcome = await run(tool, input)
        // Page inspection is supplementary after a verified app focus. Its
        // availability must not turn completed navigation into a retry.
        if tool == "app_page_read", payload["ok"] == .bool(true) {
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

    static let quietSelfAdminToolNames: Set<String> = [
        "app_page_read", "app_page_screenshot", "app_settings_list",
        "app_setting_set", "interaction_act",
    ]

    static func canonicalQuietSelfAdminToolName(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "app_page_read", "app.page_read", "app_read_page":
            return "app_page_read"
        case "app_page_screenshot", "app.page_screenshot", "app_screenshot":
            return "app_page_screenshot"
        case "app_settings_list", "app.settings_list", "app_list_settings":
            return "app_settings_list"
        case "app_setting_set", "app.setting_set", "app_set_setting":
            return "app_setting_set"
        case "interaction_act", "app.interaction_act", "card_act", "answer_card":
            return "interaction_act"
        default:
            return nil
        }
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
    struct QuietPosture: Sendable {
        let name: String
        let changesAllowed: Bool
    }

    /// The one mode that is wide open (User, 2026-09-13). Named once so the
    /// catalog's `writable` and the set's refusal cannot drift apart.
    static let fullMacModeName = "Full Mac"

    /// A posture the saved policy actually spells out, or nothing.
    ///
    /// Nothing is a refusal, never a default: a level this does not recognise
    /// (an older spelling, a hand-edited file) used to fall through to the
    /// outside-workspace axis and read as Builder, which is the permissive
    /// answer — exactly the wrong way for an unknown to fail.
    static func quietPosture(permissionLevel: String, outsideWorkspaceDefault: String) -> QuietPosture? {
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
    /// `appModel.trustPolicy` is a cached projection that a page refreshes when
    /// it feels like it, and a permissively decoded one: a policy saved as Work
    /// mode in another window kept authorizing writes here until something
    /// happened to reload it. Damaged or unreadable authority throws, and a
    /// throw is a refusal.
    static func freshQuietPosture(
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
    static func lockedPolicyIsFullMac(_ policy: [String: JSONValue]) -> Bool {
        guard case .string(let level)? = policy["permissionLevel"] else { return false }
        var outside = ""
        if case .object(let filePolicy)? = policy["filePolicy"],
           case .string(let raw)? = filePolicy["outsideWorkspaceDefault"] {
            outside = raw
        }
        return quietPosture(permissionLevel: level, outsideWorkspaceDefault: outside)?.name
            == fullMacModeName
    }

    private static func unreadablePostureFailure(extra: [String: JSONValue] = [:]) -> JSONValue {
        failure(
            "trust_mode_unreadable",
            "The saved Trust policy does not say which mode this Mac is in, so nothing is changed. "
            + "The person can set the mode in Trust.",
            extra: extra
        )
    }

    private static func failure(_ reason: String, _ detail: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var body: [String: JSONValue] = [
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
        ]
        for (key, value) in extra { body[key] = value }
        return .object(body)
    }

    private static func unattachedFailure() -> JSONValue {
        failure(
            "app_window_unavailable",
            "The app's own pages are not available in this process — there is no live window to read."
        )
    }

    private static func unknownPageFailure(_ raw: String) -> JSONValue {
        failure(
            "unknown_page",
            "No page is called that.",
            extra: ["requested": .string(raw), "pages": .array(QuietPages.ids.map { .string($0) })]
        )
    }

    // MARK: - Entry

    func runQuietSelfAdminTool(tool: String, input: [String: JSONValue], surface: String) async -> JSONValue {
        switch tool {
        case "app_page_read": return await runAppPageRead(input: input)
        case "app_page_screenshot": return await runAppPageScreenshot(input: input)
        case "app_settings_list": return await runAppSettingsList(input: input)
        case "app_setting_set": return await runAppSettingSet(input: input, surface: surface)
        case "interaction_act": return await runInteractionAct(input: input, surface: surface)
        default:
            return Self.failure("unknown_tool", "No such quiet tool.", extra: ["tool": .string(tool)])
        }
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - app_page_read

    static func pageReadResult(page: String, fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging([
            "page": .string(page),
            "page_read": .bool(true),
            "page_shown_by_this_call": .bool(false),
            "summary": .string("Read \(page) in the background; it was not opened or shown. To show it, use interaction_act(target: composer, verb: set_page, value: \(page))."),
        ]) { _, receipt in receipt })
    }

    @MainActor
    private func runAppPageRead(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        let current = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "current"
        guard let page = current ? NativeAgentAppCoordinator.shared.currentPage : QuietPages.page(named: requested) else {
            if current {
                return .object(["status": .string("failed"), "reason": .string("app_window_unavailable")])
            }
            return Self.unknownPageFailure(requested)
        }
        guard let appModel = QuietSelfAdmin.shared.appModel else { return Self.unattachedFailure() }

        let read = await QuietSelfAdminRender.pageRead(for: page, appModel: appModel)
        let posture = await Self.freshQuietPosture()
        let fullMac = posture?.name == Self.fullMacModeName
        var settingRows: [JSONValue] = []
        for setting in QuietSettings.settings(forPage: page.id) {
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
            settingRows.append(.object(row))
        }

        return Self.pageReadResult(page: page.id, fields: [
            "status": .string("ok"),
            "title": .string(page.title),
            "about": .string(page.summary),
            "settings": .array(settingRows),
            // What the page SAYS, built from the records the page draws from.
            // The accessibility tree below is kept for the rows that carry
            // words, but it is not what a page read is read from any more:
            // offscreen SwiftUI publishes almost nothing to it.
            "content": .array(read.content),
            "elements": .array(read.rows),
            "elements_truncated": .bool(read.truncated),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "changes_allowed": .bool(posture?.changesAllowed ?? false),
            "note": .string(
                "The page was read in the background, not opened or shown. To show it, use interaction_act(target: composer, verb: set_page, value: \(page.id)). `content` is the page in words, built from the "
                + "same records the page renders; `elements` is its accessibility tree. Nothing came "
                + "forward, moved, or made a sound, and the window on screen was not touched."),
        ])
    }

    // MARK: - app_page_screenshot

    @MainActor
    private func runAppPageScreenshot(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        guard let page = QuietPages.page(named: requested) else {
            return Self.unknownPageFailure(requested)
        }
        guard let appModel = QuietSelfAdmin.shared.appModel else { return Self.unattachedFailure() }
        guard let rendered = await QuietSelfAdminRender.pageImagePNG(for: page, appModel: appModel) else {
            return Self.failure("render_failed", "The page could not be drawn offscreen.")
        }
        guard case .object(var delivery) = LocalToolImage.deliverPNG(
            rendered.data, name: "\(page.id).png",
            width: rendered.width, height: rendered.height
        ) else {
            return Self.failure("image_delivery_failed", "The picture could not be handed to the model.")
        }
        delivery["page"] = .string(page.id)
        delivery["title"] = .string(page.title)
        delivery["note"] = .string(
            "An offscreen drawing of this page, not a capture of the screen. The app was not brought "
            + "forward and nothing on screen changed.")
        return .object(delivery)
    }

    // MARK: - app_settings_list

    @MainActor
    private func runAppSettingsList(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        let settings: [QuietSetting]
        var scope = "all"
        if requested.isEmpty {
            settings = QuietSettings.all
        } else {
            guard let page = QuietPages.page(named: requested) else {
                return Self.unknownPageFailure(requested)
            }
            scope = page.id
            settings = QuietSettings.settings(forPage: page.id)
        }
        let posture = await Self.freshQuietPosture()
        let fullMac = posture?.name == Self.fullMacModeName
        var catalogRows: [JSONValue] = []
        for setting in settings {
            catalogRows.append(await setting.catalogRow(fullMac: fullMac))
        }
        var body: [String: JSONValue] = [
            "status": .string("ok"),
            "page": .string(scope),
            "count": .int(Int64(settings.count)),
            "settings": .array(catalogRows),
            "pages": .array(QuietPages.all.map { .object([
                "page": .string($0.id),
                "title": .string($0.title),
                "about": .string($0.summary),
            ]) }),
        ]
        if let posture {
            body["trust_mode"] = .string(posture.name)
            body["changes_allowed"] = .bool(posture.changesAllowed)
        }
        return .object(body)
    }

    // MARK: - app_setting_set

    @MainActor
    private func runAppSettingSet(input: [String: JSONValue], surface: String) async -> JSONValue {
        let requestedPage = Self.text(input["page"])
        let requestedSetting = Self.text(input["setting"])
        guard !requestedSetting.isEmpty else {
            return Self.failure("missing_setting", "Name the setting. app_settings_list has the names.")
        }
        guard let appModel = QuietSelfAdmin.shared.appModel else { return Self.unattachedFailure() }

        guard let setting = QuietSettings.setting(id: requestedSetting) else {
            let known = requestedPage.isEmpty
                ? QuietSettings.all
                : QuietSettings.settings(forPage: QuietPages.page(named: requestedPage)?.id ?? "")
            return Self.failure(
                "unknown_setting",
                "No setting is called that. Call app_settings_list first rather than guessing a name.",
                extra: [
                    "requested": .string(requestedSetting),
                    "known": .array(known.map { .string($0.id) }),
                ]
            )
        }
        if !requestedPage.isEmpty,
           let page = QuietPages.page(named: requestedPage), page.id != setting.page {
            return Self.failure(
                "wrong_page",
                "That setting lives on a different page.",
                extra: ["setting": .string(setting.id), "page": .string(setting.page)]
            )
        }

        // The person's own posture. Refused for what it IS, not for the mode
        // the session is in — this one does not open up under Full Mac.
        if setting.ownerOnly {
            return Self.failure(
                "owner_only",
                QuietSettings.ownerOnlyRefusal,
                extra: [
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "label": .string(setting.label),
                    "value": await setting.read(appModel),
                ]
            )
        }

        guard let posture = await Self.freshQuietPosture() else {
            return Self.unreadablePostureFailure(extra: [
                "setting": .string(setting.id),
                "page": .string(setting.page),
                "value": await setting.read(appModel),
            ])
        }
        guard posture.changesAllowed else {
            return Self.failure(
                "trust_mode_read_only",
                "\(posture.name) is the posture that changes nothing at all — it is the person's "
                + "standing choice to be read from and not written to, and only they lift it.",
                extra: [
                    "trust_mode": .string(posture.name),
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "value": await setting.read(appModel),
                ]
            )
        }
        // Full Mac is wide open, and only there may the agent move the Trust
        // fence — down, never up. Below it these read and refuse, saying the
        // one thing that never changes: turning Full Mac ON is the person's.
        if setting.fullMacOnly, posture.name != Self.fullMacModeName {
            return Self.failure(
                "trust_posture_needs_full_mac",
                QuietSettings.belowFullMacRefusal,
                extra: [
                    "trust_mode": .string(posture.name),
                    "setting": .string(setting.id),
                    "page": .string(setting.page),
                    "value": await setting.read(appModel),
                ]
            )
        }
        guard let write = setting.write else {
            return Self.failure(
                "not_writable",
                "That one is shown, not set.",
                extra: ["setting": .string(setting.id), "page": .string(setting.page)]
            )
        }
        guard let requestedValue = input["value"], requestedValue != .null else {
            return Self.failure(
                "missing_value", "Pass the new value.",
                extra: ["setting": .string(setting.id), "type": .string(setting.kind.rawValue)]
            )
        }

        // The receipt's "before" is read from the page's own state, immediately
        // before the write, so it is what the person would have seen.
        let before = await setting.read(appModel)
        QuietWriteDetail.begin()
        do {
            try await write(appModel, requestedValue)
        } catch {
            // A write that touches several surfaces says which ones it had
            // already changed before it failed and rolled them back, so the
            // receipt cannot quietly under-report its own reach.
            var extra: [String: JSONValue] = [
                "setting": .string(setting.id),
                "page": .string(setting.page),
                "value": before,
            ]
            for (key, value) in QuietWriteDetail.take() { extra[key] = value }
            return Self.failure("write_refused", error.localizedDescription, extra: extra)
        }
        let detail = QuietWriteDetail.take()
        let after = await setting.read(appModel)

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
        return .object(receipt)
    }
}
