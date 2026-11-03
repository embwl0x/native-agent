import Foundation
import NativeAgentShared

// Blueprint: | `PhoneLocalSettings.swift` | Phone-local setting descriptors compose owner-declared controls; signed requests read current owners and use the phone's existing consent sheet for raises |

@MainActor
enum PhoneSettingWrite {
    struct Admission: Sendable {
        let pairing: String
        let expiresAt: Date
        let approved: Bool
        let stillAuthorized: @MainActor @Sendable () -> Bool
    }
    @TaskLocal static var current: Admission?

    /// Rechecked inside asynchronous owners, after any queued person change.
    /// A card approves this request, never a different request or pairing.
    static func check(raising: Bool = false) throws {
        guard let admission = current else { return } // Direct phone UI is the person's own act.
        guard admission.expiresAt > Date(),
              admission.stillAuthorized(),
              admission.pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else {
            throw PhoneLocalSetting.failure("The phone request ended, expired or pairing changed before this effect. Read the current setting before another change.")
        }
        guard !raising || admission.approved else {
            throw PhoneLocalSetting.failure("This now raises phone sharing authority. Ask again so the phone can show its approval sheet.")
        }
    }
}

/// The declaration lives beside each control's owner. This composition stores
/// no values: every read and write reaches that owner on the phone.
@MainActor
struct PhoneLocalSetting {
    let id: String
    let label: String
    let type: String
    var choices: [String] = []
    let read: () throws -> String
    /// A collection owner must be readable before an absent child can be judged.
    var ownsChildSettings = false
    var write: ((String) async throws -> Void)?
    var approval: (String) throws -> Bool = { _ in false }

    func row() -> MobileAppSetting {
        do {
            return MobileAppSetting(id: id, page: "pairing", label: label, type: type,
                choices: choices, writable: write != nil, value: try read())
        } catch {
            return MobileAppSetting(id: id, page: "pairing", label: label, type: type,
                choices: choices, writable: false, value: nil, unavailableReason: error.localizedDescription)
        }
    }

    static func boolean(_ value: String) throws -> Bool {
        guard value == "true" || value == "false" else { throw failure("This phone switch takes true or false.") }
        return value == "true"
    }

    static func failure(_ message: String) -> DeviceSyncError { .underlying(message: message) }
}

@MainActor
enum PhoneLocalSettings {
    static func controls() async -> [PhoneLocalSetting] {
        await PhoneSenses.shared.restorationTask?.value
        await PhonePlaces.shared.restorationTask?.value
        return [NativeAgentAppearance.settingControl, HazeSwatches.settingControl, PhoneTurnActivity.shared.settingControl]
            + PhoneSenses.shared.settingControls + PhonePlaces.shared.settingControls
    }

    static func validate(_ request: PhoneRequest) -> Bool {
        if request.kind == .settingsRead { return request.params.isEmpty || Set(request.params.keys) == ["id"] }
        if request.kind == .settingsWrite { return Set(request.params.keys) == ["id", "value"] }
        return request.params.isEmpty
    }

    static func needsApproval(_ request: PhoneRequest) async throws -> Bool {
        guard request.kind == .settingsWrite, let id = request.params["id"], let value = request.params["value"] else { return false }
        let control = try Self.control(id: id, among: await controls())
        return try control.approval(value)
    }

    private static func control(id: String, among controls: [PhoneLocalSetting]) throws -> PhoneLocalSetting {
        if let control = controls.first(where: { $0.id == id }) { return control }
        for owner in controls where owner.ownsChildSettings && id.hasPrefix(owner.id + ".") {
            _ = try owner.read()
        }
        throw PhoneLocalSetting.failure("The phone supplied no control for this id. Read phone.settings for current ids and any owner-read errors.")
    }

    static func perform(_ request: PhoneRequest, approved: Bool, pairing: String,
                        stillAuthorized: @escaping @MainActor @Sendable () -> Bool) async throws -> [String: String] {
        return try await PhoneSettingWrite.$current.withValue(.init(pairing: pairing, expiresAt: request.expiresAt,
                                                                  approved: approved, stillAuthorized: stillAuthorized)) {
        let controls = await controls()
        try PhoneSettingWrite.check()
        guard let id = request.params["id"] else {
            guard request.kind == .settingsRead else { throw PhoneLocalSetting.failure("Name the phone setting.") }
            return ["settings": String(decoding: try JSONEncoder().encode(controls.map { $0.row() }), as: UTF8.self)]
        }
        let control = try Self.control(id: id, among: controls)
        if request.kind == .settingsWrite {
            guard let value = request.params["value"], let write = control.write else { throw PhoneLocalSetting.failure("This control is read only. Use its named Settings page.") }
            try PhoneSettingWrite.check(raising: control.approval(value))
            try await write(value)
        }
        return ["setting": String(decoding: try JSONEncoder().encode(control.row()), as: UTF8.self)]
        }
    }
}
