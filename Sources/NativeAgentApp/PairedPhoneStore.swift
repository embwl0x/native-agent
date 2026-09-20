import Foundation
import SwiftUI
import NativeAgentShared

/// Main-actor serialization keeps removal and decision verification ordered.
@MainActor
final class PairedPhoneStore: ObservableObject {
    static let shared = PairedPhoneStore(url: NativeAgentPaths.dataRoot.appendingPathComponent("paired_phones.json"))

    struct Phone: Codable, Identifiable {
        enum Status: String, Codable { case pending, paired, removed }
        let id: String
        let publicKey: Data
        var status: Status
    }

    @Published private(set) var phones: [Phone] = []
    @Published private(set) var message: String?
    private let url: URL

    init(url: URL) {
        self.url = url
        reload()
    }

    private func read() throws -> [Phone] {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unavailable }
        let rows = try JSONDecoder().decode([Phone].self, from: Data(contentsOf: url))
        guard Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.publicKey.count == 32 && $0.id == DeviceApprovalSignature.deviceID(publicKey: $0.publicKey) }) else {
            throw StoreError.unavailable
        }
        return rows
    }

    func reload() {
        do { phones = try read() } catch { message = StoreError.unavailable.localizedDescription }
    }

    private func save(_ rows: [Phone]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(rows).write(to: url, options: .atomic)
        phones = rows
    }

    func setStatus(_ status: Phone.Status, id: String) {
        do {
            var rows = try read()
            guard let index = rows.firstIndex(where: { $0.id == id }) else { throw StoreError.unavailable }
            rows[index].status = status
            try save(rows)
            message = nil
        } catch { message = StoreError.unavailable.localizedDescription }
    }

    /// Called only after transport authentication. A key holder may request
    /// pairing, but only the local Pair button can grant approval authority.
    func authorize(_ action: InboxAction, requiresPairing: Bool) -> String? {
        do {
            if action.deviceSignature == nil && !requiresPairing { return nil }
            let identity = try DeviceApprovalSignature.verify(JSONEncoder().encode(action))
            var rows = try read()
            if let phone = rows.first(where: { $0.id == identity.id }) {
                if phone.status == .removed, action.action == "pairDevice",
                   let index = rows.firstIndex(where: { $0.id == identity.id }) {
                    rows[index].status = .pending
                    try save(rows)
                }
                guard phone.status == .paired else { throw StoreError.notPaired }
            } else {
                guard rows.count < 100 else { throw StoreError.unavailable }
                rows.append(Phone(id: identity.id, publicKey: identity.key, status: .pending))
                try save(rows)
                throw StoreError.notPaired
            }
            return nil
        } catch {
            let notice = (error as? DeviceApprovalSignature.Failure)?.localizedDescription
                ?? (error as? StoreError)?.localizedDescription
                ?? StoreError.unavailable.localizedDescription
            message = notice
            return notice
        }
    }

    private enum StoreError: LocalizedError {
        case unavailable, notPaired
        var errorDescription: String? {
            switch self {
            case .unavailable: "I couldn’t read the paired phones. I haven’t accepted this decision."
            case .notPaired: "This phone isn’t paired. Open Connectors → iPhone on this Mac to pair it."
            }
        }
    }
}
