import Darwin
import Foundation
import PersistenceCore
import SenseCore
// Blueprint: | `Sources/NativeAgentSenseHost/PlugIO.swift` | Bounded binary plug frames |

final class PlugIO {
    private func read(_ count: Int, allowEOF: Bool = false) throws(SenseFailure) -> NSMutableData? {
        guard let bytes = NSMutableData(length: count) else {
            throw SenseFailure(code: "resource_limit", message: "Could not allocate plug frame.")
        }
        var offset = 0
        while offset < count {
            let n = unsafe Darwin.read(STDIN_FILENO, bytes.mutableBytes.advanced(by: offset), count - offset)
            if n < 0, errno == EINTR { continue }
            if n == 0, offset == 0, allowEOF { return nil }
            guard n > 0 else { throw SenseFailure(code: "bad_frame", message: "Plug closed during a frame.") }
            offset += n
        }
        return bytes
    }

    func receive() throws -> [String: Any]? {
        guard let prefix = try read(10, allowEOF: true) else { return nil }
        let (flags, head, size) = try PlugFrame.lengths(prefix as Data)
        guard let header = try read(head),
              case .object(let fields) = try JSONValue.parse(header as Data) else {
            throw SenseFailure(code: "bad_frame", message: "Plug header requires a JSON object.")
        }
        var object = fields.mapValues(\.foundationObject)
        if flags == 1, var material = object["material"] as? [String: Any], material["kind"] as? String == "file" {
            material["data"] = try read(size)
            object["material"] = material
        } else if flags == 2, let type = object["type"] as? String,
                  ["host_reply", "source_reply", "act_reply", "app_reply", "state_reply"].contains(type) {
            object["payload"] = try read(size)
        } else if flags != 0 {
            throw SenseFailure(code: "bad_frame", message: "Unexpected plug attachment.")
        }
        return object
    }

    func send(_ object: [String: Any], payload: Data? = nil) throws {
        let frame = try PlugFrame(header: JSONValue(fromFoundation: object),
                                  flags: payload == nil ? 0 : 2, payload: payload ?? Data())
        try FileHandle.standardOutput.write(contentsOf: frame.encoded())
    }

    func fail(id: Int?, _ failure: SenseFailure, entry: Bool = false) {
        var object: [String: Any] = ["type": entry ? "entry_failed" : "failed", "failure": ["code": failure.code, "message": failure.message]]
        if let id { object["id"] = id }
        do { try send(object) } catch { exit(1) }
    }

    func fatal(id: Int?, _ error: Error) -> Never {
        fail(id: id, SenseFailure(error, code: "crashed"))
        exit(1)
    }
}
