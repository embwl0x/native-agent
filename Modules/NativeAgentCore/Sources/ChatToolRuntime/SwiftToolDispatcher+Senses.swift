import Foundation
import MacControl
import PersistenceCore
import Senses

extension SwiftToolDispatcher {
    func senseAppCorner(_ input: [String: JSONValue]) -> SenseCorner? {
        let source = defaultMacAXElementSource()
        let requested = jsonString(input["app"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
              case .string(let path)? = fields["path"], case .int(let bytes)? = fields["bytes"] else {
            throw SenseFailure(code: "source_unavailable", message: "The original file reader did not admit this file.")
        }
        return .file(path: path, bytes: Int(bytes))
    }
}
