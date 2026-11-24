import SenseCore
import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
import DeskCore
// Blueprint: | `ConnectorFace+Phone.swift` | Connectors' iPhone rows: iCloud pairing facts, paired devices, notification route, phone senses; Pair, Remove and Rotate are the person's; each row is a door call, and the pairing verbs no other verb runs run here |

/// Changes of the pairing owner's published values, so the Connectors page re-reads them.
enum ConnectorFaceChange {
    struct PhoneDidChange: NotificationCenter.MainActorMessage {
        typealias Subject = NSObject
    }
}

extension NativeAgentEngine {
    @MainActor func watchPhoneFace() {
        sync.observeStatus()
        Task { [countsStatus, sync] in
            await countsStatus.observePhoneFace(sync)
        }
    }

    /// The phone's evidence files whose change re-reads the Connectors page.
    var phoneFacePaths: [URL] { [dataRoot.appendingPathComponent("paired_phones.json"), PhoneSenseHistory.url(dataRoot)] }

    /// The iPhone as one connector row: its state in words, with its setup, paired devices and senses behind it. Takes the pairing owner's
    /// published values on main and awaits the phone's file-backed evidence off main.
    @concurrent func phoneFaceRow() async -> PartFace.Row {
        let state = await MainActor.run {
            (connection: sync.connection, status: sync.status, standing: sync.standing, pairingError: sync.pairingError,
             phonePairedElsewhere: sync.phonePairedElsewhere, isCheckingPairing: sync.isCheckingPairing, phones: sync.phones, message: sync.message)
        }
        var rows: [PartFace.Row] = [.init(id: "iphone.about", title: "Pair your iPhone or iPad", detail: """
            Open the Mac app and the companion app on your iPhone or iPad, using the same Apple Account on both devices. The pairing key arrives \
            automatically through iCloud. Once it arrives, tap Connect on your phone or tablet.
            I run on your Mac. Keep it awake with NativeAgent running for replies and actions from your phone.
            Match the phone's code before choosing Pair. Removing a phone stops it from deciding approvals.
            """, symbol: "iphone", tone: .quiet)]
        if let connection = state.connection {
            rows += connection.facts.map { item in
                PartFace.Row(id: "iphone.fact:" + item.label, title: item.label,
                    detail: item.fact.line + (item.fact.state == .holds ? "" : item.fact.lever.map { "\n" + $0 } ?? ""),
                    value: item.fact.state == .holds ? "OK" : item.fact.state == .waiting ? "Waiting" : "Needs fixing",
                    tone: item.fact.state == .holds ? .done : item.fact.state == .waiting ? .attention : .failed)
            }
        }
        rows.append(.init(id: "iphone.latest", title: "iCloud status", detail: state.status, tone: .quiet))
        if let standing = state.standing {
            rows.append(.init(id: "iphone.standing", title: standing.line, tone: standing.waiting > 0 ? .attention : nil))
        }
        if let error = state.pairingError { rows.append(.init(id: "iphone.error", title: "Pairing needs attention", detail: error, tone: .failed)) }
        // One phone follows one Mac; moving it between Macs requires the person's action, never launch.
        if state.phonePairedElsewhere {
            rows.append(.init(id: "iphone.elsewhere", title: "Your iPhone is paired with another Mac", detail: """
                Your iPhone is paired with another Mac (or an earlier install of NativeAgent) on this Apple Account. Moving it here disconnects it \
                from that one.
                """, tone: .attention, actions: [.init(id: "use-here", label: "Use my iPhone with this Mac", role: .primary, doors: ["mac"],
                                                       call: .init("pairing.use_here"))]))
        }
        rows += phoneDeviceRows(state.phones, connected: state.standing?.connected == true, message: state.message)
        rows.append(.init(id: "iphone.delivery", title: "Pairing delivery", detail: """
            Use the same Apple Account on both devices and keep both apps online. The facts above show what iCloud needs. After fixing it, check \
            delivery here, then tap Check for Mac on your phone.
            """, value: state.isCheckingPairing ? "Checking…" : nil, symbol: "icloud",
            actions: [.init(id: "check", label: "Check iCloud delivery", call: .init("pairing.check_delivery"))]))
        rows.append(await phoneNotificationRow())
        rows.append(.init(id: "iphone.rotate", title: "Regenerate the pairing key", detail: """
            The old key stops working immediately. Keep both apps open while iCloud delivers the new key to each paired iPhone and iPad. If \
            delivery needs attention, follow the facts above and check iCloud delivery.
            """, symbol: "arrow.triangle.2.circlepath",
            actions: [.init(id: "rotate", label: "Regenerate", role: .destructive, doors: ["mac"], call: .init("pairing.rotate"))]))
        rows.append(await phoneSensesRow())
        // The pairing owner's own assessment names the first unmet fact; a pairing error or another Mac holding the phone comes first.
        let (value, tone): (String, PartFace.Tone) =
            if state.pairingError != nil { ("Needs attention", .failed) }
            else if state.phonePairedElsewhere { ("Paired with another Mac", .attention) }
            else if let waiting = state.standing?.waiting, waiting > 0 { ("Waiting for Pair", .attention) }
            else if let confirming = state.standing?.confirming, confirming > 0 { ("Waiting for iPhone", .attention) }
            else {
                switch state.connection?.headline.state {
                case .holds?: ("Connected", .live)
                case .waiting?: ("Waiting", .attention)
                case .broken?: ("Needs fixing", .failed)
                case nil: ("Not checked", .quiet)
                }
            }
        return .init(id: "iphone", title: "iPhone", detail: state.connection?.headline.line ?? state.status, value: value, symbol: "iphone",
                     tone: tone, rows: rows)
    }

