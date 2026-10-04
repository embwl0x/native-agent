import Foundation
import Combine
import NativeAgentShared
import PersistenceCore
import TrustCenter

/// Main-actor serialization keeps removal and decision verification ordered.
@MainActor
public final class PairedPhoneStore: ObservableObject {
    public typealias Phone = PairedPhoneAuthority.Phone

    @Published public private(set) var phones: [Phone] = []
    @Published public private(set) var message: String?
    private let url: URL

    init(url: URL) {
        self.url = url
        reload()
    }

    private func read() throws -> [Phone] { try Self.read(at: url) }

    /// Doctor reads the owner store without constructing or reloading UI state.
    nonisolated public static func pairedCountChecked(at url: URL) throws -> Int {
        try PairedPhoneAuthority.pairedCountChecked(at: url)
    }

    nonisolated private static func read(at url: URL) throws -> [Phone] {
        try PairedPhoneAuthority.read(at: url)
    }

    /// Phones paired right now, read from disk (a setup card's done-check).
    public func pairedCount() -> Int {
        ((try? read()) ?? []).filter { $0.status == .paired }.count
    }

    public func reload() {
        do { phones = try read() } catch { message = StoreError.unavailable.localizedDescription }
    }

    private func save(_ rows: [Phone]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(rows).write(to: url, options: .atomic)
        phones = rows
    }

    public func setStatus(_ status: Phone.Status, id: String) {
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
            case .notPaired: "This phone isn’t paired. Open Settings → Pair iPhone / iPad on this Mac to pair it."
            }
        }
    }
}
