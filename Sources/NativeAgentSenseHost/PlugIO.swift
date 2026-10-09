import Darwin
import Foundation
import Senses

/// Bounded JSON lines. App-served reply waits are not sense execution stalls.
/// Buffered input is also forwarded to Swift children through this owner.
final class PlugIO {
    static let maximumLineBytes = 24 * 1024 * 1024
    private var pending = Data()

    func receive() throws -> [String: Any]? {
        while true {
            if let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                pending.removeSubrange(...end)
                guard line.count <= Self.maximumLineBytes,
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw SenseFailure(code: "bad_input", message: "Sense plug requires bounded JSON objects.")
                }
                return object
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SenseFailure(code: "source_unavailable", message: "Sense plug input failed.") }
            if count == 0 {
                guard pending.isEmpty else { throw SenseFailure(code: "bad_input", message: "Incomplete JSON line on sense plug.") }
                return nil
            }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= Self.maximumLineBytes + buffer.count else {
                throw SenseFailure(code: "bad_input", message: "Sense plug line exceeds 24 MiB.")
            }
        }
    }

    func send(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard bytes.count <= Self.maximumLineBytes else {
            throw SenseFailure(code: "bad_output", message: "Sense output exceeds 24 MiB.")
        }
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }

    func fail(id: Int?, _ failure: SenseFailure) {
        var object: [String: Any] = ["type": "failed", "failure": ["code": failure.code, "message": failure.message]]
        if let id { object["id"] = id }
        do { try send(object) } catch { exit(1) }
    }
}
