import Foundation
import Combine
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import DeskCore
// Blueprint: | `PairedPhoneStore.swift` | Canonical pairing-array mutations; local approval authority excluded from export and sync. |

/// Main-actor serialization orders removals and approval checks; Mac pairing authority stays out of backup, export and phone sync.
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

    /// The owner file read fresh; nil when it can't be read, with `message` saying why.
    public func checkedPhones() async -> [Phone]? {
        let url = url
        let result = await storage.perform { Result { try Self.read(at: url) } }
        switch result {
        case .success(let rows): return rows
        case .failure(let error):
            message = "The paired phones could not be read: \(error.localizedDescription). Restore access to paired_phones.json and try again."
            return nil
        }
    }

    public func reload() async {
        let url = url
        _ = await latest.read {
            await storage.perform { Result { try Self.read(at: url) } }
        } publish: { result in
            switch result {
            case .success(let rows):
                if !phones.elementsEqual(rows, by: {
                    $0.id == $1.id && $0.publicKey == $1.publicKey && $0.status == $1.status && $0.confirmed == $1.confirmed
                        && $0.acceptance == $1.acceptance
                }) {
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
                // Accepting a phone owes it that acceptance, in the same write and under a new identity; any other status owes it nothing.
                if rows[index].status != status {
                    rows[index].confirmed = nil
                    rows[index].acceptance = status == .paired ? UUID().uuidString : nil
                }
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

    /// The phone heard this Mac's acceptance: what was owed to it is settled. Only a paired phone's own signed word echoing the current acceptance
    /// settles it; an acknowledgement of an earlier pairing changes nothing.
    @discardableResult
    func confirm(id: String, acceptance: String) async -> Bool {
        let url = url
        do {
            let rows = try await storage.perform { () -> [Phone]? in
                var rows = try Self.read(at: url)
                guard let index = rows.firstIndex(where: { $0.id == id && $0.status == .paired }) else { throw StoreError.notPaired }
                guard rows[index].confirmed != true else { return nil }
                // An echo of an earlier acceptance settles nothing and says so: the phone is sent the current one.
                guard (rows[index].acceptance ?? "") == acceptance else { throw StoreError.earlierAcceptance }
                rows[index].confirmed = true
                try Self.save(rows, to: url)
                return rows
            }
            if let rows {
                latest.write {
                    phones = rows
                    message = nil
                }
            }
            return true
        } catch {
            message = (error as? StoreError)?.localizedDescription ?? StoreError.unavailable.localizedDescription
            return false
        }
    }

    /// Authentication permits pairing requests, but only the local Pair button can grant approval authority.
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
                        rows[index].confirmed = nil
                        rows[index].acceptance = nil
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
        case unavailable, notPaired, earlierAcceptance
        var errorDescription: String? {
            switch self {
            case .earlierAcceptance: "The iPhone confirmed an earlier pairing. This Mac sends it the current acceptance."
            case .unavailable: "I couldn’t read the paired phones. I haven’t accepted this decision."
            case .notPaired: "This phone can’t approve yet. On this Mac, open Connectors → iPhone, match the phone’s code, and choose Pair."
            }
        }
    }
}
