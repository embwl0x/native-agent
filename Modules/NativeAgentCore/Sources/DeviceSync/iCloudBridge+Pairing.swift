import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `iCloudBridge+Pairing.swift` | Exact-item reconciliation gates signing; account claims and phone connection facts. |

extension iCloudBridge {
    /// Publish atomic rotation readback directly so a second read cannot change the authority decision.
    @discardableResult
    public func publishPairingSecret(_ secret: Data) async -> Bool {
        let generation = setupGeneration
        guard await publishPairing(secret), generation == setupGeneration else { return false }
        notePairingHeld()
        return true
    }

    /// Keep key publication owed until the account accepts it, so interrupted rotation cannot look like another Mac's claim. Failed person-requested moves
    /// remain explicit errors, never standing claims.
    public func owePairingPublication(_ owed: Bool) {
        if owed {
            UserDefaults.standard.set(true, forKey: pairingPublicationOwedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pairingPublicationOwedKey)
        }
        refreshPhoneConnection()
    }

    public var pairingPublicationOwed: Bool {
        UserDefaults.standard.bool(forKey: pairingPublicationOwedKey)
    }

    private func pairingSecretForPublication() async throws -> Data {
        let owed = pairingPublicationOwed
        let secret = try await sync.storage.perform {
            try owed ? PairingSecret.requireExistingSecret() : PairingSecret.loadOrGenerateSecret()
        }
        if sync.engine.pairingSecretRotation == .awaitingVerification {
            await sync.engine.finishPairingSecretRotation(with: secret)
            nativeLog("[PairingBootstrap] Reconciled pairing rotation from the exact existing Keychain item; pairing publication remains owed")
        }
        return secret
    }

