import AppToolRuntime
import AuthoredCapabilities
import DeviceSync
import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `ConnectorFace+Phone.swift` | Connectors' iPhone rows: iCloud pairing facts, paired devices, notification route, phone senses; Pair, Remove and Rotate are the person's; each row is a door call, and the pairing verbs no other verb runs run here |

/// Changes of the pairing owner's published values, so the Connectors page re-reads them.
enum ConnectorFaceChange {
    static let phone = Notification.Name("NativeAgent.connectorsFace.phoneChanged")
}

extension NativeAgentEngine {
    /// Posts `ConnectorFaceChange.phone` whenever the pairing owner publishes a new fact, phone, message or error. The quiet key check runs
    /// once here, never in the page read: a read that wrote what this watches would re-read the page without end.
    @MainActor func watchPhoneFace() {
        sync.observeStatus()
        Task { @MainActor [sync] in
            await sync.loadSecret(quiet: true)
            while !Task.isCancelled {
                await withCheckedContinuation { (moved: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = (sync.phones, sync.message, sync.phonePairedElsewhere, sync.connection, sync.standing, sync.pairingError,
                             sync.isCheckingPairing)
                    } onChange: { moved.resume() }
                }
                NotificationCenter.default.post(name: ConnectorFaceChange.phone, object: nil)
            }
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
        rows.append(.init(id: "iphone.latest", title: "Latest from iCloud", detail: state.status, tone: .quiet))
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

    private func phoneDeviceRows(_ devices: [PairedPhoneStore.Phone], connected: Bool, message: String?) -> [PartFace.Row] {
        let phones = devices.filter { $0.status != .removed }
        var rows = phones.map { phone in
            let id: [String: PartFace.Value] = ["id": .string(phone.id)]
            let pair = PartFace.Action(id: "pair", label: "Pair", role: .primary, doors: ["mac"], call: .init("pairing.pair", id))
            return PartFace.Row(id: "phone:" + phone.id, title: phone.status == .paired ? "iPhone or iPad" : "Phone waiting to pair",
                detail: phone.id, value: phone.status == .paired ? "Can approve" : "Waiting", symbol: "iphone",
                tone: phone.status == .paired ? .live : .attention,
                actions: (phone.status == .pending ? [pair] : [])
                    + [PartFace.Action(id: "remove", label: "Remove", role: .destructive, doors: ["mac"], call: .init("pairing.remove", id))])
        }
        // A phone that chats over the shared key is connected before it can approve, so an empty list never reads as "no phone".
        if phones.isEmpty {
            rows.append(.init(id: "iphone.none", title: connected
                ? "Your iPhone is connected over iCloud, but it hasn't asked to pair. Open the companion app and tap Connect; it appears here to Pair."
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
    @MainActor func pairingCheckDelivery() async throws -> String? {
        _ = try pairingOwner()
        guard !sync.isCheckingPairing else { return "An iCloud delivery check is already running." }
        await sync.checkPairingDelivery()
        return sync.pairingError ?? "iCloud delivery was checked. Tap Check for Mac on your phone."
    }

    /// `pairing.use_here`: the iPhone paired with another Mac on this Apple Account follows this one.
    @MainActor func pairingUseHere() async throws -> String? {
        guard try await pairingOwner().bridge.usePhoneHere() else {
            throw PartCallError(code: "pairing_failed", message: "This Mac could not take the iPhone pairing. Check iCloud and try again.")
        }
        return "Your iPhone now follows this Mac."
    }

    /// `pairing.rotate`: a new pairing key replaces the old one, which stops working at once.
    @MainActor func pairingRotate() async throws -> String? {
        _ = try pairingOwner()
        await sync.regenerateSecret()
        if let error = sync.pairingError { throw PartCallError(code: "rotate_failed", message: error) }
        return "A new pairing key was made; iCloud is delivering it to each paired iPhone and iPad."
    }

    /// `pairing.pair`: a phone waiting in the paired list may approve.
    @MainActor func pairingPair(_ id: String) async throws -> String? {
        let owner = try pairingOwner()
        guard let phone = sync.phones.first(where: { $0.id == id && $0.status != .removed }) else {
            throw PartCallError(code: "stale_row", message: "That phone is no longer in the paired list. Refresh Connectors before changing it.")
        }
        guard await owner.pairedPhones.setStatus(.paired, id: phone.id) else {
            throw PartCallError(code: "pairing_failed", message: (owner.pairedPhones.message ?? "The change did not save.") + " The phone is as it was.")
        }
        return "The phone is paired and can approve."
    }

    @MainActor private func pairingOwner() throws -> DeviceSync {
        guard let owner = sync.owner else { throw PartCallError(code: "pairing_unavailable", message: "Pairing is unavailable on this Mac.") }
        return owner
    }
}
