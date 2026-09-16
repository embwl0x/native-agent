import AVFoundation
import Dispatcher
import Foundation
import MultimodalTTS
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
    static let quietSelfAdminToolNames: Set<String> = [
        "app_page_read", "app_page_screenshot", "app_settings_list",
        "app_setting_set", "interaction_act", "voice_render",
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
        case "voice_render", "voice.render", "tts_render":
            return "voice_render"
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
                return QuietPosture(name: "Work mode", changesAllowed: false)
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
        case "voice_render": return await runVoiceRender(input: input)
        default:
            return Self.failure("unknown_tool", "No such quiet tool.", extra: ["tool": .string(tool)])
        }
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - app_page_read

    @MainActor
    private func runAppPageRead(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        guard let page = QuietPages.page(named: requested) else {
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

        return .object([
            "status": .string("ok"),
            "page": .string(page.id),
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
                "Read from an offscreen copy of the page. `content` is the page in words, built from the "
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
                "\(posture.name) lets the agent read this app's settings but not change them. "
                + "Builder or Full Mac allows changes; the person sets that in Trust.",
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

    // MARK: - voice_render

    /// Speech with no speaker. Nothing here constructs an `AVAudioPlayer` or an
    /// `AVAudioEngine` output node: the local route uses
    /// `AVSpeechSynthesizer.write`, which hands back buffers and never reaches
    /// an output device, and the cloud route is a plain HTTPS body written to a
    /// file. There is no code path from this function to the speakers.
    private func runVoiceRender(input: [String: JSONValue]) async -> JSONValue {
        let text = Self.text(input["text"])
        guard !text.isEmpty else {
            return Self.failure("missing_text", "Pass the words to render.")
        }
        guard text.count <= 4096 else {
            return Self.failure(
                "text_too_long",
                "voice_render takes up to 4096 characters; this is \(text.count).")
        }
        let requestedRoute = Self.text(input["route"]).lowercased()

        // Rendering is a WRITE: this leaves a file on the person's disk that
        // outlives the call. It therefore stands behind the same posture gate
        // app_setting_set stands behind, read the same fresh way.
        guard let posture = await Self.freshQuietPosture() else {
            return Self.unreadablePostureFailure()
        }
        guard posture.changesAllowed else {
            return Self.failure(
                "trust_mode_read_only",
                "\(posture.name) does not let the agent write files, and rendering a voice writes one. "
                + "Builder or Full Mac allows it; the person sets that in Trust.",
                extra: ["trust_mode": .string(posture.name)]
            )
        }

        let dataRoot = PersistenceCore.defaultDataRoot()
        let directory = dataRoot.appendingPathComponent("voice_renders", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return Self.failure("render_directory_unavailable", error.localizedDescription)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let handle = UUID().uuidString.prefix(8).lowercased()

        if requestedRoute == "cloud" {
            return await renderCloudVoice(
                text: text, directory: directory, basename: "voice-\(stamp)-\(handle)")
        }
        return await renderLocalVoice(
            text: text,
            voice: Self.text(input["voice"]),
            directory: directory,
            basename: "voice-\(stamp)-\(handle)"
        )
    }

    private func renderLocalVoice(
        text: String, voice requestedVoice: String, directory: URL, basename: String
    ) async -> JSONValue {
        let url = directory.appendingPathComponent("\(basename).caf")
        let voice: AVSpeechSynthesisVoice? = requestedVoice.isEmpty
            ? nil
            : (AVSpeechSynthesisVoice(identifier: requestedVoice)
                ?? AVSpeechSynthesisVoice(language: requestedVoice))
        if !requestedVoice.isEmpty, voice == nil {
            return Self.failure(
                "unknown_voice",
                "No Mac voice matches that identifier or language.",
                extra: ["requested": .string(requestedVoice)]
            )
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice { utterance.voice = voice }
        let voiceName = utterance.voice?.name ?? voice?.name ?? "the Mac default voice"
        let voiceIdentifier = utterance.voice?.identifier ?? voice?.identifier ?? ""

        let synthesizer = AVSpeechSynthesizer()
        var file: AVAudioFile?
        var frames: Int64 = 0
        var sampleRate: Double = 0
        var writeFailure: String?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    finished = true
                    writeFailure = "The Mac voice returned audio in a shape this cannot write."
                    continuation.resume()
                    return
                }
                // A zero-length buffer is how AVSpeechSynthesizer says "done".
                guard pcm.frameLength > 0 else {
                    finished = true
                    continuation.resume()
                    return
                }
                do {
                    if file == nil {
                        file = try AVAudioFile(
                            forWriting: url, settings: pcm.format.settings,
                            commonFormat: pcm.format.commonFormat,
                            interleaved: pcm.format.isInterleaved
                        )
                        sampleRate = pcm.format.sampleRate
                    }
                    try file?.write(from: pcm)
                    frames += Int64(pcm.frameLength)
                } catch {
                    finished = true
                    writeFailure = error.localizedDescription
                    continuation.resume()
                }
            }
        }
        file = nil

        if let writeFailure {
            try? FileManager.default.removeItem(at: url)
            return Self.failure("render_failed", writeFailure)
        }
        guard frames > 0, sampleRate > 0 else {
            try? FileManager.default.removeItem(at: url)
            return Self.failure("render_empty", "The Mac voice produced no audio for that text.")
        }
        let bytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return .object([
            "status": .string("ok"),
            "route": .string("mac"),
            "voice": .string(voiceName),
            "voice_identifier": .string(voiceIdentifier),
            "path": .string(url.path),
            "format": .string("caf"),
            "bytes": .int(Int64(bytes ?? 0)),
            "duration_seconds": .double((Double(frames) / sampleRate * 100).rounded() / 100),
            "characters": .int(Int64(text.count)),
            "note": .string("Written to a file. Nothing was played and the speakers were not opened."),
        ])
    }

    private func renderCloudVoice(text: String, directory: URL, basename: String) async -> JSONValue {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let snapshot = try? await routing.checkedRoutingSnapshot()
        let provider = snapshot.flatMap {
            ProviderRoutingSurfaceLookup.value($0.activeProviders, "chat")
        } ?? snapshot
            .flatMap { ProviderRoutingSurfaceLookup.value($0.preferences, "chat") }
            .flatMap { routing.inferProviderForModel($0.model) }
        guard let provider,
              let model = FirstPartyModelCatalog.speechModel(forProviderID: provider) else {
            return Self.failure(
                "route_has_no_speech",
                "The provider Chat runs on has no cloud voice. Pass route \"mac\" to use the Mac voice."
            )
        }
        let audio: Data
        do {
            audio = try await SwiftOpenAITTSClient(model: model)
                .synthesize(text: text, voice: VoicePreference.cloudVoice(), format: "mp3")
        } catch {
            return Self.failure("render_failed", error.localizedDescription)
        }
        let url = directory.appendingPathComponent("\(basename).mp3")
        do {
            try audio.write(to: url, options: .atomic)
        } catch {
            return Self.failure("render_failed", error.localizedDescription)
        }
        // A metadata read, not a player: nothing is scheduled and no output
        // device is opened.
        let duration = (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
        return .object([
            "status": .string("ok"),
            "route": .string("cloud"),
            "voice": .string(VoicePreference.cloudVoice()),
            "model": .string(model),
            "path": .string(url.path),
            "format": .string("mp3"),
            "bytes": .int(Int64(audio.count)),
            "duration_seconds": .double(duration.isFinite ? (duration * 100).rounded() / 100 : 0),
            "characters": .int(Int64(text.count)),
            "note": .string("Written to a file. Nothing was played and the speakers were not opened."),
        ])
    }
}
