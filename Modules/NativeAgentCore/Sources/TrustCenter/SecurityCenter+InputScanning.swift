import Foundation
import PersistenceCore
import Privacy
// Blueprint: | `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: audit `redactValue`, using Privacy's canonical detection predicates |

extension SwiftNativeSecurityCenter {
    static func redactValue(_ value: JSONValue, keyPath: String = "") -> JSONValue {
        if NativeAgentSecretRedactor.isSecretName(keyPath, use: .audit) {
            return .string("[REDACTED]")
        }
        switch value {
        case .string(let s):
            if NativeAgentSecretRedactor.containsAuditSecret(s) {
                return .string("[REDACTED]")
            }
            if s.count > 500 {
                return .string(String(s.prefix(500)) + "...")
            }
            return .string(s)
        case .array(let arr):
            return .array(arr.enumerated().map { idx, item in
                redactValue(item, keyPath: "\(keyPath)[\(idx)]")
            })
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (k, item) in obj {
                out[k] = redactValue(item, keyPath: keyPath.isEmpty ? k : "\(keyPath).\(k)")
            }
            return .object(out)
        default:
            return value
        }
    }

}
