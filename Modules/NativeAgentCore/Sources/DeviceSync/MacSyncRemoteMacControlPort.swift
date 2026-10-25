import Foundation
import TrustCenter
// Blueprint: | `MacSyncRemoteMacControlPort.swift` | `MacSyncRemoteMacControlPort` protocol; `loadTrustPolicy`, `run` |

/// The app route's unchanged response, before device-sync interpretation.
public struct MacSyncRemoteMacControlResult {
    public let statusCode: Int
    public let json: [String: Any]?
    public let rawData: Data

    public init(statusCode: Int, json: [String: Any]?, rawData: Data) {
        self.statusCode = statusCode
        self.json = json
        self.rawData = rawData
    }
}

@MainActor
public protocol MacSyncRemoteMacControlPort {
    func loadTrustPolicy() async throws -> TrustPolicy
    func run(path: String, bodyData: Data) async throws -> MacSyncRemoteMacControlResult
}
