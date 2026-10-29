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
// Blueprint: | `iCloudBridge+Pairing.swift` | Pairing claims and the Mac reading of phone connection facts |

extension iCloudBridge {
    /// Publish the exact bytes returned by the atomic rotation transaction.
    /// This avoids a second disk read becoming a different authority decision.
    @discardableResult
    public func publishPairingSecret(_ secret: Data) async -> Bool {
        let generation = setupGeneration
        guard await publishPairing(secret), generation == setupGeneration else { return false }
        notePairingHeld()
        return true
    }

    /// A key change is owed to the account's pairing record from before the
    /// key changes until the record takes it, so no quit or claim in between
    /// reads this install's own old key as another Mac's. Only a key change
    /// owes: a move-here the person pressed that failed stays their error to
    /// retry, never a standing claim.
    public func owePairingPublication(_ owed: Bool) {
        if owed {
            UserDefaults.standard.set(true, forKey: pairingPublicationOwedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pairingPublicationOwedKey)
        }
        refreshPhoneConnection()
    }

    /// The account's pairing record takes this Mac's key: the person's act or
    /// this Mac's own key change. Landing settles anything owed.
    private func publishPairing(_ secret: Data) async -> Bool {
        guard let deviceTransport else { return false }
        let published = await PairingSecret.publishMaterial(secret, to: deviceTransport)
        await recordSendResult(operation: "pairing", error: published ? nil :
            DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
        if published { owePairingPublication(false) }
        return published
    }

    /// The phone follows one Mac: whichever key the account's Mac pairing
    /// record holds. Launch takes that record only when it is free or already
    /// this Mac's. Another Mac keeps the phone until the person moves it here
    /// (`usePhoneHere`), so launching a second Mac never takes the phone.
    func claimPhonePairing() async {
        guard let transport = deviceTransport else { return }
        let generation = setupGeneration
        let accountGeneration = accountFailureGeneration
        let secret: Data
        do {
            secret = try PairingSecret.loadOrGenerateSecret()
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
        if UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            held = await publishPairing(secret) ? true : nil
        } else {
            held = await transport.claimPairing(secret: secret)
            if held == nil {
                await recordSendResult(operation: "pairing", error:
                    DeviceSyncError.transient(message: "The iPhone pairing record could not be read; retrying at the next sync."))
            } else {
                await recordSendResult(operation: "pairing")
            }
        }
        guard generation == setupGeneration, let held else { return }
        // The account answered; a stored account failure is no longer true.
        if accountFailure != nil, accountGeneration == accountFailureGeneration { await clearAccountFailure() }
        if held {
            notePairingHeld()
        } else {
            notePairedElsewhere()
        }
    }

    /// The person's act: move the phone to this Mac.
    @discardableResult
    public func usePhoneHere() async -> Bool {
        guard deviceTransport != nil,
              let secret = try? PairingSecret.loadOrGenerateSecret() else { return false }
        return await publishPairingSecret(secret)
    }

    /// This Mac holds the pairing. Coming out of silence (launch, or another
    /// Mac had the phone), everything it has for the phone goes out afresh:
    /// the other Mac may have written over all of it.
    private func notePairingHeld() {
        let wasSpeaking = speaksToPhone
        let wasElsewhere = phonePairedElsewhere
        phonePairingSettled = true
        phonePairedElsewhere = false
        guard !wasSpeaking else { return }
        lastPublishedProviderCatalogStatus = nil
        lastPublishedMobileSnapshotStatus.removeAll()
        if wasElsewhere {
            // The drain and the presence republish below record their own pulses.
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
        deviceDrainTimerTask?.cancel()
        deviceDrainTimerTask = nil
        recordTransportOrgansOff("the iPhone is paired with another Mac")
    }

    // MARK: - The phone connection

    func notePhoneContact(at peerTimestamp: Date) {
        let contact = min(peerTimestamp, Date())
        if contact > (lastPhoneContactAt ?? .distantPast) { lastPhoneContactAt = contact }
    }

    func refreshPhoneConnection() {
        let next = NAPhoneConnection(pairing: phonePairingFact, transport: phoneTransportFact, exchange: phoneExchangeFact)
        if next != phoneConnection { phoneConnection = next }
    }

    private var phonePairingFact: NAPhoneConnection.Fact {
        if pairingKeyUnreadable {
            return .init(.broken, "This Mac's pairing key can't be read.", owner: .personOnMac,
                         lever: "Open Connectors → iPhone → Regenerate the pairing key, confirm Regenerate, then pair the iPhone again.")
        }
        if deviceTransport != nil, UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            return .init(.waiting, "This Mac's new pairing key is waiting for iCloud to take it.", owner: .network,
                         lever: "Keep this Mac online with NativeAgent open; it publishes the key on its own.")
        }
        if phonePairedElsewhere {
            return .init(.waiting, "Your iPhone is paired with another Mac (or an earlier install) on this Apple Account.",
                         owner: .personOnMac,
                         lever: "Choose Connectors → iPhone → Use my iPhone with this Mac to disconnect it from the other Mac and connect it here.")
        }
        let phones = sync.pairedPhones.phones.filter { $0.status != .removed }
        if phones.contains(where: { $0.status == .pending }) {
            return .init(.waiting, "An iPhone is waiting for you to pair it.", owner: .personOnMac,
                         lever: "Open Connectors → iPhone, match the code the iPhone shows, then choose Pair.")
        }
        guard phones.contains(where: { $0.status == .paired }) else {
            return .init(.waiting, "No iPhone is paired yet.", owner: .personOnPhone,
                         lever: "Open NativeAgent on your iPhone, signed in to this Apple Account, and tap Connect.")
        }
        if deviceTransport != nil, !phonePairingSettled {
            return .init(.waiting, "Paired; checking in iCloud that this Mac still holds the pairing.")
        }
        return .init(.holds, "Paired with your iPhone.")
    }

    private var phoneTransportFact: NAPhoneConnection.Fact {
        if accountFailure != nil {
            return .init(.broken, "iCloud sign-in needs attention on this Mac.", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and finish signing in to iCloud.")
        }
        if deviceTransport == nil, let transportRefusal { return transportRefusal }
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
        if let rejected = lastPhoneRejectedAt, rejected > (lastPhoneContactAt ?? .distantPast) {
            return .init(.broken,
                         "Turned away the iPhone's last message (\(rejected.formatted(date: .abbreviated, time: .shortened))): it was signed with a key this Mac does not hold.",
                         owner: .personOnPhone,
                         lever: "On the iPhone, open Settings › Connection and choose Pair with Mac.")
        }
        guard let contact = lastPhoneContactAt else {
            return .init(.waiting, "No message from your iPhone yet.", owner: .personOnPhone,
                         lever: "Send a message from NativeAgent on your iPhone.")
        }
        return .init(.holds, "Last message from your iPhone: \(contact.formatted(date: .abbreviated, time: .shortened)).")
    }

    /// Why a build meant to use CloudKit got no transport for the phone.
    nonisolated static func cloudKitRefusal(containerID: String) -> NAPhoneConnection.Fact? {
        guard DeviceSyncTransportResolver.resolvedKind() == .cloudkit else { return nil }
        guard DeviceCloudKitPreflight.hasCloudKitEntitlement() else {
            return .init(.broken, "This build is not signed for CloudKit, so the iPhone cannot reach it.", owner: .builder,
                         lever: "Install a NativeAgent build signed with CloudKit.")
        }
        return .init(.broken,
                     "This build is configured for iCloud container \(containerID), but its signature grants another, so the iPhone cannot reach it.",
                     owner: .builder,
                     lever: "Install a NativeAgent build whose iCloud container matches its signature.")
    }
}
