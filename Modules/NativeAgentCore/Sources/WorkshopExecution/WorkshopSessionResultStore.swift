import Foundation
import NativeAgentCore
import PersistenceCore
import Desk

/// Durable terminal handoff between the one-turn runner and Desk settlement.
/// It is a reconciliation record, not a second task owner: Desk remains the
/// visible/canonical lifecycle and this file is deleted only by retention.
public struct WorkshopSessionResultStore: Sendable {
    let dataRoot: URL
    let platform: any WorkshopPumpPlatform

    public init(dataRoot: URL, platform: any WorkshopPumpPlatform) {
        self.dataRoot = dataRoot
        self.platform = platform
    }

    private var directory: URL {
        dataRoot.appendingPathComponent("workshop/session_results", isDirectory: true)
    }

    func path(reservationId: String) -> URL? {
        guard let safe = try? platform.validateArtifactComponent(reservationId) else { return nil }
        return directory.appendingPathComponent("\(safe).json")
    }

    public func save(_ receipt: WorkshopSessionReceipt) -> Bool {
        guard let path = path(reservationId: receipt.reservationId) else { return false }
        let row: JSONValue = .object([
            "version": .int(1),
            "handle": .string(receipt.handle),
            "reservationId": .string(receipt.reservationId),
            "status": .string(receipt.status.rawValue),
            "summary": .string(String(receipt.summary.prefix(600))),
            "model": receipt.model.map(JSONValue.string) ?? .null,
            "artifactPaths": .array(receipt.artifactPaths.map(JSONValue.string)),
            "disposition": .string(receipt.disposition.rawValue),
            "generatedAt": .string(NativeTimestampFormat.fractionalZulu(receipt.generatedAt)),
        ])
        do {
            let data = try row.serializedData(pretty: false)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
            return true
        } catch {
            nativeLog("[workshop] terminal result durability failed for %@: %@",
                  receipt.reservationId, String(describing: error))
            return false
        }
    }

    public func load(reservationId: String) -> WorkshopSessionReceipt? {
        guard let path = path(reservationId: reservationId),
              let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data),
              case .object(let object) = value,
              case .string(let handle)? = object["handle"],
              case .string(let storedID)? = object["reservationId"], storedID == reservationId,
              case .string(let statusRaw)? = object["status"],
              let status = WorkshopSessionStatus(rawValue: statusRaw),
              case .string(let summary)? = object["summary"],
              case .string(let generatedRaw)? = object["generatedAt"],
              let generatedAt = NativeTimestampFormat.parseISO8601FractionalFirst(generatedRaw) else { return nil }
        let model: String? = if case .string(let value)? = object["model"] { value } else { nil }
        let artifacts: [String] = if case .array(let values)? = object["artifactPaths"] {
            values.compactMap { if case .string(let value) = $0 { value } else { nil } }
        } else { [] }
        let disposition: DeskWorkDisposition = if case .string(let raw)? = object["disposition"] {
            DeskWorkDisposition(rawValue: raw) ?? .progress
        } else { .progress }
        return WorkshopSessionReceipt(
            handle: handle,
            reservationId: reservationId,
            status: status,
            summary: summary,
            model: model,
            artifactPaths: artifacts,
            generatedAt: generatedAt,
            disposition: disposition
        )
    }

    public func hasClaim(reservationId: String) -> Bool {
        guard let safe = try? platform.validateArtifactComponent(reservationId) else { return false }
        return FileManager.default.fileExists(atPath: dataRoot
            .appendingPathComponent("workshop/reservation_claims/\(safe).claim").path)
    }

    public func hasResult(reservationId: String) -> Bool {
        guard let path = path(reservationId: reservationId) else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    public func remove(reservationId: String) {
        guard let path = path(reservationId: reservationId) else { return }
        try? FileManager.default.removeItem(at: path)
    }
}
