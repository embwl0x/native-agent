import PersistenceCore
import AppToolRuntime
import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import TrustCenter
// Blueprint: | `SettingsFace.swift` | Settings face reads the registry; person controls use its owner setters, agent controls retain setting.set admission |

public enum SettingsFaceChange {
    public static let platform = Notification.Name("NativeAgent.settingsFace.platformChanged")
    static let cognition = Notification.Name("NativeAgent.settingsFace.cognitionChanged")
}

/// Platform-only references and actions stay beside their owners; every door receives the same rows.
@MainActor
public protocol SettingsFaceHost: QuietSettingsHost {
    func settingsFaceExtras() async throws -> [PartFace.Section]
    func settingsFaceAction(row: String, action: String) async throws -> String?
}

extension NativeAgentEngine {
    @MainActor
    private func settingsFaceHost() throws -> any SettingsFaceHost {
        guard hasBody,
              let host = ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false).quietHost() as? any SettingsFaceHost,
              host.dataRootOverride == dataRoot else {
            throw PartCallError(code: "settings_unavailable", message: "Settings are not mounted for this agent. Open the Mac app and read Settings again.")
        }
        return host
    }

    @MainActor
    func settingsFace() async throws -> (PartFace, UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let host = try settingsFaceHost()
        let settings = try QuietSettings.settings(forPage: "settings", host: host)
        var rows: [PartFace.Row] = []
        for setting in settings {
            try Task.checkCancellation()
            rows.append(try await settingsFaceRow(setting, host: host))
        }
        let status = try await settingsFaceStatus()
        let extras = try await host.settingsFaceExtras()
        return (PartFace(title: "Settings", line: "These make up who I am. Everything else I carry is below.", sections: [
            .init(id: "preferences", title: "Preferences", style: .list,
                  footer: settings.isEmpty ? "The settings registry returned no controls." : nil, rows: rows),
        ] + status + extras), epoch)
    }

    @MainActor
    private func settingsFaceRow(_ setting: QuietSetting, host: any SettingsFaceHost) async throws -> PartFace.Row {
        let editable = setting.write != nil && !setting.ownerOnly && !setting.fullMacOnly && !setting.readsAnotherDevice
        var offered: [String]?
        do {
            if setting.kind == .choice { offered = try await setting.liveChoices?({ host }) ?? setting.choices }
            let value = try await setting.read(host)
            let control: PartFace.Control?
            if !editable {
                control = nil
            } else {
                switch (setting.kind, value) {
                // Meaning-based memory re-indexes every saved memory when it changes, so it asks first, as the Mac's control always has.
                case (.boolean, .bool(let on)) where setting.id == "memories.meaning_based":
                    control = .toggle(on, confirm: on ? "Turn off meaning-based memory? Saved memories are re-indexed."
                        : "Turn on meaning-based memory? Saved memories are re-indexed.")
                case (.boolean, .bool(let on)): control = .toggle(on)
                case (.choice, .string(let selected)):
                    guard let offered else {
                        throw QuietSettingError.unavailable("\(setting.label) supplied no choices.")
                    }
                    guard offered.contains(selected) else {
                        throw QuietSettingError.unavailable("The saved choice \(selected) is not offered by \(setting.label).")
                    }
                    control = .choice(offered.map { .init(id: $0, label: $0) }, selected: selected)
                case (.boolean, _), (.choice, _):
                    throw QuietSettingError.unavailable("\(setting.label) returned a value that does not match its declared type.")
                default: control = nil
                }
            }
            return .init(id: setting.id, title: setting.label, detail: setting.note,
                         value: control == nil ? try settingsFaceText(value) : nil,
                         open: setting.id == "settings.daily_reflection_budget" ? "page:cognition" : nil, control: control)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // One unreadable setting never erases its readable siblings or invents an off switch.
            return .init(id: setting.id, title: setting.label,
                         detail: [setting.note, error.localizedDescription].filter { !$0.isEmpty }.joined(separator: " "),
                         value: "Unavailable", tone: .failed,
                         control: editable ? offered.flatMap { choices in
                             choices.isEmpty ? nil : .choice(choices.map { .init(id: $0, label: $0) }, selected: nil)
                         } : nil)
        }
    }

    @MainActor
    func settingsAct(row: String, action: String, value: String?, by actor: PartFaces.Actor) async throws -> String? {
        do { return try await applySettingsAct(row: row, action: action, value: value, by: actor) }
        catch {
            // A failed registration or readback can follow a committed preference; show what its owner now knows.
            await settle { _ = await self.pages.refresh(page: "settings") }
            if error is CancellationError { throw error }
            if let owned = error as? PartCallError { throw owned }
            throw PartCallError(code: "setting_failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func applySettingsAct(row: String, action: String, value: String?, by actor: PartFaces.Actor) async throws -> String? {
        let host = try settingsFaceHost()
        // The recovery button is the same setting write, with the same actor, as its switch.
        if row == "inner-life-status", action == "enable-inner-life" {
            return try await applySettingsAct(row: "settings.inner_life", action: "set", value: "on", by: actor)
        }
        guard action == "set" else {
            guard case .person = actor else {
                throw PartCallError(code: "person_only", message: "This action opens a Mac control for the person. Use the app's own actions instead.")
            }
            return try await host.settingsFaceAction(row: row, action: action)
        }
        guard let setting = try QuietSettings.settings(forPage: "settings", host: host).first(where: { $0.id == row }),
              !setting.ownerOnly, !setting.fullMacOnly, !setting.readsAnotherDevice, let write = setting.write else {
            throw PartCallError(code: "setting_not_writable", message: "This row has no editable Settings control. Read Settings again.")
        }
        guard let value else { throw PartCallError(code: "missing_value", message: "Pass the control's new value.") }
        let wanted: JSONValue
        switch setting.kind {
        case .boolean:
            guard value == "on" || value == "off" else {
                throw PartCallError(code: "bad_value", message: "A Settings switch takes on or off.")
            }
            wanted = .bool(value == "on")
        case .choice: wanted = .string(value)
        case .text, .number, .list:
            throw PartCallError(code: "no_field", message: "This face shows the value; use its existing editor or setting.set to change it.")
        }
        if case .agent(let turn) = actor {
            // Keep the agent's actual turn and setting.set's complete admission, lower-only checks and receipts.
            let result = try await ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), true).execute(
                tool: "app", input: ["action": .string("setting.set"),
                                     "args": .object(["setting": .string(setting.id), "value": wanted])],
                surface: "app", turn: turn)
            guard result.objectValue?["status"] == .string("ok") else {
                throw PartCallError(code: "setting_refused", message: try result.serialize(pretty: false))
            }
            return try result.serialize(pretty: false)
        }
        // Only the person's Mac or authenticated phone gesture carries owner authority.
        let turn = Turn().with(\.settingByOwner, true)
        let detail = QuietWriteDetail()
        try await write(host, wanted, QuietSettingWrite(turn: turn, detail: detail))
        let saved = try await setting.read(host)
        let evidence = try detail.take().sorted { $0.key < $1.key }.map { try "\($0.key): " + settingsFaceText($0.value) }
        return ([setting.label + ": " + (try settingsFaceText(saved))] + evidence).joined(separator: "\n")
    }

    private func settingsFaceText(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let text): return text.isEmpty ? "Empty" : text
        case .null: return "No value supplied"
        default: return try value.serialize(pretty: false)
        }
    }
}
