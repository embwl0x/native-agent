import PersistenceCore
import AppToolRuntime
import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import TriggerScheduler
import TrustCenter
// Blueprint: | `SettingsFace.swift` | Settings rows: registry, notification policy and triggers, search service; every control and action is its setting.set or verb call |

public enum SettingsFaceChange {
    public static let platform = Notification.Name("NativeAgent.settingsFace.platformChanged")
    static let cognition = Notification.Name("NativeAgent.settingsFace.cognitionChanged")
}

/// Platform-only rows stay beside their owners; every door receives the same rows, each action its own call.
@MainActor
public protocol SettingsFaceHost: QuietSettingsHost {
    func settingsFaceExtrasSnapshot() -> any SettingsFaceExtrasSnapshot
}

/// Platform owners copy plain in-memory values on main; the snapshot shapes its rows off main.
public protocol SettingsFaceExtrasSnapshot: Sendable {
    func sections() -> [PartFace.Section]
}

/// A setting's control or action calls `setting.set` on that setting, the same call the agent makes; the change arrives as `value`.
func settingSetCall(_ id: String, _ value: PartFace.Value? = nil) -> PartFace.Call {
    PartFace.Call("setting.set", value.map { ["setting": .string(id), "value": $0] } ?? ["setting": .string(id)])
}

extension NativeAgentEngine {
    private struct SettingsSnapshot: Sendable {
        let settings: [QuietSetting.ReadSnapshot]
        let search: QuietSetting.Descriptor?
        let extras: any SettingsFaceExtrasSnapshot
    }

