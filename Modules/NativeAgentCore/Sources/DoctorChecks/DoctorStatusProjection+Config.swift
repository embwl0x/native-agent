import Foundation

extension DoctorStatusProjection {
    public static func readAutoDoctorConfig(dataRoot: URL) -> AutoDoctorConfig {
        let path = dataRoot
            .appendingPathComponent("auto_doctor", isDirectory: true)
            .appendingPathComponent("config.json")
        let object: [String: Any]
        if let data = try? Data(contentsOf: path),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = value
        } else {
            object = [:]
        }
        var config = AutoDoctorConfig()
        config.enabled = boolValue(object["enabled"])
        config.runOnStartup = boolValue(object["run_on_startup"])
        config.intervalSeconds = intValue(object["interval_seconds"])
        config.usesModelCalls = boolValue(object["uses_model_calls"])
        config.checkLLM = boolValue(object["check_llm"])
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
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
