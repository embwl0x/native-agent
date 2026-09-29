import CoreLocation
import NativeAgentShared
import SwiftUI

@MainActor
final class PhonePlaces: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = PhonePlaces()
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
    private struct State: Codable {
        var places: [Place] = []
        var pending: [Pending] = []
    }
    @Published private(set) var places: [Place] = []
    @Published var errorMessage: String?
    @Published private(set) var locating = false
    @Published private(set) var alwaysAllowed = false
    private var state = State()
    private var available = true
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

    private override init() {
        super.init()
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            }
            places = state.places
        } catch { available = false; errorMessage = "Places could not be read: \(error.localizedDescription)" }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        alwaysAllowed = location.authorizationStatus == .authorizedAlways
    }

    private func save(_ change: (inout State) -> Void) throws {
        guard available else { throw DeviceSyncError.underlying(message: "Places storage is unavailable.") }
        var next = state
        change(&next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    func setEnabled(_ id: String, _ enabled: Bool) {
        let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests)
        guard !enabled || pairing != nil else {
            errorMessage = "Pair this phone with your Mac before enabling a place."; return
        }
        guard !enabled || iCloudBridge.shared.usesCloudKitDeviceTransport else {
            errorMessage = "Places need the paired CloudKit connection to your Mac."; return
        }
        do {
            try save { state in
                guard let index = state.places.firstIndex(where: { $0.id == id }) else { return }
                state.places[index].enabled = enabled
                state.places[index].inside = nil
                state.places[index].pairing = enabled ? pairing : nil
                if !enabled { state.pending.removeAll { $0.event.placeID == id } }
            }
            // Only this explicit enable action can ask for Always access.
            if enabled { location.requestAlwaysAuthorization() }
            resume()
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ id: String) {
        do {
            try save { state in
                state.places.removeAll { $0.id == id }
                state.pending.removeAll { $0.event.placeID == id }
            }
            resume()
        } catch { errorMessage = error.localizedDescription }
    }

    func resume() {
        guard available else { return }
        reconcileAgain = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task {
            defer { reconcileTask = nil }
            while reconcileAgain {
                reconcileAgain = false
                await reconcile()
            }
            await publish()
        }
    }

    private func reconcile() async {
        let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests)
        do {
            try save { state in
                for index in state.places.indices where state.places[index].enabled && state.places[index].pairing != pairing {
                    state.places[index].enabled = false
                    state.places[index].inside = nil
                }
                state.pending.removeAll { $0.pairing != pairing }
            }
        } catch { errorMessage = error.localizedDescription; return }
        alwaysAllowed = location.authorizationStatus == .authorizedAlways
        let enabled = state.places.filter { $0.enabled && alwaysAllowed }
        // Re-take the session on a location relaunch; never request it for an
        // app with no enabled places or without the person's Always grant.
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
                    try observed(event)
                    await publish()
                }
            } catch { errorMessage = "Place monitoring stopped: \(error.localizedDescription)" }
        }
    }

    private func observed(_ event: CLMonitor.Event) throws {
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
        try save { state in
            state.places[index].inside = inside
            // The first fix establishes a baseline, not a claimed journey.
            if place.inside != nil {
                let event = PhonePlaceEvent(id: "place-\(place.id)-\(event.date.timeIntervalSince1970)-\(inside)",
                    placeID: place.id, name: place.name, transition: inside ? .arrived : .left, timestamp: event.date)
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
                  state.places.contains(where: { $0.id == pending.event.placeID && $0.enabled }) else { continue }
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(id: pending.event.id,
                    text: String(decoding: try JSONEncoder().encode(pending.event), as: UTF8.self),
                    metadata: ["kind": PhonePlaceEvent.messageKind], preparedMessage: pending.envelope,
                    onPrepared: { message in
                        guard self.state.pending.contains(where: { $0.event.id == pending.event.id }),
                              pending.pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else {
                            throw CancellationError()
                        }
                        try self.save { state in
                            if let index = state.pending.firstIndex(where: { $0.event.id == pending.event.id }) {
                                state.pending[index].envelope = message
                            }
                        }
                    })
                try save { $0.pending.removeAll { $0.event.id == pending.event.id } }
            } catch { errorMessage = "Place events are waiting to sync: \(error.localizedDescription)"; return }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        alwaysAllowed = manager.authorizationStatus == .authorizedAlways
        if locating { requestFix() }
        // Launch wiring calls resume after binding the pairing store.
        if monitor != nil { resume() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let name = newName else { return }
        locating = false; newName = nil
        guard let fix = locations.last, (0...200).contains(fix.horizontalAccuracy),
              abs(fix.timestamp.timeIntervalSinceNow) < 60 else {
            errorMessage = "A precise current location was unavailable. Try saving this place again with Precise Location enabled."
            return
        }
        do {
            try save { $0.places.append(Place(name: name, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)) }
        } catch { errorMessage = error.localizedDescription }
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
                Text("Let your agent know when this phone arrives or leaves. Save your current location, then enable the place.")
                    .font(.footnote).foregroundStyle(AlivePalette.secondary)
                ForEach(places.places) { place in
                    HStack {
                        Toggle(place.name, isOn: Binding(get: { place.enabled }, set: { places.setEnabled(place.id, $0) }))
                        Button(role: .destructive) { places.remove(place.id) } label: { Image(systemName: "trash") }
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
                }.disabled(places.locating || places.places.count >= 20 || (label == "Custom" && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Text("Places cover about 200 metres. Location updates may be delayed by iOS.").font(.footnote).foregroundStyle(AlivePalette.secondary)
                if let error = places.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }.aliveRow()
        }
        .task { places.resume() }
    }
}