    @MainActor
    private func settingsFaceSnapshot() async throws -> SettingsSnapshot {
        guard hasBody,
              let host = ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false).quietHost() as? any SettingsFaceHost,
              host.dataRootOverride == dataRoot else {
            throw PartCallError(code: "settings_unavailable", message: "Settings are not mounted for this agent. Open the Mac app and read Settings again.")
        }
        var settings: [QuietSetting.ReadSnapshot] = []
        for setting in try QuietSettings.settings(forPage: "settings", host: host) {
            try Task.checkCancellation()
            settings.append(try await setting.snapshot(host: host))
        }
        let search = try QuietSettings.settings(forPage: "desk", host: host).first { $0.id == Self.searchService }?.descriptor
        return SettingsSnapshot(settings: settings, search: search, extras: host.settingsFaceExtrasSnapshot())
    }

    @concurrent
    func settingsFace() async throws -> (PartFace, UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let snapshot = try await settingsFaceSnapshot()
        async let notificationRead = settingsFaceNotifications()
        async let searchRead = settingsFaceSearchService(setting: snapshot.search)
        async let statusRead = settingsFaceStatus()
        var rows: [PartFace.Row] = []
        for setting in snapshot.settings {
            try Task.checkCancellation()
            rows.append(try await settingsFaceRow(setting))
        }
        let (notifications, search, status) = try await (notificationRead, searchRead, statusRead)
        let extras = snapshot.extras.sections()
        return (PartFace(title: "Settings", line: "These make up who I am. Everything else I carry is below.", sections: [
            .init(id: "preferences", title: "Preferences", style: .list,
                  footer: snapshot.settings.isEmpty ? "The settings registry returned no controls." : nil,
                  rows: Self.preferenceGroups(rows, search: search)),
            notifications,
        ] + status + extras), epoch)
    }

    private static let notificationsMaster = "notifications.raise_unasked"
    private static let searchService = "research.search_url"

    /// Preferences as a person names them, in page order: each group's settings in the order drawn. A setting no group names is drawn
    /// in Other, so every setting the registry puts on this page stays on it.
    private static let preferenceGroupMembers: [(id: String, title: String, settings: [String])] = [
        ("preferences.reach", "Where I reach you", ["notifications.channel_push", "notifications.channel_telegram",
                                                    "notifications.channel_in_app", "notifications.delivery_receipts"]),
        ("preferences.reading", "What I can read", ["settings.image_understanding", "settings.pdf_reading"]),
        ("preferences.memory", "Memory", ["memories.knowledge_graph", "memories.cross_session", "memories.recur_to_facts",
                                          "memories.meaning_based", "settings.memory_in_every_reply"]),
        ("preferences.inner_life", "Inner life", ["settings.inner_life", "settings.inner_life_background", "settings.reflection",
                                                  "settings.organism_kernel", "settings.wander_hour", "settings.inner_life_capsule",
                                                  "personality.dreams", "personality.rem_cycle", "personality.self_improvement"]),
        ("preferences.look", "How I look", ["settings.dark_mode", "settings.haze_color", "settings.view_mode"]),
        ("preferences.shortcuts", "Shortcuts", ["settings.global_hotkey", "settings.shotgun_shortcut"]),
    ]
    /// Developer dials, drawn last under Advanced with the search service.
    private static let advancedSettings = ["settings.developer_surfaces", "settings.daily_reflection_budget"]

    /// One parent row per group whose nested rows are its settings' own rows, unchanged; a group with none of its settings is not drawn.
    private static func preferenceGroups(_ rows: [PartFace.Row], search: PartFace.Row) -> [PartFace.Row] {
        let named = Set(preferenceGroupMembers.flatMap { $0.settings } + advancedSettings)
        let members: ([String]) -> [PartFace.Row] = { ids in ids.flatMap { id in rows.filter { $0.id == id } } }
        var groups = preferenceGroupMembers.map { (id: $0.id, title: $0.title, rows: members($0.settings)) }
        groups.append((id: "preferences.other", title: "Other", rows: rows.filter { !named.contains($0.id) }))
        groups.append((id: "preferences.advanced", title: "Advanced", rows: members(advancedSettings) + [search]))
        return groups.filter { !$0.rows.isEmpty }.map { group in
            // A setting that could not be read marks its group, so a closed group never hides the failure.
            PartFace.Row(id: group.id, title: group.title, value: groupValue(group.rows),
                         tone: group.rows.contains { $0.tone == .failed } ? .failed : nil, rows: group.rows)
        }
    }

    /// A group's state in a few words: how many of its switches are on, each choice's selection, and how many could not be read.
    private static func groupValue(_ rows: [PartFace.Row]) -> String? {
        let switches = rows.compactMap { $0.control?.on }
        let on = switches.filter { $0 }.count
        var words: [String] = []
        if !switches.isEmpty { words.append(on == switches.count ? "All on" : on == 0 ? "None on" : "\(on) of \(switches.count) on") }
        words += rows.compactMap { row in
            row.control?.selected.flatMap { selected in row.control?.options?.first(where: { $0.id == selected })?.label }
        }
        let unavailable = rows.filter { $0.tone == .failed }.count
        if unavailable > 0 { words.append("\(unavailable) unavailable") }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// Raising things unasked and its triggers read from the Trust and inbox owners; while the master is off its triggers are not offered.
    private func settingsFaceNotifications() async throws -> PartFace.Section {
        let history = PartFace.Row(id: "notifications.history", title: "Notification history",
                                   detail: "Every note raised, archived and dismissed ones included, under Earlier on Inbox.", open: "page:inbox")
        let master: Bool
        do { master = try await trust.inboxEnabled() }
        catch is CancellationError { throw CancellationError() }
        catch {
            return .init(id: "notifications", title: "Notifications", style: .list,
                         footer: "Notification options are unavailable until this setting can be read.", rows: [
                .init(id: Self.notificationsMaster, title: "Raise things unasked",
                      detail: UserFacingError.message(error, action: "read the notification setting"), value: "Unavailable", tone: .failed),
                history,
            ])
        }
        var rows: [PartFace.Row] = [.init(id: Self.notificationsMaster, title: "Raise things unasked",
            detail: "When on, observations, file changes, finished Desk tasks and check-ins arrive without being asked.",
            control: .toggle(master, call: settingSetCall(Self.notificationsMaster)))]
        var footer: String? = "Nothing is raised unasked while this is off."
        if master {
            do {
                let triggers = try await inbox.triggers()
                rows += triggers.map {
                    PartFace.Row(id: QuietSettings.inboxTriggerPrefix + $0.name, title: Self.triggerTitle($0.name), detail: Self.triggerNote($0.name) ?? $0.description,
                          control: .toggle($0.enabled, call: settingSetCall(QuietSettings.inboxTriggerPrefix + $0.name)))
                }
                footer = triggers.isEmpty ? "No notification options are configured yet." : nil
            } catch is CancellationError { throw CancellationError() }
            catch {
                rows.append(.init(id: "notifications.triggers", title: "Notification options unavailable",
                                  detail: UserFacingError.message(error, action: "load triggers"), tone: .failed))
                footer = nil
            }
        }
        return .init(id: "notifications", title: "Notifications", style: .list, footer: footer, rows: rows + [history])
    }

    /// The built-in brief says what it is beside a helper that may also send one; any other trigger keeps its own description.
    private static func triggerNote(_ name: String) -> String? {
        name == "morning_brief" ? "My own built-in daily brief at the set hour. A helper that sends a brief is separate and listed on Helpers." : nil
    }

    /// A trigger's name as the person reads it.
    private static func triggerTitle(_ name: String) -> String {
        switch name {
        case "idle_checkin": return "Idle check-in"
        case "morning_brief": return "Built-in morning brief"
        default:
            let words = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            guard let first = words.first else { return name }
            return String(first).uppercased() + words.dropFirst()
        }
    }

    /// The search service is read from its saved configuration; a field sends the address, and Find sends auto, through the registry's write.
    private func settingsFaceSearchService(setting: QuietSetting.Descriptor?) async throws -> PartFace.Row {
        guard let setting else {
            return .init(id: Self.searchService, title: "Search service", detail: "The settings registry has no search service setting.",
                         value: "Unavailable", tone: .failed)
        }
        let placeholder = "http://localhost:8888, or auto"
        // Find is the search service's own discovery: the same write as typing auto.
        let find = [PartFace.Action(id: "find", label: "Find", call: settingSetCall(setting.id, .string("auto")))]
        do {
            let url = try await configuration.readSearXNG(dataRoot: dataRoot)
            return .init(id: setting.id, title: setting.label, detail: setting.note,
                         value: url.isEmpty ? "No search service configured." : nil, actions: find,
                         control: .field(url, placeholder: placeholder, call: settingSetCall(setting.id)))
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .init(id: setting.id, title: setting.label,
                         detail: UserFacingError.message(error, action: "load the search service"), value: "Unavailable", tone: .failed,
                         actions: find, control: .field("", placeholder: placeholder, call: settingSetCall(setting.id)))
        }
    }

    private func settingsFaceRow(_ snapshot: QuietSetting.ReadSnapshot) async throws -> PartFace.Row {
        let setting = snapshot.setting
        // The face is the person's: every writable setting draws its control, whose call setting.set's one law decides for whoever makes it.
        let editable = setting.editable
        let call = settingSetCall(setting.id)
        let offered = snapshot.choices
        do {
            let value = try await snapshot.value(dataRoot: dataRoot)
            let control: PartFace.Control?
            if !editable {
                control = nil
            } else {
                switch (setting.kind, value) {
                // Meaning-based memory re-indexes every saved memory when it changes, so it asks first, as the Mac's control always has.
                case (.boolean, .bool(let on)) where setting.id == "memories.meaning_based":
                    control = .toggle(on, confirm: on ? "Turn off meaning-based memory? Saved memories are re-indexed."
                        : "Turn on meaning-based memory? Saved memories are re-indexed.", call: call)
                case (.boolean, .bool(let on)): control = .toggle(on, call: call)
                case (.choice, .string(let selected)):
                    guard let offered else {
                        throw QuietSettingError.unavailable("\(setting.label) supplied no choices.")
                    }
                    guard offered.contains(selected) else {
                        throw QuietSettingError.unavailable("The saved choice \(selected) is not offered by \(setting.label).")
                    }
                    control = .choice(offered.map { .init(id: $0, label: $0) }, selected: selected, call: call)
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
                             choices.isEmpty ? nil : .choice(choices.map { .init(id: $0, label: $0) }, selected: nil, call: call)
                         } : nil)
        }
    }

    private func settingsFaceText(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let text): return text.isEmpty ? "Empty" : text
        case .null: return "No value supplied"
        default: return try value.serialize(pretty: false)
        }
    }
}
