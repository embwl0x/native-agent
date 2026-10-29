import Foundation
// Blueprint: | `DoctorStatusProjection+Config.swift` | `AutoDoctorConfig`; `DoctorReadout`: `readAutoDoctorConfig`, `boolValue`, `intValue` |

public struct AutoDoctorConfig: Codable, Hashable, Sendable {
    public var enabled: Bool?
    public var runOnStartup: Bool?
    public var intervalSeconds: Int?
    public var readError: String?
    public init() {}
}

extension DoctorReadout {
    public static func readAutoDoctorConfig(dataRoot: URL) -> AutoDoctorConfig {
        let path = dataRoot
            .appendingPathComponent("auto_doctor", isDirectory: true)
            .appendingPathComponent("config.json")
        var config = AutoDoctorConfig()
        do {
            let data: Data
            do { data = try Data(contentsOf: path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return config }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            config.enabled = boolValue(object["enabled"])
            config.runOnStartup = boolValue(object["run_on_startup"])
            config.intervalSeconds = intValue(object["interval_seconds"])
            guard (object["enabled"] == nil || config.enabled != nil),
                  (object["run_on_startup"] == nil || config.runOnStartup != nil),
                  (object["interval_seconds"] == nil || (config.intervalSeconds.map { $0 >= 3600 } ?? false)) else {
                throw CocoaError(.propertyListReadCorrupt)
            }
        } catch {
            config.enabled = false
            config.runOnStartup = false
            config.readError = "Auto Doctor configuration is unavailable at \(path.path): \(error.localizedDescription). Its bytes were preserved; repair this file before automatic diagnostics can run."
        }
        return config
    }

    public static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    public static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return Int(number.stringValue) }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
