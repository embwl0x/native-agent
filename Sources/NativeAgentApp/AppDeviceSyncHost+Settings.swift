import AppToolRuntime
import Foundation
import NativeAgentShared
import PersistenceCore

/// The phone's settings door: the settings page's own registry
/// (`QuietSettings`), each row read and written through the closures its page
/// control uses. A signed phone is User, so the writes run as his
/// (`QuietSettings.byOwner`): what the Mac's pages let him change, the phone
/// changes. Trust reads here and changes only through the phone's Trust editor.
extension AppDeviceSyncHost {
    @MainActor
    func appSettings() async throws -> [MobileAppSetting] {
        let host = try Self.settingsHost()
        var rows: [MobileAppSetting] = []
        for setting in QuietSettings.all(host: host) {
            rows.append(await Self.row(setting, host: host))
        }
        return rows
    }

    @MainActor
    func setAppSetting(id: String, value: String, actionID: String, clientID: String) async throws -> MobileAppSetting {
        let host = try Self.settingsHost()
        guard let setting = QuietSettings.all(host: host).first(where: { $0.id == id }) else {
            throw SettingsDoorError("No setting is called \(id). Refresh the settings list.")
        }
        guard Self.writable(setting), let write = setting.write else {
            throw SettingsDoorError("\(setting.label) is changed on the Trust page.")
        }
        let wanted = try Self.jsonValue(value, kind: setting.kind, label: setting.label)
        try await PhoneSettingChange.$current.withValue(PhoneSettingChange(actionID: actionID, clientID: clientID)) {
            try await QuietSettings.$byOwner.withValue(true) {
                try await write(host, wanted)
            }
        }
        return await Self.row(setting, host: host)
    }

    @MainActor
    private static func settingsHost() throws -> AppQuietSettingsHost {
        guard let appModel = QuietSelfAdmin.shared.appModel else {
            throw SettingsDoorError("The Mac's settings are not loaded yet. Try again in a moment.")
        }
        return AppQuietSettingsHost(appModel)
    }

    /// Every row with a setter, except Trust: its posture and the switches
    /// that raise it stay with the Trust editor.
    private static func writable(_ setting: QuietSetting) -> Bool {
        setting.write != nil && !setting.ownerOnly && !setting.fullMacOnly && setting.page != "trust"
    }

    @MainActor
    private static func row(_ setting: QuietSetting, host: AppQuietSettingsHost) async -> MobileAppSetting {
        MobileAppSetting(
            id: setting.id, page: setting.page, label: setting.label, type: setting.kind.rawValue,
            choices: await setting.liveChoices?({ host }) ?? setting.choices,
            writable: writable(setting),
            value: text(await setting.read(host))
        )
    }

    private static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .string(let raw): return raw
        case .array(let items): return items.map(text).joined(separator: "\n")
        case .object: return (try? value.serialize(pretty: false)) ?? ""
        }
    }

    private static func jsonValue(_ text: String, kind: QuietSetting.Kind, label: String) throws -> JSONValue {
        switch kind {
        case .boolean:
            switch text.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw SettingsDoorError("\(label) takes true or false.")
            }
        case .number: return Int64(text.trimmingCharacters(in: .whitespaces)).map(JSONValue.int) ?? .string(text)
        case .list: return .array(text.components(separatedBy: .newlines).map(JSONValue.string))
        case .text, .choice: return .string(text)
        }
    }
}

/// The signed phone action a setting write is running for, so a row whose
/// store keeps a provenance receipt records the phone, not the Mac.
struct PhoneSettingChange: Sendable {
    @TaskLocal static var current: PhoneSettingChange?
    let actionID: String
    let clientID: String
}

private struct SettingsDoorError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
