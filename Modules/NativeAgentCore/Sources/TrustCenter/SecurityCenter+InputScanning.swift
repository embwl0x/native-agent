import Foundation
import PersistenceCore
import Privacy
// Blueprint: | `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: audit `redactValue`, using Privacy's canonical detection predicates |

extension SwiftNativeSecurityCenter {
    /// A preview, never the whole input: a background ability's full packet in every audit row grew the record by hundreds of megabytes a day.
    /// The whole preview has one bound, whatever the input's shape; past it the row keeps the start and says how much there was.
    static func redactValue(_ value: JSONValue) -> JSONValue {
        let kept = redactNode(value)
        guard let text = try? kept.serialize(pretty: false), text.utf8.count > previewBytes else { return kept }
        return .object(["start": .string(String(decoding: text.utf8.prefix(previewBytes), as: UTF8.self)), "bytes": .int(Int64(text.utf8.count))])
    }

    private static func redactNode(_ value: JSONValue, keyPath: String = "", depth: Int = 0) -> JSONValue {
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
            guard depth < previewDepth else { return .string("[\(arr.count) items]") }
            var kept = arr.prefix(previewItems).enumerated().map { idx, item in
                redactNode(item, keyPath: "\(keyPath)[\(idx)]", depth: depth + 1)
            }
            if arr.count > previewItems { kept.append(.string("+\(arr.count - previewItems) more")) }
            return .array(kept)
        case .object(let obj):
            guard depth < previewDepth else { return .string("[\(obj.count) fields]") }
            var out: [String: JSONValue] = [:]
            for k in obj.keys.sorted().prefix(previewFields) {
                out[k] = redactNode(obj[k] ?? .null, keyPath: keyPath.isEmpty ? k : "\(keyPath).\(k)", depth: depth + 1)
            }
            if obj.count > previewFields { out["+more"] = .int(Int64(obj.count - previewFields)) }
            return .object(out)
        default:
            return value
        }
    }
    private static let previewDepth = 5, previewItems = 12, previewFields = 32, previewBytes = 4_096

}