    /// The phone's short code as both screens show it: the first eight characters of its id, in two groups ("7e6d cae1").
    private static func groupedCode(_ id: String) -> String { "\(id.prefix(4)) \(id.dropFirst(4).prefix(4))" }

    private func phoneDeviceRows(_ devices: [PairedPhoneStore.Phone], connected: Bool, message: String?) -> [PartFace.Row] {
        let phones = devices.filter { $0.status != .removed }
        var rows = phones.map { phone in
            let id: [String: PartFace.Value] = ["id": .string(phone.id)]
            let pair = PartFace.Action(id: "pair", label: "Pair", role: .primary, doors: ["mac"], call: .init("pairing.pair", id))
            let canApprove = phone.status == .paired && !phone.confirmationOwed
            return PartFace.Row(id: "phone:" + phone.id, title: phone.status == .paired ? "iPhone or iPad" : "Phone waiting to pair",
                detail: "Code: \(Self.groupedCode(phone.id))", value: canApprove ? "Can approve" : phone.status == .paired ? "Waiting for it to confirm" : "Waiting",
                symbol: "iphone", tone: canApprove ? .live : .attention,
                actions: (phone.status == .pending ? [pair] : [])
                    + [PartFace.Action(id: "remove", label: "Remove", role: .destructive, doors: ["mac"], call: .init("pairing.remove", id))])
        }
        // A phone that chats over the shared key is connected before it can approve, so an empty list never reads as "no phone".
        if phones.isEmpty {
            rows.append(.init(id: "iphone.none", title: connected
                ? "Your iPhone chats here through this Apple Account but isn't paired. Open the companion app and tap Connect; it appears here to Pair."
                : "No phone can approve yet. Open the companion app and tap Connect to request pairing.", tone: .quiet))
        }
        if let message { rows.append(.init(id: "iphone.devices-error", title: message, tone: .failed)) }
        return rows
    }

