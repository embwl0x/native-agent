import CoreLocation
import Foundation
import NativeAgentShared
import SwiftUI
import UIKit
// Blueprint: | `PhonePlaces.swift` | Opt-in places and pairing-bound outbox; per-observation admission errors and receipt-driven delivery |

@MainActor
final class PhonePlaces: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = PhonePlaces()
    var settingControls: [PhoneLocalSetting] {
        let inventory = PhoneLocalSetting(id: "phone.places", label: "Saved iPhone places", type: "list", read: {
            try self.requireSettingsAvailable()
            return self.state.places.map { "\($0.id.lowercased()): \($0.name)" }.joined(separator: "\n")
        }, ownsChildSettings: true)
        return [inventory] + state.places.flatMap { place in
            [PhoneLocalSetting(id: "phone.places.\(place.id.lowercased()).enabled", label: "iPhone place: \(place.name)", type: "boolean",
                read: {
                    try self.requireSettingsAvailable()
                    guard let saved = self.state.places.first(where: { $0.id == place.id }) else {
                        throw PhoneLocalSetting.failure("This saved place is unavailable. Open iPhone NativeAgent Settings → Places.")
                    }
                    return saved.enabled ? "true" : "false"
                }, write: { value, authority in
                    let wanted = try PhoneLocalSetting.boolean(value)
                    if self.state.places.first(where: { $0.id == place.id })?.enabled == wanted { return }
                    await self.setEnabled(place.id, wanted, authority: authority)
                    guard self.state.places.first(where: { $0.id == place.id })?.enabled == wanted else {
                        throw PhoneLocalSetting.failure(self.errorMessage ?? "The saved place switch did not change.")
                    }
                }, approval: { value in
                    let wanted = try PhoneLocalSetting.boolean(value)
                    try self.requireSettingsAvailable()
                    guard let saved = self.state.places.first(where: { $0.id == place.id }) else {
                        throw PhoneLocalSetting.failure("The place is unavailable. Open iPhone NativeAgent Settings → Places and read phone.settings again.")
                    }
                    return wanted && !saved.enabled
                })]
        }
    }
    private func requireSettingsAvailable() throws {
        guard available else {
            throw PhoneLocalSetting.failure((errorMessage ?? "Places storage is not ready.")
                + " Repair phone-places.json in the iPhone app data, then reopen NativeAgent Settings → Places.")
        }
    }
    struct Place: Codable, Identifiable, Sendable, Equatable {
        var id = UUID().uuidString
        let name: String
        let latitude: Double
        let longitude: Double
        var enabled = false
        var inside: Bool?
        var pairing: String?
    }
    private struct Pending: Codable, Sendable, Equatable {
        let event: PhonePlaceEvent
        let pairing: String
        var envelope: BridgeMessage?
    }
    private struct State: Codable, Sendable, Equatable {
        var places: [Place] = []
        var pending: [Pending] = []
    }
    @Published private(set) var places: [Place] = []
    @Published var errorMessage: String?
    @Published private(set) var locating = false
    @Published private(set) var alwaysAllowed = false
    private var state = State()
    private let storage = MobileLocalStorage()
    private var mutationTask: Task<State, Error>?
    private var mutationGeneration = 0
    private var appliedMutationGeneration = 0
    private var available = false
    private(set) var restorationTask: Task<Void, Never>?
    private let file = URL.applicationSupportDirectory.appendingPathComponent("phone-places.json")
    private let location = CLLocationManager()
    private var newName: String?
    private var locationReply: CheckedContinuation<Place, any Error>?
    private var locationRequest: UUID?
    private var monitor: CLMonitor?
    private var service: CLServiceSession?
    private var eventsTask: Task<Void, Never>?
    private var eventsGeneration = UUID()
    private var reconcileTask: Task<Void, Never>?
    private var reconcileAgain = false
    private var publishing = false

    /// Setup is read from the place owner, never a mirrored enabled/permission latch.
    var senseSetup: PhoneSenseEvent.Setup {
        let status = location.authorizationStatus
        let permission: String = switch status {
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "while-in-use"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unrecognized iOS status"
        }
        let precise = location.accuracyAuthorization == .fullAccuracy
        var missing: [String] = []
        if !available { missing.append("Places storage not ready; open NativeAgent and check Places") }
        else if state.places.isEmpty { missing.append("no place added yet") }
        else if !state.places.contains(where: \.enabled) { missing.append("enable a saved place in NativeAgent Settings → Places") }
        if status != .authorizedAlways { missing.append("choose Always location in iPhone Settings") }
        if !precise { missing.append("turn on Precise Location in iPhone Settings") }
        if !CLLocationManager.locationServicesEnabled() { missing.append("turn on Location Services in iPhone Settings → Privacy & Security") }
        return .init(enabled: available ? state.places.contains(where: \.enabled) : nil,
            required: "Location: Always and Precise Location", permission: "\(permission); precise \(precise ? "on" : "off")",
            missing: missing, detail: available ? "\(state.places.count) saved; \(state.places.filter(\.enabled).count) enabled"
                : "saved places not yet readable")
    }

    private override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        alwaysAllowed = location.authorizationStatus == .authorizedAlways
        let file = file
        restorationTask = Task {
            do {
                let restored = try await Task.detached(priority: .utility) {
                    let data: Data
                    do { data = try Data(contentsOf: file) }
                    catch CocoaError.fileReadNoSuchFile { return State() }
                    return try JSONDecoder().decode(State.self, from: data)
                }.value
                state = restored
                places = restored.places
                available = true
                if reconcileAgain { resume() }
            } catch { errorMessage = "Places could not be read: \(error.localizedDescription)" }
        }
    }

    private func save(_ change: @escaping (inout State) throws -> Void) async throws {
        guard available else { throw DeviceSyncError.underlying(message: "Places storage is unavailable.") }
        let previous = mutationTask
        let base = state
        mutationGeneration += 1
        let generation = mutationGeneration
        let task = Task {
            var next = try await previous?.value ?? base
            let before = next
            try change(&next)
            if next == before { return next }
            try await storage.checkpoint(next, to: file)
            return next
        }
        mutationTask = task
        defer { if mutationGeneration == generation { mutationTask = nil } }
        let next = try await task.value
        guard generation > appliedMutationGeneration else { return }
        appliedMutationGeneration = generation
        guard next != state else { return }
        for pending in state.pending where !next.pending.contains(where: { $0.event.id == pending.event.id }) {
            iCloudBridge.shared.retireDelivery(for: pending.event.id)
        }
        state = next; places = next.places
    }

    func addHere(name: String, id: UUID) async throws -> Place {
        await restorationTask?.value
        do { try requireSettingsAvailable(); try Task.checkCancellation() }
        catch { throw Self.locationFailure(error) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locating, state.places.count < 20, !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Self.locationFailure(PhoneLocalSetting.failure(
                "Choose a place name of 1–60 characters; at most 20 places can be saved, one at a time."))
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw Self.locationFailure(CancellationError()) }
            return try await withCheckedThrowingContinuation { reply in
                locationReply = reply; locationRequest = id
                newName = name; locating = true
                if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
                else { requestFix() }
            }
        } onCancel: {
            Task { @MainActor in
                // Once the location callback starts saving, its real save result still owes settlement.
                guard self.locationRequest == id, self.newName != nil else { return }
                self.location.stopUpdatingLocation()
                self.finishLocation(.failure(Self.locationFailure(CancellationError())))
            }
        }
    }

    /// Join the owner's save before reading the exact submitted identity from durable storage.
    func readPlace(id: String) async throws -> Place? {
        await restorationTask?.value
        _ = await mutationTask?.result
        let file = file
        return try await Task.detached(priority: .utility) { () throws -> Place? in
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            return try JSONDecoder().decode(State.self, from: data).places.first { $0.id == id }
        }.value
    }

    private static func locationFailure(_ error: any Error) -> WireFailure {
        WireFailure(code: "place_not_saved", message: "The place was not saved.", cause: error.localizedDescription, effects: .none)
    }

    private func finishLocation(_ result: Result<Place, any Error>) {
        let reply = locationReply
        locationReply = nil; locationRequest = nil; locating = false; newName = nil
        reply?.resume(with: result)
    }

    private func requestFix() {
        guard newName != nil else { return }
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: location.requestLocation()
        case .denied, .restricted:
            errorMessage = "Allow location in iPhone Settings to save this place."
            finishLocation(.failure(Self.locationFailure(PhoneLocalSetting.failure(
                "Allow location in iPhone Settings to save this place."))))
        default: break
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool, authority: PhoneSettingWrite) async {
        let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests)
        guard !enabled || pairing != nil else {
            errorMessage = "Pair this phone with your Mac before enabling a place."; return
        }
        guard !enabled || iCloudBridge.shared.usesCloudKitDeviceTransport else {
            errorMessage = "Places need the paired CloudKit connection to your Mac."; return
        }
        do {
            try await save { state in
                guard let index = state.places.firstIndex(where: { $0.id == id }) else { throw PhoneLocalSetting.failure("This place is no longer saved.") }
                try authority.check(raising: enabled && !state.places[index].enabled)
                state.places[index].enabled = enabled
                state.places[index].inside = nil
                state.places[index].pairing = enabled ? pairing : nil
                if !enabled { state.pending.removeAll { $0.event.placeID == id } }
            }
            // Only this explicit enable action can ask for Always access.
            try authority.check(raising: enabled)
            if enabled { location.requestAlwaysAuthorization() }
            resume()
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ id: String) async {
        do {
            try await save { state in
                state.places.removeAll { $0.id == id }
                state.pending.removeAll { $0.event.placeID == id }
            }
            resume()
        } catch { errorMessage = error.localizedDescription }
    }

    func resume() {
        // Setup must not wait for CLMonitor's async construction or reconciliation.
        PhoneSenses.shared.wake()
        reconcileAgain = true
        guard available else { return }
        guard reconcileTask == nil else { return }
        reconcileTask = Task {
            defer { reconcileTask = nil }
            while reconcileAgain {
                reconcileAgain = false
                await reconcile()
            }
            PhoneSenses.shared.wake()
            await publish()
        }
    }

    private func reconcile() async {
        do {
            guard let store = iCloudBridge.shared.pairingStore else { throw DeviceSyncError.notConfigured }
            let pairing = try store.sensePairingIdentity()
            try await save { state in
                for index in state.places.indices where state.places[index].enabled && state.places[index].pairing != pairing {
                    state.places[index].enabled = false
                    state.places[index].inside = nil
                }
                state.pending.removeAll { $0.pairing != pairing }
            }
        } catch { errorMessage = error.localizedDescription; return }
        alwaysAllowed = location.authorizationStatus == .authorizedAlways
        let enabled = state.places.filter { $0.enabled && alwaysAllowed }
        // Reacquire on location relaunch only with enabled places and an existing Always grant.
        if enabled.isEmpty { service?.invalidate(); service = nil }
        else if service == nil { service = CLServiceSession(authorization: .always) }
        if monitor == nil { monitor = await CLMonitor("NativeAgentPlaces") }
        guard let monitor else { return }
        let identifiers = await monitor.identifiers
        for id in identifiers where !enabled.contains(where: { $0.id == id }) { await monitor.remove(id) }
        for place in enabled where !identifiers.contains(place.id) {
            await monitor.add(CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), radius: 200),
                identifier: place.id)
        }
        guard !enabled.isEmpty else {
            eventsGeneration = UUID()
            eventsTask?.cancel(); eventsTask = nil
            return
        }
        guard eventsTask == nil else { return }
        let generation = UUID()
        eventsGeneration = generation
        eventsTask = Task {
            defer { if eventsGeneration == generation { eventsTask = nil } }
            do {
                for try await event in await monitor.events {
                    guard !Task.isCancelled, eventsGeneration == generation else { return }
                    // Admission failure belongs to this observation; a full outbox must not stop delivery or monitoring.
                    do { try await observed(event) }
                    catch { errorMessage = error.localizedDescription }
                    PhoneSenses.shared.wake()
                    await publish()
                }
            } catch { errorMessage = "Place monitoring stopped: \(error.localizedDescription)" }
        }
    }

    private func observed(_ event: CLMonitor.Event) async throws {
        guard event.state == .satisfied || event.state == .unsatisfied else {
            errorMessage = "A place could not be monitored. Check Always location and Precise Location in iPhone Settings."
            return
        }
        guard let index = state.places.firstIndex(where: { $0.id == event.identifier && $0.enabled }),
              let pairing = state.places[index].pairing,
              pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else { return }
        let place = state.places[index], inside = event.state == .satisfied
        guard place.inside != inside else { return }
        guard state.pending.count < 128 else { throw DeviceSyncError.underlying(message: "Place events are waiting to sync. Open the app when connected.") }
        try await save { state in
            guard let index = state.places.firstIndex(where: { $0.id == place.id && $0.enabled && $0.pairing == pairing }),
                  state.places[index].inside != inside else { return }
            let previousInside = state.places[index].inside
            state.places[index].inside = inside
            // A first inside fix proves presence only; a first outside fix cannot prove departure from an unseen place.
            if previousInside != nil || inside {
                let event = PhonePlaceEvent(id: "place-\(place.id)-\(event.date.timeIntervalSince1970)-\(inside)",
                    placeID: place.id, name: place.name,
                    transition: previousInside == nil ? .at : inside ? .arrived : .left, timestamp: event.date)
                state.pending.append(Pending(event: event, pairing: pairing))
            }
        }
    }

    func publish() async {
        guard available, !publishing else { return }
        guard iCloudBridge.shared.usesCloudKitDeviceTransport else {
            if !state.pending.isEmpty { errorMessage = "Place events are waiting for the paired CloudKit connection." }
            return
        }
        publishing = true
        defer { publishing = false }
        for pending in state.pending.prefix(8) {
            guard pending.pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else { return }
            guard state.pending.contains(where: { $0.event.id == pending.event.id }),
                  state.places.contains(where: { $0.id == pending.event.placeID && $0.enabled }),
                  !iCloudBridge.shared.isAwaitingMacAcceptance(pending.event.id) else { continue }
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(id: pending.event.id,
                    text: String(decoding: try JSONEncoder().encode(pending.event), as: UTF8.self),
                    metadata: ["kind": PhonePlaceEvent.messageKind], preparedMessage: pending.envelope,
                    expectedPairing: pending.pairing,
                    onPrepared: { message in
                        guard self.state.pending.contains(where: { $0.event.id == pending.event.id }),
                              pending.pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else {
                            throw CancellationError()
                        }
                        try await self.save { state in
                            if let index = state.pending.firstIndex(where: { $0.event.id == pending.event.id }) {
                                state.pending[index].envelope = message
                            }
                        }
                    })
            } catch { errorMessage = "Place events are waiting to sync: \(error.localizedDescription)"; return }
        }
    }

    func ownsDelivery(_ id: String) -> Bool {
        state.pending.contains { $0.event.id == id }
    }

    func acceptDelivery(_ id: String) async -> Bool {
        await restorationTask?.value
        guard ownsDelivery(id) else { return true }
        do {
            try await save { $0.pending.removeAll { $0.event.id == id } }
            Task { await publish() }
            return true
        } catch {
            errorMessage = "Place acceptance could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        alwaysAllowed = manager.authorizationStatus == .authorizedAlways
        if locating { requestFix() }
        if monitor != nil { resume() }
        else if available { PhoneSenses.shared.wake() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let name = newName else { return }
        let request = locationRequest
        guard let fix = locations.last, (0...200).contains(fix.horizontalAccuracy),
              abs(fix.timestamp.timeIntervalSinceNow) < 60 else {
            errorMessage = "A precise current location was unavailable. Try saving this place again with Precise Location enabled."
            finishLocation(.failure(Self.locationFailure(PhoneLocalSetting.failure(
                "A precise current location was unavailable. Enable Precise Location and save again."))))
            return
        }
        let latitude = fix.coordinate.latitude, longitude = fix.coordinate.longitude
        guard let request else { return }
        let place = Place(id: request.uuidString, name: name, latitude: latitude, longitude: longitude)
        newName = nil
        Task {
            do {
                try await save { $0.places.append(place) }
                if locationRequest == request { finishLocation(.success(place)) }
                resume()
            }
            catch {
                errorMessage = error.localizedDescription
                if locationRequest == request { finishLocation(.failure(error)) }
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard newName != nil else { return }
        errorMessage = error.localizedDescription
        finishLocation(.failure(Self.locationFailure(error)))
    }
}

struct PhonePlacesSettings: View {
    @ObservedObject private var places = PhonePlaces.shared
    private var session: FacePageSession { iCloudSyncEngine.shared.pageSessions.page("phone-places") }
    var body: some View {
        FaceView(face: face, door: door, session: session).task { places.resume() }
    }

    private var face: PartFace {
        var sections: [PartFace.Section] = [.init(id: "places", title: "Places", footer: """
            Enabled place names and arrival/departure times travel through your paired iCloud connection to the Mac and its selected AI provider. \
            Saved names and switches are shared when requested, including disabled places; coordinates stay on this phone. Places cover about 200 metres. \
            iOS may delay updates. Save a location, then enable its place.
            """, rows: places.places.map { place in
                .init(id: place.id, title: place.name, actions: [.init(id: "delete", label: "Delete", role: .destructive,
                    call: .init("phone.place.remove", ["id": .string(place.id)]))],
                    control: .init(on: place.enabled, call: .init("phone.place.enable", ["id": .string(place.id)])))
            })]
        if places.places.contains(where: \.enabled), !places.alwaysAllowed {
            sections.append(.init(id: "permission", rows: [.init(id: "settings", title: "Enabled places need Always location access.",
                actions: [.init(id: "open", label: "Open iPhone Settings", call: .init("phone.settings.open"))])]))
        }
        sections.append(.init(id: "new-place", title: "Save this location", rows: [], block: .init(kind: "form", key: "new-place",
            fields: [.init(id: "name", label: "Place name", value: .string("Home"), placeholder: "Home, Work, or another name", required: true)],
            submit: [.init(id: "save", label: "Save this location", call: .init("phone.place.add"),
                           unavailable: places.places.count >= 20 ? "At most 20 places can be saved." : nil)])))
        if let error = places.errorMessage { sections.append(.init(id: "issue", rows: [.init(id: "cause", title: error, tone: .failed)])) }
        return PartFace(sections: sections)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "this iPhone's location and saved places") { submission in
            if submission.checking {
                do {
                    if submission.expectedCall.action == "phone.place.add" {
                        if let place = try await places.readPlace(id: submission.id.uuidString) {
                            return .init(words: "Saved " + place.name + ".", effects: .known, accepted: true,
                                committed: [.init(id: "name", value: .string("Home"))])
                        }
                        return .init(words: "The completed save left no place with this request's identity. You can try again.",
                            effects: .none, accepted: true)
                    }
                    if let id = submission.expectedCall.args["id"]?.stringValue {
                        let saved = try await places.readPlace(id: id)
                        if submission.expectedCall.action == "phone.place.remove", saved == nil {
                            return .init(words: "The place is no longer saved.", effects: .known, accepted: true)
                        }
                        if submission.expectedCall.action == "phone.place.enable", let saved {
                            let value = saved.enabled ? "on" : "off"
                            if value == submission.value {
                                return .init(effects: .known, accepted: true, committed: [.init(id: "value", value: .string(value))])
                            }
                        }
                    }
                    return .init(words: "The saved places do not confirm this change.", effects: .unknown)
                } catch { return .interrupted(error) }
            }
            do {
                switch submission.expectedCall.action {
                case "phone.place.add":
                    guard let name = submission.values?["name"]?.stringValue else {
                        throw WireFailure(code: "place_name_required", message: "Enter a place name.", cause: nil, effects: .none)
                    }
                    let place = try await places.addHere(name: name, id: submission.id)
                    return .init(words: "Saved \(place.name). Enable its switch to share arrivals and departures.", effects: .known, accepted: true,
                        committed: [.init(id: "name", value: .string("Home"))])
                case "phone.place.enable":
                    guard let id = submission.expectedCall.args["id"]?.stringValue, let value = submission.value,
                          ["on", "off"].contains(value),
                          let control = places.settingControls.first(where: { $0.id == "phone.places.\(id.lowercased()).enabled" }),
                          let write = control.write else { throw PhoneLocalSetting.failure("Read the saved place again before changing its switch.") }
                    try await write(value == "on" ? "true" : "false", .person)
                    let saved = try control.read()
                    return .init(effects: .known, accepted: true, committed: [.init(id: "value", value: .string(saved == "true" ? "on" : "off"))])
                case "phone.place.remove":
                    guard let id = submission.expectedCall.args["id"]?.stringValue,
                          places.places.contains(where: { $0.id == id }) else { throw PhoneLocalSetting.failure("Read the saved place before deleting it.") }
                    places.errorMessage = nil
                    await places.remove(id)
                    if let error = places.errorMessage { throw PhoneLocalSetting.failure(error) }
                    return .init(words: "Place deleted.", effects: .known, accepted: true)
                case "phone.settings.open":
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { throw PhoneLocalSetting.failure("iPhone Settings has no URL.") }
                    guard await UIApplication.shared.open(url) else { throw PhoneLocalSetting.failure("iPhone Settings could not be opened.") }
                    return .init(effects: .none, accepted: true)
                default: throw PhoneLocalSetting.failure("This Places action is unavailable.")
                }
            } catch { return .interrupted(error) }
        }
    }
}
