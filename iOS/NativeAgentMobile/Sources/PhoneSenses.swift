import CoreLocation
import CoreMotion
import Foundation
import Intents
import NativeAgentShared
import SwiftUI
import UIKit

// Blueprint: | `PhoneSenses.swift` | Opt-in sense outbox; callback-owned wake readings and pairing-bound durable delivery |
@MainActor
final class PhoneSenses: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = PhoneSenses()
    private struct Pending: Codable, Sendable {
        let event: PhoneSenseEvent
        let pairing: String
        var envelope: BridgeMessage?
    }
    private struct State: Codable, Sendable {
        var enabled: Set<PhoneSenseEvent.Source> = []
        var pairing: String?
        var latest: [String: PhoneSenseEvent] = [:]
        var pending: [Pending] = []
    }
    @Published private(set) var enabled: Set<PhoneSenseEvent.Source> = []
    @Published var errorMessage: String?
    private var state = State()
    private var available = false
    private var work: Task<Void, Never>?
    private let storage = MobileLocalStorage()
    private let file = URL.applicationSupportDirectory.appendingPathComponent("phone-senses.json")
    private let motion = CMMotionActivityManager()
    private let location = CLLocationManager()
    @Published private var motionQuery: UUID?
    private var focusAuthorization: Task<Void, Never>?
    private lazy var bodyReadings = PhoneBodyReadings(owner: self)
    private(set) var restorationTask: Task<Void, Never>?

    var waitingSources: [PhoneSenseEvent.Source] {
        (motionQuery == nil ? [] : [.motion]) + bodyReadings.waitingSources
    }

    private override init() {
        super.init()
        location.delegate = self
        let file = file
        restorationTask = Task {
            do {
                state = try await Task.detached(priority: .utility) {
                    let data: Data
                    do { data = try Data(contentsOf: file) }
                    catch CocoaError.fileReadNoSuchFile { return State() }
                    return try JSONDecoder().decode(State.self, from: data)
                }.value
                enabled = state.enabled; available = true
            } catch { errorMessage = "Phone senses could not be read: \(error.localizedDescription)" }
        }
    }

    private func enqueue(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let previous = work
        let next = Task {
            await previous?.value
            await restorationTask?.value
            guard available else { return }
            do { try await body() }
            catch {
                errorMessage = "Phone senses are waiting: \(error.localizedDescription)"
                // Drain accepted work despite new admission failure so receipts can release outbox capacity.
                await publishNow()
            }
        }
        work = next
        return next
    }

    private func save(_ change: (inout State) throws -> Void) async throws {
        var next = state
        try change(&next)
        try await storage.checkpoint(next, to: file)
        for pending in state.pending where !next.pending.contains(where: { $0.event.id == pending.event.id }) {
            iCloudBridge.shared.retireDelivery(for: pending.event.id)
        }
        state = next; enabled = next.enabled
    }

    private var pairing: String? { AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) }

    @discardableResult
    func set(_ source: PhoneSenseEvent.Source, enabled value: Bool, authority: PhoneSettingWrite) -> Task<Void, Never> {
        return enqueue {
            guard source != .places else { throw PhoneLocalSetting.failure("Use the saved place's switch.") }
            try authority.check(raising: value && !self.state.enabled.contains(source))
            if value {
                guard self.pairing != nil && iCloudBridge.shared.usesCloudKitDeviceTransport else {
                    self.errorMessage = "Pair this phone with the Mac over CloudKit before sharing a phone sense."; return
                }
                try await self.reconcilePairing()
            }
            // Checkpoint local opt-out and retire this source before pairing-dependent sampling or sending.
            try await self.save { state in
                try authority.check(raising: value && !state.enabled.contains(source))
                if value { state.enabled.insert(source) } else { state.enabled.remove(source) }
                // Keep source timestamps across toggles so old readings cannot overwrite a newer disabled event.
                state.pending.removeAll { $0.event.source == source }
            }
            try authority.check(raising: value)
            if source == .focus, value {
                self.requestFocusAuthorization(authority: authority)
            }
            if source == .motion {
                self.motionQuery = nil
            }
            if source == .motion, value { self.queryMotion(allowPrompt: true) }
            if value { self.bodyReadings.requestPermission(for: source) }
            if !value { try await self.record(source, value: "disabled") }
            try await self.sample()
        }
    }

    /// OS consent may wait indefinitely; it must not hold the sampling/settings queue or block disabling Focus.
    private func requestFocusAuthorization(authority: PhoneSettingWrite) {
        guard focusAuthorization == nil else { return }
        focusAuthorization = Task {
            defer { focusAuthorization = nil }
            guard enabled.contains(.focus) else { return }
            do { try authority.check(raising: true) }
            catch { errorMessage = error.localizedDescription; return }
            let status = await INFocusStatusCenter.default.requestAuthorization()
            if enabled.contains(.focus), status != .authorized {
                errorMessage = "Focus is unknown. Allow Focus Status in iPhone Settings to share it."
            }
            wake()
        }
    }

    var settingControls: [PhoneLocalSetting] {
        PhoneSenseEvent.Source.allCases.filter { $0 != .places }.map { source in
            PhoneLocalSetting(id: "phone.senses.\(source.rawValue)", label: "iPhone \(source.title)", type: "boolean",
                read: { try self.settingEnabled(source) ? "true" : "false" }, write: { value, authority in
                    let wanted = try PhoneLocalSetting.boolean(value)
                    if try self.settingEnabled(source) == wanted { return }
                    await self.set(source, enabled: wanted, authority: authority).value
                    guard try self.settingEnabled(source) == wanted else {
                        throw PhoneLocalSetting.failure(self.errorMessage ?? "The phone sense switch did not change.")
                    }
                }, approval: { try PhoneLocalSetting.boolean($0) && !self.settingEnabled(source) })
        }
    }
    private func settingEnabled(_ source: PhoneSenseEvent.Source) throws -> Bool {
        guard available else {
            throw PhoneLocalSetting.failure((errorMessage ?? "Phone senses storage is not ready.")
                + " Repair phone-senses.json in the iPhone app data, then reopen NativeAgent Settings → Phone senses.")
        }
        return enabled.contains(source)
    }

    /// Sample only on existing wakes; no activity stream, continuous updates or timer may keep the app alive.
    func wake() { enqueue { try await self.sample() } }

    private func reconcilePairing() async throws {
        guard let store = iCloudBridge.shared.pairingStore else {
            throw DeviceSyncError.notConfigured
        }
        let identity = try store.sensePairingIdentity()
        guard state.pairing != identity else { return }
        try await save { state in
            state.enabled = []; state.pending = []; state.latest = [:]; state.pairing = identity
        }
        UIDevice.current.isBatteryMonitoringEnabled = false
        location.stopMonitoringSignificantLocationChanges()
        motionQuery = nil
        bodyReadings.stop()
    }

    private func sample() async throws {
        try await reconcilePairing()
        // Drain before sampling: a full outbox must not block its own send.
        await publishNow()
        UIDevice.current.isBatteryMonitoringEnabled = state.enabled.contains(.charging) || state.enabled.contains(.battery)
        if !state.enabled.isEmpty, location.authorizationStatus == .authorizedAlways,
           CLLocationManager.significantLocationChangeMonitoringAvailable() {
            location.startMonitoringSignificantLocationChanges()
        } else { location.stopMonitoringSignificantLocationChanges() }
        for source in PhoneSenseEvent.Source.allCases {
            let setup = source == .places ? PhonePlaces.shared.senseSetup : setup(for: source)
            try await record(source, value: "setup", setup: setup)
        }
        if state.enabled.contains(.focus) {
            let center = INFocusStatusCenter.default
            let focused = center.authorizationStatus == .authorized ? center.focusStatus.isFocused : nil
            try await record(.focus, value: focused.map { $0 ? "on" : "off" } ?? "unknown")
        }
        if state.enabled.contains(.charging) {
            let battery = UIDevice.current.batteryState
            let value = battery == .charging || battery == .full ? "charging" : battery == .unplugged ? "unplugged" : "unknown"
            let hour = Calendar.current.component(.hour, from: Date())
            try await record(.charging, value: value, night: hour >= 22 || hour < 7)
        }
        if state.enabled.contains(.motion) { queryMotion(allowPrompt: false) }
        bodyReadings.sample(enabled: state.enabled, pairing: pairing)
        await publishNow()
    }

    private func setup(for source: PhoneSenseEvent.Source) -> PhoneSenseEvent.Setup {
        let on = state.enabled.contains(source)
        if source == .motion {
            let status = CMMotionActivityManager.authorizationStatus()
            let permission = Self.motionPermission(status)
            return .init(enabled: on, required: "Motion & Fitness", permission: permission,
                missing: (on ? [] : ["turn on Motion in NativeAgent Settings → Phone senses"])
                    + (status == .authorized ? [] : ["allow Motion & Fitness in iPhone Settings"])
                    + (CMMotionActivityManager.isActivityAvailable() ? [] : ["motion activity unavailable on this device"]))
        }
        if source == .focus {
            let status = INFocusStatusCenter.default.authorizationStatus
            let permission: String = switch status {
            case .authorized: "authorized"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not determined"
            @unknown default: "unrecognized iOS status"
            }
            return .init(enabled: on, required: "Focus Status", permission: permission,
                missing: (on ? [] : ["turn on Focus in NativeAgent Settings → Phone senses"])
                    + (status == .authorized ? [] : ["allow Focus Status in iPhone Settings"]))
        }
        return bodyReadings.setup(for: source, enabled: on)
    }

    static func motionPermission(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unrecognized iOS status"
        }
    }

    /// Scalar evidence crosses callbacks; framework objects never cross an actor boundary.
    func observed(_ source: PhoneSenseEvent.Source, value: String, summary: String? = nil, pairing key: String?, at: Date) {
        enqueue {
            guard key == self.pairing, self.state.enabled.contains(source) else { return }
            try await self.record(source, value: value, at: at, summary: summary)
            await self.publishNow()
        }
    }

    private func queryMotion(allowPrompt: Bool) {
        guard motionQuery == nil else { return }
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized
                || (allowPrompt && CMMotionActivityManager.authorizationStatus() == .notDetermined) else {
            enqueue {
                guard self.state.enabled.contains(.motion) else { return }
                try await self.record(.motion, value: "unknown"); await self.publishNow()
            }
            return
        }
        let query = UUID(), key = pairing
        motionQuery = query
        let end = Date()
        motion.queryActivityStarting(from: end.addingTimeInterval(-15 * 60), to: end, to: .main) { activities, error in
            let last = activities?.max { $0.startDate < $1.startDate }
            var flags: [String] = []
            var confidence: String?
            var began: Date?
            if error == nil, let last {
                if last.stationary { flags.append("stationary") }
                if last.walking { flags.append("walking") }
                if last.running { flags.append("running") }
                if last.cycling { flags.append("cycling") }
                if last.automotive { flags.append("driving") }
                if last.unknown { flags.append("unknown") }
                confidence = switch last.confidence {
                case .low: "low"
                case .medium: "medium"
                case .high: "high"
                @unknown default: nil
                }
                began = last.startDate
            }
            let value = flags.isEmpty ? "unknown" : flags.joined(separator: "+")
            // Immutable Sendable scalars only in the MainActor task.
            let reportedConfidence = confidence, activityTime = began, failure = error?.localizedDescription
            Task { @MainActor in
                guard self.motionQuery == query else { return }
                self.motionQuery = nil
                self.enqueue {
                    guard self.state.enabled.contains(.motion), self.pairing == key else { return }
                    if let failure { self.errorMessage = "Phone motion unavailable: \(failure)" }
                    try await self.record(.motion, value: value, at: end, confidence: reportedConfidence, activityStartedAt: activityTime)
                    try await self.record(.motion, value: "setup", setup: self.setup(for: .motion))
                    await self.publishNow()
                }
            }
        }
    }

    private func record(_ source: PhoneSenseEvent.Source, value: String, night: Bool? = nil, at: Date = Date(),
                        setup: PhoneSenseEvent.Setup? = nil, confidence: String? = nil, activityStartedAt: Date? = nil, summary: String? = nil) async throws {
        guard let pairing, state.pairing == pairing else { return }
        let slot = source.rawValue + (value == "setup" ? "/setup" : "")
        let previous = state.latest[slot]
        guard previous.map({ $0.timestamp <= at }) ?? true else { return }
        // Unchanged is not unknown: a reading re-reports before the Mac's fifteen minutes would call it historical.
        let held = value != "setup" && previous.map { at.timeIntervalSince($0.timestamp) > 10 * 60 } == true
        guard held || previous?.value != value || previous?.localNight != night || previous?.setup != setup
            || previous?.confidence != confidence || previous?.activityStartedAt != activityStartedAt || previous?.summary != summary else { return }
        guard state.pending.count < 128 else {
            throw DeviceSyncError.underlying(message: "Phone sense changes are waiting to sync. Open NativeAgent with the Mac connected.")
        }
        let event = PhoneSenseEvent(source: source, value: value, timestamp: at, localNight: night,
            setup: setup, confidence: confidence, activityStartedAt: activityStartedAt, summary: summary)
        guard event.isValid else { throw DeviceSyncError.underlying(message: "Invalid \(source.title) evidence was not queued.") }
        try await save { state in
            state.latest[slot] = event
            state.pending.append(Pending(event: event, pairing: pairing))
        }
    }

    func publish() { enqueue { try await self.reconcilePairing(); await self.publishNow() } }

    private func publishNow() async {
        guard iCloudBridge.shared.usesCloudKitDeviceTransport else { return }
        for pending in state.pending.prefix(8) {
            guard pending.pairing == pairing else { return }
            guard state.pending.contains(where: { $0.event.id == pending.event.id }) else { continue }
            guard !iCloudBridge.shared.isAwaitingMacAcceptance(pending.event.id) else { continue }
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(id: pending.event.id,
                    text: String(decoding: try JSONEncoder().encode(pending.event), as: UTF8.self),
                    metadata: ["kind": PhoneSenseEvent.messageKind], preparedMessage: pending.envelope,
                    expectedPairing: pending.pairing,
                    onPrepared: { message in
                        guard self.pairing == pending.pairing,
                              self.state.pending.contains(where: { $0.event.id == pending.event.id }) else { throw CancellationError() }
                        try await self.save { state in
                            if let index = state.pending.firstIndex(where: { $0.event.id == pending.event.id }) {
                                state.pending[index].envelope = message
                            }
                        }
                    })
            } catch { errorMessage = "Phone sense changes are waiting to sync: \(error.localizedDescription)"; return }
        }
    }

    func ownsDelivery(_ id: String) -> Bool { state.pending.contains { $0.event.id == id } }
    func acceptDelivery(_ id: String) async -> Bool {
        await restorationTask?.value
        guard ownsDelivery(id) else { return true }
        await enqueue {
            try await self.save { $0.pending.removeAll { $0.event.id == id } }
        }.value
        if !ownsDelivery(id) { publish() }
        return !ownsDelivery(id)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { wake() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { wake() }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Phone wake location unavailable: \(error.localizedDescription)"
    }
}