    /// Account acceptance of this Mac's key settles owed publication, regardless of who initiated it.
    private func publishPairing(_ secret: Data) async -> Bool {
        guard let deviceTransport else { return false }
        let published = await PairingSecret.publishMaterial(secret, to: deviceTransport)
        await recordSendResult(operation: "pairing", error: published ? nil :
            DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
        if published { owePairingPublication(false) }
        return published
    }

    /// Claim only a free or self-held account record; another Mac keeps the phone until the person explicitly moves it here.
    public func claimPhonePairing() async {
        guard let transport = deviceTransport, sync.engine.pairingSecretRotation != .writing else { return }
        let generation = setupGeneration
        let accountGeneration = accountFailureGeneration
        let secret: Data
        do {
            secret = try await pairingSecretForPublication()
        } catch {
            nativeLog("[PairingBootstrap] Pairing unavailable; refusing device claim: \(error.localizedDescription)")
            pairingKeyUnreadable = true
            await recordSendResult(operation: "pairing", error:
                DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
            syncStatus = "iPhone pairing unavailable — check the Mac pairing key and iCloud"
            return
        }
        pairingKeyUnreadable = false
        let held: Bool?
        if pairingPublicationOwed {
            held = await publishPairing(secret) ? true : nil
        } else {
            do {
                held = try await transport.claimPairing(secret: secret)
                await recordSendResult(operation: "pairing")
            } catch {
                await recordSendResult(operation: "pairing", error: error)
                syncStatus = "The iPhone pairing record could not be read: \(error.localizedDescription)"
                return
            }
        }
        guard generation == setupGeneration, let held else { return }
        // A successful account answer supersedes the stored account failure.
        if accountFailure != nil, accountGeneration == accountFailureGeneration { await clearAccountFailure() }
        if held {
            notePairingHeld()
        } else {
            notePairedElsewhere()
        }
    }

    @discardableResult
    public func usePhoneHere() async -> Bool {
        guard deviceTransport != nil, sync.engine.pairingSecretRotation != .writing else { return false }
        do {
            let secret = try await pairingSecretForPublication()
            pairingKeyUnreadable = false
            return await publishPairingSecret(secret)
        } catch {
            pairingKeyUnreadable = true
            nativeLog("[PairingBootstrap] Pairing unavailable; refusing move here: \(error.localizedDescription)")
            return false
        }
    }

    /// Reclaim republishes all phone projections because another Mac may have overwritten them while this Mac was silent.
    private func notePairingHeld() {
        let wasSpeaking = speaksToPhone
        let wasElsewhere = phonePairedElsewhere
        phonePairingSettled = true
        phonePairedElsewhere = false
        guard !wasSpeaking else { return }
        lastPublishedProviderCatalogStatus = nil
        lastPublishedMobileSnapshotStatus.removeAll()
        if wasElsewhere {
            doctorTransportHealth = .unmeasured
        }
        Task.detached(priority: .utility) { await PairingSecret.publishMaterialToKVS() }
        Task {
            _ = await self.publishProviderCatalogStatus()
            await self.sync.engine.republishPhonePages()
            if wasElsewhere { _ = await self.drainDeviceTransport(trigger: .coalesced) }
        }
    }

    private func notePairedElsewhere() {
        phonePairingSettled = true
        phonePairedElsewhere = true
        syncStatus = Self.pairedElsewhereStatus
        doctorTransportHealth = .pairedElsewhere
        doctorSendFailures.removeAll()
        recordTransportOrgansOff("the iPhone is paired with another Mac")
    }

    // MARK: - The phone connection

    func notePhoneContact(at peerTimestamp: Date) {
        let contact = min(peerTimestamp, Date())
        phoneContactRead.write {
            phoneContactReadFailure = nil
            if contact > (lastPhoneContactAt ?? .distantPast) { lastPhoneContactAt = contact }
        }
    }

    /// Contact is the saved signed evidence; the shared key carries no device identity, so it says that a phone spoke, never which one.
    /// Unreadable evidence is unknown, never silence.
    func standing(of rows: [PairedPhoneStore.Phone]) -> NAPhoneStanding {
        let live = rows.filter { $0.status != .removed }
        let connected: Bool? = phoneContactReadFailure != nil ? nil : lastPhoneContactAt != nil ? true : nil
        return NAPhoneStanding(connected: connected, waiting: live.filter { $0.status == .pending }.count,
                               approvers: live.filter { $0.status == .paired }.count)
    }

    /// The same standing from a checked read of paired_phones.json, for a verdict that must not rest on the published copy. Nil when it can't be read.
    public func checkedPhoneStanding() async -> NAPhoneStanding? {
        guard let rows = await sync.pairedPhones.checkedPhones() else { return nil }
        return standing(of: rows)
    }

    func refreshPhoneConnection() {
        let current = standing(of: sync.pairedPhones.phones)
        if current != phoneStanding { phoneStanding = current }
        let next = NAPhoneConnection(pairing: phonePairingFact, transport: phoneTransportFact, exchange: phoneExchangeFact)
        if next != phoneConnection { phoneConnection = next }
    }

    private var phonePairingFact: NAPhoneConnection.Fact {
        if pairingKeyUnreadable {
            return .init(.broken, "This Mac's pairing key can't be read.", owner: .personOnMac,
                         lever: "Open Connectors → iPhone → Regenerate the pairing key, confirm Regenerate, then pair the iPhone again.")
        }
        if deviceTransport != nil, pairingPublicationOwed {
            return .init(.waiting, "This Mac's new pairing key is waiting for iCloud to take it.", owner: .network,
                         lever: "Keep this Mac online with NativeAgent open; it publishes the key on its own.")
        }
        if phonePairedElsewhere {
            return .init(.waiting, "Your iPhone is paired with another Mac (or an earlier install) on this Apple Account.",
                         owner: .personOnMac,
                         lever: "Choose Connectors → iPhone → Use my iPhone with this Mac to disconnect it from the other Mac and connect it here.")
        }
        if phoneStanding.waiting > 0 {
            return .init(.waiting, phoneStanding.line, owner: .personOnMac,
                         lever: "Open Connectors → iPhone, match the code the iPhone shows, then choose Pair.")
        }
        guard phoneStanding.canApprove else {
            return .init(.waiting, phoneStanding.line, owner: .personOnPhone,
                         lever: "Open NativeAgent on your iPhone, signed in to this Apple Account, and tap Connect.")
        }
        if deviceTransport != nil, !phonePairingSettled {
            return .init(.waiting, "Paired; checking in iCloud that this Mac still holds the pairing.")
        }
        return .init(.holds, phoneStanding.line)
    }

    private var phoneTransportFact: NAPhoneConnection.Fact {
        if let accountFailureReadError {
            return .init(.broken, accountFailureReadError, owner: .builder,
                         lever: "Restore access to icloud/account_failure.json, then check Connection.")
        }
        if accountFailure != nil {
            return .init(.broken, "iCloud sign-in needs attention on this Mac.", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and finish signing in to iCloud.")
        }
        if deviceTransport == nil, let transportRefusal { return transportRefusal }
        if cloudKitPushUnavailable {
            return .init(.broken, "CloudKit cannot wake this Mac for phone messages.", owner: .builder,
                         lever: "Repair APNs registration and CloudKit subscriptions. Open Connection to refresh explicitly meanwhile.")
        }
        let carrier = deviceTransport != nil ? "CloudKit" : "iCloud Drive"
        switch doctorTransportHealth {
        case .available, .pairedElsewhere:
            guard doctorSendFailures.isEmpty else {
                return .init(.waiting, "\(carrier) is up; some deliveries to the iPhone are waiting to resend.", owner: .network,
                             lever: "Keep this Mac online with NativeAgent open; it resends on its own.")
            }
            return .init(.holds, "\(carrier) carries their messages.")
        case .unmeasured:
            return .init(.waiting, "\(carrier) is starting; not measured yet.")
        case .signedOut:
            return .init(.broken, "This Mac is not signed in to iCloud.", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and sign in.")
        case .notEntitled:
            return .init(.broken, "This build is not signed to use iCloud for the phone.", owner: .builder,
                         lever: "Install a signed NativeAgent build.")
        case .quotaExceeded:
            return .init(.broken, "iCloud storage is full.", owner: .iCloudAccount,
                         lever: "Free iCloud storage in System Settings → Apple Account → iCloud.")
        case .accountFailure(_, let detail):
            return .init(.broken, "iCloud turned this Mac away: \(detail)", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and check iCloud.")
        case .unavailable(let reason):
            return .init(.waiting, "\(carrier)'s last receive failed: \(reason)", owner: .network,
                         lever: "Check this Mac's internet connection; NativeAgent retries on its own.")
        }
    }

    private var phoneExchangeFact: NAPhoneConnection.Fact {
        if let phoneContactReadFailure {
            return .init(.waiting, "Saved phone contact evidence is unavailable: \(phoneContactReadFailure)",
                         owner: .builder, lever: "Repair mobile/signed_peer_evidence.json while preserving its contents, then reconnect.")
        }
        if let failure = sync.engine.syncError {
            return .init(.waiting, "Phone sync needs attention: \(failure)", owner: .builder,
                         lever: "Repair the named storage or iCloud cause in Diagnostics, then refresh the phone connection.")
        }
        if let rejected = lastPhoneRejectedAt, rejected > (lastPhoneContactAt ?? .distantPast) {
            return .init(.broken,
                         """
                             Turned away the iPhone's last message (\(rejected.formatted(date: .abbreviated, time: .shortened))): it was signed with a key \
                             this Mac does not hold.
                             """,
                         owner: .personOnPhone,
                         lever: "On the iPhone, open Settings › Connection and choose Pair with Mac.")
        }
        guard let contact = lastPhoneContactAt else {
            return .init(.waiting, "No message from your iPhone yet.", owner: .personOnPhone,
                         lever: "Send a message from NativeAgent on your iPhone.")
        }
        return .init(.holds, "Last message from your iPhone: \(contact.formatted(date: .abbreviated, time: .shortened)).")
    }

}
