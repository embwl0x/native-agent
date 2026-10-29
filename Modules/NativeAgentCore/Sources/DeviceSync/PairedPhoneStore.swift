import Foundation
import Combine
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `PairedPhoneStore.swift` | Paired-phone array mutations using PairedPhoneAuthority's one Phone schema; local backup/export/phone exclusions and Paired Phones privacy scope are declared here |

/// Main-actor serialization keeps removal and decision verification ordered.
/// Owns paired_phones.json's Phone array, decoded by PairedPhoneAuthority.
/// Local backup, export and phone sync exclude this Mac's pairing authority;
/// PrivacyMap lists Paired Phones.
@MainActor
public final class PairedPhoneStore: ObservableObject {
    public typealias Phone = PairedPhoneAuthority.Phone

    @Published public private(set) var phones: [Phone] = []
    @Published public private(set) var message: String?
    private let url: URL
    private let storage: DeviceSyncStorage
    private var observationTask: Task<Void, Never>?
    private let latest = LatestRead()

    init(url: URL, storage: DeviceSyncStorage) {
        self.url = url
        self.storage = storage
        observationTask = Task { [weak self] in
            let events = FileChangeEvents(paths: [url])
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    guard let self else { return }
                    await self.reload()
                }
            } onCancel: { events.cancel() }
        }
    }
    deinit { observationTask?.cancel() }

    /// Doctor reads the owner store without constructing or reloading UI state.
    nonisolated public static func pairedCountChecked(at url: URL) throws -> Int {
        try PairedPhoneAuthority.pairedCountChecked(at: url)
    }

    nonisolated private static func read(at url: URL) throws -> [Phone] {
        try PairedPhoneAuthority.read(at: url)
    }

    /// Phones paired right now, read from disk (a setup card's done-check).
    public func pairedCount() async -> Int {
        let url = url
        return await storage.perform { (try? Self.pairedCountChecked(at: url)) ?? 0 }
    }

    public func reload() async {
        let url = url
        _ = await latest.read {
            await storage.perform { Result { try Self.read(at: url) } }
        } publish: { result in
            switch result {
            case .success(let rows):
                if !phones.elementsEqual(rows, by: { $0.id == $1.id && $0.publicKey == $1.publicKey && $0.status == $1.status }) {
                    phones = rows
                }
                message = nil
            case .failure:
                message = StoreError.unavailable.localizedDescription
            }
        }
    }

    nonisolated private static func save(_ rows: [Phone], to url: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(rows), to: url)
    }

    @discardableResult
    public func setStatus(_ status: Phone.Status, id: String) async -> Bool {
        let url = url
        do {
            let rows = try await storage.perform {
                var rows = try Self.read(at: url)
                guard let index = rows.firstIndex(where: { $0.id == id }) else { throw StoreError.unavailable }
                rows[index].status = status
                try Self.save(rows, to: url)
                return rows
            }
            latest.write {
                phones = rows
                message = nil
            }
            return true
        } catch {
            message = StoreError.unavailable.localizedDescription
            return false
        }
    }

    /// Called only after transport authentication. A key holder may request
    /// pairing, but only the local Pair button can grant approval authority.
    func authorize(_ action: InboxAction) async -> String? {
        let url = url
        do {
            let notice: String? = try await storage.perform {
                let identity = try DeviceApprovalSignature.verify(JSONEncoder().encode(action))
                var rows = try Self.read(at: url)
                if let phone = rows.first(where: { $0.id == identity.id }) {
                    if phone.status == .removed, action.action == "pairDevice",
                       let index = rows.firstIndex(where: { $0.id == identity.id }) {
                        rows[index].status = .pending
                        try Self.save(rows, to: url)
                    }
                    guard phone.status == .paired else { throw StoreError.notPaired }
                } else {
                    guard rows.count < 100 else { throw StoreError.unavailable }
                    rows.append(Phone(id: identity.id, publicKey: identity.key, status: .pending))
                    try Self.save(rows, to: url)
                    throw StoreError.notPaired
                }
                return nil
            }
            return notice
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
