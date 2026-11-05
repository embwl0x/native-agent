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
    struct Place: Codable, Identifiable {
        var id = UUID().uuidString
        let name: String
        let latitude: Double
        let longitude: Double
        var enabled = false
        var inside: Bool?
        var pairing: String?
    }
    private struct Pending: Codable {
        let event: PhonePlaceEvent
        let pairing: String
        var envelope: BridgeMessage?
    }
    private struct State: Codable, Sendable {
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
            try change(&next)
            try await storage.checkpoint(next, to: file)
            return next
        }
        mutationTask = task
        defer { if mutationGeneration == generation { mutationTask = nil } }
        let next = try await task.value
        guard generation > appliedMutationGeneration else { return }
        appliedMutationGeneration = generation
        for pending in state.pending where !next.pending.contains(where: { $0.event.id == pending.event.id }) {
            iCloudBridge.shared.stopDeliveryNudges(for: pending.event.id)
        }
        state = next; places = next.places
    }

    func addHere(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard available, !locating, state.places.count < 20, !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        newName = name; locating = true
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        else { requestFix() }
    }

    private func requestFix() {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: location.requestLocation()
        case .denied, .restricted:
            locating = false; newName = nil
            errorMessage = "Allow location in iPhone Settings to save this place."
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
        locating = false; newName = nil
        guard let fix = locations.last, (0...200).contains(fix.horizontalAccuracy),
              abs(fix.timestamp.timeIntervalSinceNow) < 60 else {
            errorMessage = "A precise current location was unavailable. Try saving this place again with Precise Location enabled."
            return
        }
        let latitude = fix.coordinate.latitude, longitude = fix.coordinate.longitude
        Task {
            do {
                try await save { $0.places.append(Place(name: name, latitude: latitude, longitude: longitude)) }
                resume()
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locating = false; newName = nil; errorMessage = error.localizedDescription
    }
}

struct PhonePlacesSettings: View {
    @ObservedObject private var places = PhonePlaces.shared
    @State private var label = "Home"
    @State private var custom = ""
    var body: some View {
        AliveSection("Places") {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                    Shares enabled place names and arrival/departure times through your paired iCloud connection to your Mac and the AI provider selected \
                    there. When you ask your agent to inspect phone settings, saved place names and switches are also shared, including disabled places; \
                    coordinates stay on this phone. Save your current location, then enable the place.
                    """)
                    .font(.footnote).foregroundStyle(AlivePalette.secondary)
                ForEach(places.places) { place in
                    HStack {
                        Toggle(place.name, isOn: Binding(get: { place.enabled }, set: { value in Task { await places.setEnabled(place.id, value,
                            authority: .person) } }))
                        Button(role: .destructive) { Task { await places.remove(place.id) } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete \(place.name)")
                    }
                }
                if places.places.contains(where: \.enabled), !places.alwaysAllowed {
                    Text("Enabled places need Always location access. Choose Always in iPhone Settings.").font(.footnote)
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Picker("Place name", selection: $label) {
                    Text("Home").tag("Home"); Text("Work").tag("Work"); Text("Custom").tag("Custom")
                }.pickerStyle(.segmented)
                if label == "Custom" { TextField("Place name", text: $custom).textFieldStyle(.roundedBorder) }
                Button(places.locating ? "Finding this location…" : "Save this location") {
                    places.addHere(name: label == "Custom" ? custom : label)
                }.disabled(places.locating || places.places.count >= 20
                    || (label == "Custom" && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Text("Places cover about 200 metres. Location updates may be delayed by iOS.").font(.footnote).foregroundStyle(AlivePalette.secondary)
                if let error = places.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }.aliveRow()
        }
        .task { places.resume() }
    }
}
