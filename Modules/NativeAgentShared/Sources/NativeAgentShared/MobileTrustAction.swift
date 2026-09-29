import Foundation

/// Closed, non-secret requests accepted only from a verified paired phone.
public enum MobileTrustAction: Sendable {
    case preset(Preset, confirmed: Bool)
    case policy(Field, value: String, confirmed: Bool)

    public enum Preset: String, CaseIterable, Sendable {
        case safe, workMode = "work_mode", builder, fullMac = "full_mac"

        public init?(permissionLevel: String) {
            switch permissionLevel {
            case "strict": self = .safe
            case "balanced": self = .workMode
            default: return nil
            }
        }

        public var title: String {
            switch self {
            case .safe: "Safe"
            case .workMode: "Work mode"
            case .builder: "Builder"
            case .fullMac: "Full Mac"
            }
        }
    }

    public enum Field: String, CaseIterable, Sendable {
        case permissionLevel, autonomyDefault, requireBackups, outsideDefault, developerMode
        case workshopEnabled, showTimeline, autonomousTraining, dreamScheduler

        public var values: [String] {
            switch self {
            case .permissionLevel: ["strict", "balanced"] // Full Mac uses the complete preset.
            case .autonomyDefault: ["supervised", "app_data_autonomous", "workspace_autonomous"]
            case .outsideDefault: ["deny", "ask", "allow"]
            default: ["false", "true"]
            }
        }
    }

    public init?(payload: [String: String]) {
        guard let confirmedRaw = payload["confirmed"], ["true", "false"].contains(confirmedRaw) else { return nil }
        let confirmed = confirmedRaw == "true"
        if Set(payload.keys) == ["preset", "confirmed"], let preset = Preset(rawValue: payload["preset"] ?? "") {
            guard preset != .fullMac || confirmed else { return nil }
            self = .preset(preset, confirmed: confirmed)
        } else if Set(payload.keys) == ["field", "value", "confirmed"],
                  let field = Field(rawValue: payload["field"] ?? ""),
                  let value = payload["value"], field.values.contains(value), confirmed {
            // Outside Allow grants Full Mac authority. Only the complete preset
            // may grant it, after presenting the shared Full Mac disclosure.
            guard field != .outsideDefault || value != "allow" else { return nil }
            self = .policy(field, value: value, confirmed: confirmed)
        } else {
            return nil
        }
    }

    public var payload: [String: String] {
        switch self {
        case .preset(let preset, let confirmed):
            ["preset": preset.rawValue, "confirmed": String(confirmed)]
        case .policy(let field, let value, let confirmed):
            ["field": field.rawValue, "value": value, "confirmed": String(confirmed)]
        }
    }

    public static let fullMacTitle = "Enable Full Mac access?"
    public static let outsideFullMacRefusal = "Full Mac allows access outside workspaces. Choose Safe, Work mode, or Builder before changing Outside default."
    public static let fullMacButton = "Enable Full Mac"
    public static let fullMacMessage = """
    I will be able to read and modify files anywhere, run shell commands, control the system, and move or trash files across app surfaces.

    Workspace actions run autonomously, and access outside workspaces is allowed. Pre-write backups stay on.

    Full Mac does not bypass macOS itself. Documents, Desktop, Downloads, and other protected folders still need their own approval in System Settings → Privacy & Security → Files and Folders (or Full Disk Access) before anything can read them.
    """
}