struct PhoneSensesSettings: View {
    @ObservedObject private var senses = PhoneSenses.shared
    private var session: FacePageSession { iCloudSyncEngine.shared.pageSessions.page("phone-senses") }
    var body: some View {
        FaceView(face: face, door: door, session: session).task { senses.wake() }
    }
    private var face: PartFace {
        var rows = senses.settingControls.map { control -> PartFace.Row in
            let row = control.row()
            return .init(id: control.id, title: control.label, detail: row.unavailableReason ?? description(control.id),
                control: row.value.map { .init(on: $0 == "true", call: .init("phone.sense.set", ["id": .string(control.id)])) })
        }
        rows += senses.waitingSources.map { .init(id: "waiting-" + $0.rawValue,
            title: "Waiting on \($0.title)", detail: "Turn off its switch to cancel.", tone: .quiet) }
        if let error = senses.errorMessage { rows.append(.init(id: "error", title: error, tone: .failed)) }
        return .init(sections: [.init(id: "senses", title: "Phone senses", footer: """
            All start off. A switch explicitly allows its summary through paired iCloud to your Mac and the selected AI provider. Setup state is shared \
            so your agent can help. No coordinates travel through these senses. Always location, if allowed for Places, can wake a reading. \
            iOS may delay updates; silence means unknown.
            """, rows: rows)])
    }
    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "this iPhone's sense preferences") { submission in
            do {
                guard let id = submission.expectedCall.args["id"]?.stringValue,
                      let control = senses.settingControls.first(where: { $0.id == id }), let write = control.write else {
                    throw PhoneLocalSetting.failure("Read the phone sense before changing it.")
                }
                if !submission.checking {
                    guard let value = submission.value, ["on", "off"].contains(value) else {
                        throw PhoneLocalSetting.failure("This phone sense switch takes on or off.")
                    }
                    try await write(value == "on" ? "true" : "false", .person)
                }
                let value = try control.read()
                return .init(effects: .known, accepted: true,
                    committed: [.init(id: "value", value: .string(value == "true" ? "on" : "off"))])
            } catch { return .interrupted(error) }
        }
    }
    private func description(_ id: String) -> String {
        switch id {
        case "phone.senses.motion": "Shares activity estimates and confidence at wake. Requires Motion & Fitness access."
        case "phone.senses.focus": "Shares Focus on, off or unknown, without its name. Requires Focus Status access."
        case "phone.senses.charging": "Shares charging and whether it is night. Sleep is only an inference, never a fact."
        case "phone.senses.battery": "Shares the current battery percentage, without battery history."
        case "phone.senses.headphones": "Shares this app's audio route, without device names. Bluetooth does not prove headphones."
        case "phone.senses.network": "Shares network kind or unavailability, without names or addresses."
        case "phone.senses.music":
            "Shares Music playback state, song title and artist, without audio or listening history. Requires Media & Apple Music access."
        case "phone.senses.photos": "Shares only today's visible photo count; Limited Access counts your selection, never images."
        default: "Read this phone sense's setup before enabling it."
        }
    }
}