    @concurrent nonisolated private func phoneNotificationRow() async -> PartFace.Row {
        do {
            let phone = try await SwiftNativeAPNSSender().notificationReadiness(dataRoot: dataRoot)
            return .init(id: "iphone.notifications", title: "Notifications", detail: phone.detail,
                         value: phone.supported ? "Ready" : "Not paired", symbol: "bell", tone: phone.supported ? .done : .attention)
        } catch {
            return .init(id: "iphone.notifications", title: "Phone notification evidence could not be read",
                         detail: error.localizedDescription, symbol: "bell", tone: .failed)
        }
    }

    /// The phone's last reported setup per sense, then the steps any agent follows to help the person set one up, behind one row.
    @concurrent nonisolated private func phoneSensesRow() async -> PartFace.Row {
        let rows: [PartFace.Row]
        do {
            rows = try PhoneSenseHistory.setupLines(dataRoot).enumerated().map { PartFace.Row(id: "iphone.sense:\($0.offset)", title: $0.element) }
        } catch {
            rows = [.init(id: "iphone.senses-error", title: "Phone sense history could not be read", detail: error.localizedDescription, tone: .failed)]
        }
        let guide = PartFace.Row(id: "iphone.senses-guide", title: "Phone senses guide",
            detail: "The steps to set up a phone sense, read when opened.", open: "page:connectors/iphone.senses-guide")
        return .init(id: "iphone.senses", title: "Phone senses", rows: rows + [guide])
    }

    /// `pairing.check_delivery`: the pairing owner checks iCloud delivery of the pairing key.
    @MainActor func pairingCheckDelivery() throws -> HostVerbEffect {
        _ = try pairingOwner()
        return { [self] in
            guard !sync.isCheckingPairing else { return "An iCloud delivery check is already running." }
            await sync.checkPairingDelivery()
            return sync.pairingError ?? "iCloud delivery was checked. Tap Check for Mac on your phone."
        }
    }

    /// `pairing.use_here`: the iPhone paired with another Mac on this Apple Account follows this one.
    @MainActor func pairingUseHere() throws -> HostVerbEffect {
        let owner = try pairingOwner()
        return {
            guard try await owner.bridge.usePhoneHere() else {
                throw PartCallError(code: "pairing_failed", message: "This Mac could not take the iPhone pairing. Check iCloud and try again.")
            }
            return "Your iPhone now follows this Mac."
        }
    }

    /// `pairing.rotate`: a new pairing key replaces the old one, which stops working at once.
    @MainActor func pairingRotate() throws -> HostVerbEffect {
        _ = try pairingOwner()
        return { [self] in
            let published = await sync.regenerateSecret()
            if let error = sync.pairingError { throw PartCallError(code: "rotate_failed", message: error) }
            return published ? "A new pairing key was made; iCloud is delivering it to each paired iPhone and iPad."
                : "A new pairing key was made, but iCloud has not taken it yet; it is delivered at the next sync. Don't rotate again: the old key already stopped working."
        }
    }

    /// `pairing.pair`: the pairing owner, and the phone `id` names in the paired list, not removed (the lookups); that waiting phone may
    /// approve (the effect).
    @MainActor func pairingPair(_ id: String) throws -> HostVerbEffect {
        let owner = try pairingOwner()
        let phone = try NamedRow.find(id, kind: "phone", in: sync.phones, ids: { [$0.id, String($0.id.prefix(8)), Self.groupedCode($0.id)] }, shown: { Self.groupedCode($0.id) })
        guard phone.status != .removed else { throw NamedRow.stale("That phone was removed from the paired list.") }
        return {
            guard await owner.pairedPhones.setStatus(.paired, id: phone.id) else {
                throw PartCallError(code: "pairing_failed", message: (owner.pairedPhones.message ?? "The change did not save.") + " The phone is as it was.")
            }
            return "Paired on this Mac. The phone confirms as soon as it hears from this Mac, then it can approve."
        }
    }

    @MainActor private func pairingOwner() throws -> DeviceSync {
        guard let owner = sync.owner else { throw PartCallError(code: "pairing_unavailable", message: "Pairing is unavailable on this Mac.") }
        return owner
    }
}
