import Foundation
import MacControl
import PersistenceCore
import Senses
// Blueprint: | `SwiftToolDispatcher+Senses.swift` | `SwiftToolDispatcher`: sense corner resolution and authorized raw material adapters |

extension SwiftToolDispatcher {
    func senseAppCorner(_ input: [String: JSONValue]) -> SenseCorner? {
        let source = defaultMacAXElementSource()
        let requested = input["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target: MacAXAppInfo?
        if requested.isEmpty { target = source.frontmostApp() }
        else if case .matched(let app) = MacBackgroundSight.resolve(requested, among: source.runningApps()) { target = app }
        else { target = nil }
        return target?.bundleIdentifier.map { .app(bundleID: $0) }
    }

    static func senseTextMaterial(_ result: JSONValue) throws -> SenseMaterial {
        if case .string(let text) = result { return .text(text) }
        guard case .object(let fields) = result, fields["ok"] != .bool(false) else {
            throw SenseFailure(code: "source_unavailable", message: "The original reader refused this read.")
        }
        if case .string(let text)? = fields["text"] { return .text(text) }
        if case .object(let output)? = fields["output"], case .string(let text)? = output["text"] { return .text(text) }
        return .accessibility(result)
    }

    static func senseFileMaterial(_ result: JSONValue) throws -> SenseMaterial {
        guard case .object(let fields) = result, fields["ok"] == .bool(true),
              case .string(let path)? = fields["path"], case .string(let content)? = fields["content"] else {
            throw SenseFailure(code: "source_unavailable", message: "The original file reader did not admit this file.")
        }
        let data: Data
        if fields["encoding"] == .string("base64") {
            guard let decoded = Data(base64Encoded: content) else {
                throw SenseFailure(code: "source_unavailable", message: "The file reader returned invalid base64 material.")
            }
            data = decoded
        } else { data = Data(content.utf8) }
        return .file(path: path, bytes: data.count, data: data)
    }
}
