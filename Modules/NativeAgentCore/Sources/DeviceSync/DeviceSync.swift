import Foundation
import CryptoKit
import Cognition
import Desk
import Experiences
import NativeAgentShared
import PersistenceCore

// Blueprint: | `DeviceSync.swift` | Canonical-root phone bridge; Desk waits are ask matters, answered only by an observed Desk item |

typealias MemoryRecord = NativeAgentShared.MemoryRecord
typealias MultimodalAttachment = NativeAgentShared.MultimodalAttachment
typealias ChatSession = NativeAgentShared.ChatSession

/// The resident bridge is bound by construction to the canonical app data root.
@MainActor
public final class DeviceSync {
    nonisolated let storage = DeviceSyncStorage()
    public nonisolated let dataRoot: URL
    nonisolated let host: any DeviceSyncHost
    nonisolated let cognition: NativeCognitionRuntime
    public nonisolated let apns = SwiftNativeAPNSSender()
    nonisolated let needsUser: DeskNeedsUser

    public lazy var bridge = iCloudBridge(sync: self)
    public lazy var engine = MacSyncEngine(sync: self)
    public lazy var relay = MacSyncMobileNotificationRelay(sync: self)
    public lazy var pairedPhones = PairedPhoneStore(url: dataRoot.appendingPathComponent("paired_phones.json"), storage: storage)

    public nonisolated init(host: any DeviceSyncHost, cognition: NativeCognitionRuntime) {
        let dataRoot = PersistenceCore.defaultDataRoot()
        self.dataRoot = dataRoot
        self.host = host
        self.cognition = cognition
        self.needsUser = DeskNeedsUser(dataRoot: dataRoot)
    }

    /// Attention follows the app's overview, so phone-sync shutdown cannot suppress it.
    public nonisolated func evaluateNeedsUser(items: [DeskItem]) async {
        do { try await needsUser.evaluate(items: items) }
        catch {
            let failure = "Desk questions remain owed: \(error.localizedDescription)"
            await MainActor.run { self.engine.syncError = failure }
        }
    }
}

/// ForPerson remembers which question was asked; an absent item never proves its question was answered.
actor DeskNeedsUser {
    private let dataRoot: URL
    private var pending: [DeskItem]?
    private var evaluating = false
    private(set) var failure: String?

    init(dataRoot: URL) { self.dataRoot = dataRoot }

    struct EvaluationFailure: LocalizedError {
        let causes: [String]
        var errorDescription: String? { causes.joined(separator: "; ") }
    }

    func evaluate(items: [DeskItem]) async throws {
        pending = items
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        while let items = pending {
            pending = nil
            let forPerson = ForPerson.at(dataRoot)
            let matters: [Experience]
            do { matters = try await forPerson.matters() }
            catch {
                if pending == nil { pending = items }
                failure = error.localizedDescription
                nativeLog("needs_user: questions unavailable: %@", error.localizedDescription)
                throw error
            }
            var failed: [DeskItem] = []
            var causes: [String] = []
            for item in items {
                do {
                    let question = item.title + "\n" + (item.blockedReason ?? item.summary ?? "")
                    let digest = SHA256.hash(data: Data(question.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                    let id = "needs_user:" + item.handle + ":" + digest
                    let evidence = Experience.Ref(source: "desk", id: item.handle)
                    if item.requiresOwnerInput {
                        let reason = (item.blockedReason ?? item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let body = reason.isEmpty ? item.title : item.title + " — " + reason
                        try await forPerson.tell(Matter(id: id, form: .ask, from: "needs_user",
                            title: "\(NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot)) needs you",
                            summary: MobileDeskProjectionBounds.clipped(body, to: 500), words: body,
                            open: "page:desk/" + item.handle, evidence: [evidence]), doors: Door.person(thread: nil))
                    }
                    for old in matters where old.face?.from == "needs_user" && old.evidence.contains(evidence)
                        && old.owes["decide"]?.phase.isSettled == false && (!item.requiresOwnerInput || old.id != id) {
                        try await forPerson.answered(old.id, evidence: evidence)
                    }
                } catch {
                    failed.append(item)
                    causes.append(item.handle + ": " + error.localizedDescription)
                    nativeLog("needs_user: %@ question remains owed: %@", item.handle, error.localizedDescription)
                }
            }
            if !failed.isEmpty {
                if pending == nil { pending = failed }
                let error = EvaluationFailure(causes: causes)
                failure = error.localizedDescription
                throw error
            }
        }
        failure = nil
    }
}

/// One executor serializes disk bookkeeping while admission and acknowledgements await checked results off the UI actor.
actor DeviceSyncStorage {
    func perform<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T { try work() }
}

extension Notification.Name {
    public static let iCloudInboxDidProcess = Notification.Name("NativeAgent.iCloudInboxDidProcess")
}
