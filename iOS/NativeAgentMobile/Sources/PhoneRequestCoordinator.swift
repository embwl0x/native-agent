import CoreLocation
import Foundation
import Network
import NativeAgentShared
import PhotosUI
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Durable acceptance precedes transport ACK; execution and result publication
/// are separate so a retry never opens a second picker or repeats a location fix.
/// CLLocationManager is created on the main run loop, which owns its callbacks.
@MainActor
final class PhoneRequestCoordinator: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = PhoneRequestCoordinator()
    @Published private(set) var active: PhoneRequest?
    @Published var errorMessage: String?
    private struct Record: Codable {
        var request: PhoneRequest
        var pairing: String
        var executing = false
        var result: PhoneRequestResult?
        var attachments: [MultimodalAttachment] = []
        var envelope: BridgeMessage?
        var recoveryAttempts: Int?
        var sent = false
    }
    private var records: [Record] = []
    private struct Replay: Codable {
        let id: String
        let kind: PhoneRequest.Kind
        let state: PhoneRequestResult.Status
        let expiresAt: Date
        let finishedAt: Date
    }
    private struct History: Codable {
        var pending: [Record]
        var replay: [Replay]
    }
    private var replay: [Replay] = []
    private var loaded = false
    private var publishing = false
    private let connectivity = NWPathMonitor()
    private var wasConnected = false
    private var recoveryQueued = false
    private var deadline: Task<Void, Never>?
    private var locationManager: CLLocationManager?
    private var locationRequestID: String?
    private var locationStarted = false
    private let file = URL.applicationSupportDirectory.appendingPathComponent("phone-requests.json")

    override private init() {
        super.init()
        connectivity.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = connected && !self.wasConnected
                self.wasConnected = connected
                if recovered { self.syncDidSucceed() }
            }
        }
        connectivity.start(queue: DispatchQueue(label: "phone-request-connectivity"))
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            replay = []
            if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
                // Migrate the original array, scrubbing previously sent payloads.
                records = try decoder.decode([Record].self, from: data)
                for record in records where record.sent {
                    remember(record, state: record.result?.status ?? .completed)
                }
                records.removeAll { $0.sent }
            } else {
                let history = try decoder.decode(History.self, from: data)
                records = history.pending
                replay = history.replay
            }
            try save()
        }
        loaded = true
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(History(pending: records, replay: replay))
            .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func remember(_ record: Record, state: PhoneRequestResult.Status) {
        replay.append(Replay(id: record.request.id, kind: record.request.kind, state: state,
                            expiresAt: record.request.expiresAt, finishedAt: Date()))
        replay = Array(replay.filter { $0.expiresAt > Date().addingTimeInterval(-86_400) }.suffix(128))
    }

    private func expireObsolete(pairing: String) {
        let obsolete = records.filter {
            // Completed payloads get only a short delivery grace period.
            $0.pairing != pairing || $0.request.expiresAt.addingTimeInterval(300) <= Date()
                || ($0.result == nil && $0.request.expiresAt <= Date())
        }
        for record in obsolete { remember(record, state: .expired) }
        let ids = Set(obsolete.map { $0.request.id })
        records.removeAll { ids.contains($0.request.id) }
        replay.removeAll { $0.expiresAt <= Date().addingTimeInterval(-86_400) }
        if let active, ids.contains(active.id) { clearActive() }
    }

    func accept(_ message: BridgeMessage, secret: Data) async -> Bool {
        var refusedRequest: PhoneRequest?
        do {
            let request = try JSONDecoder().decode(PhoneRequest.self, from: Data(message.text.utf8))
            guard request.id == message.id, request.params.isEmpty,
                  request.expiresAt.timeIntervalSince(message.timestamp) <= 125,
                  request.expiresAt > message.timestamp,
                  let pairing = AgentNameCache.fingerprint(secret) else {
                NSLog("[PhoneRequest] Dropping invalid request %@", message.id)
                return true
            }
            refusedRequest = request
            try load()
            expireObsolete(pairing: pairing)
            try save()
            if replay.contains(where: { $0.id == request.id }) { return true }
            if !records.contains(where: { $0.request.id == request.id }) {
                guard records.count < 128 else { throw DeviceSyncError.underlying(message: "Phone request history is full.") }
                records.append(Record(request: request, pairing: pairing))
                do { try save() } catch { records.removeLast(); throw error }
            }
            // Do not hold the shared CloudKit drain while waiting for a person.
            Task { await self.resume() }
            return true
        } catch {
            errorMessage = "Could not accept phone request: \(error.localizedDescription)"
            NSLog("[PhoneRequest] Dropping unaccepted request %@: %@", message.id, error.localizedDescription)
            if let request = refusedRequest {
                Task {
                    guard AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests)
                            == AgentNameCache.fingerprint(secret) else { return }
                    do {
                        let result = PhoneRequestResult(requestID: request.id, status: .denied,
                            message: "The phone could not accept this request.")
                        _ = try await iCloudBridge.shared.sendChatMessage(id: "phone-result-\(request.id)",
                            text: String(decoding: try JSONEncoder().encode(result), as: UTF8.self),
                            correlationID: request.id, metadata: ["kind": PhoneRequestResult.messageKind])
                    } catch { NSLog("[PhoneRequest] Could not publish refusal: %@", error.localizedDescription) }
                }
            }
            return true
        }
    }

    func resume(retrying: Bool = false) async {
        do {
            try load()
            guard let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else { return }
            expireObsolete(pairing: pairing)
            try save()
            let previous = records
            for index in records.indices where records[index].result == nil {
                let record = records[index]
                if record.pairing != pairing || record.request.expiresAt <= Date() {
                    records[index].result = PhoneRequestResult(requestID: record.request.id, status: .expired)
                } else if record.executing && active?.id != record.request.id {
                    records[index].result = PhoneRequestResult(requestID: record.request.id, status: .failed,
                        message: "The app closed while handling this request. It was not repeated.")
                }
            }
            do { try save() } catch { records = previous; throw error }
            if let active, records.first(where: { $0.request.id == active.id })?.result != nil { clearActive() }
            if active == nil, UIApplication.shared.applicationState == .active,
               let record = records.first(where: { $0.result == nil && $0.pairing == pairing }) {
                active = record.request
                deadline = Task { [weak self, request = record.request] in
                    do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) }
                    catch { return }
                    self?.deadline = nil
                    await self?.complete(request.id, status: .expired)
                }
            }
            await publishResults(pairing: pairing, retrying: retrying)
        } catch { errorMessage = "Phone request storage unavailable: \(error.localizedDescription)" }
    }

    func syncDidSucceed() {
        // One bounded batch per recovery/success signal; our own sends must not
        // recursively trigger publication. No collection is repeated here.
        guard !publishing, !recoveryQueued else { return }
        recoveryQueued = true
        Task {
            defer { self.recoveryQueued = false }
            await self.resume(retrying: true)
        }
    }

    private func publishResults(pairing: String, retrying: Bool) async {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        let ids = records.filter {
            $0.pairing == pairing && $0.result != nil && (!retrying || ($0.recoveryAttempts ?? 0) < 3)
        }.prefix(8).map { $0.request.id }
        for id in ids {
            guard AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) == pairing else { return }
            guard let index = records.firstIndex(where: { $0.request.id == id }) else { continue }
            guard let result = records[index].result else { continue }
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(
                    id: "phone-result-\(result.requestID)",
                    text: String(decoding: try JSONEncoder().encode(result), as: UTF8.self),
                    correlationID: result.requestID,
                    metadata: ["kind": PhoneRequestResult.messageKind],
                    attachments: records[index].attachments,
                    preparedMessage: records[index].envelope,
                    onPrepared: { message in
                        guard let index = self.records.firstIndex(where: { $0.request.id == id }) else {
                            throw CancellationError()
                        }
                        self.records[index].envelope = message
                        // The signed envelope is the sole retry payload.
                        self.records[index].attachments = []
                        self.records[index].result = PhoneRequestResult(requestID: id, status: result.status)
                        if retrying { self.records[index].recoveryAttempts = (self.records[index].recoveryAttempts ?? 0) + 1 }
                        try self.save()
                    })
                guard let index = records.firstIndex(where: { $0.request.id == id }) else { continue }
                remember(records.remove(at: index), state: result.status)
                try save()
            } catch { errorMessage = "Phone result is waiting to sync: \(error.localizedDescription)" }
        }
    }

    func complete(_ id: String, status: PhoneRequestResult.Status, values: [String: String] = [:],
                  message: String? = nil, attachments: [MultimodalAttachment] = []) async {
        guard let index = records.firstIndex(where: { $0.request.id == id }), records[index].result == nil else { return }
        let expired = records[index].request.expiresAt <= Date()
        records[index].result = PhoneRequestResult(requestID: id, status: expired ? .expired : status,
            values: expired ? [:] : values, message: message)
        records[index].attachments = expired ? [] : attachments
        do { try save() } catch {
            records[index].result = nil
            records[index].attachments = []
            errorMessage = "Could not save phone result: \(error.localizedDescription)"
            return
        }
        if active?.id == id { clearActive() }
        await resume()
    }

    private func clearActive() {
        deadline?.cancel()
        deadline = nil
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        locationRequestID = nil
        locationStarted = false
        active = nil
    }

    func begin(_ request: PhoneRequest) -> Bool {
        guard active?.id == request.id, request.expiresAt > Date(),
              let index = records.firstIndex(where: { $0.request.id == request.id }),
              records[index].pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests),
              records[index].result == nil, !records[index].executing else { return false }
        records[index].executing = true
        do { try save(); return true }
        catch {
            records[index].executing = false
            errorMessage = "Could not save phone request: \(error.localizedDescription)"
            return false
        }
    }

    func locate(_ request: PhoneRequest) {
        guard begin(request) else { return }
        locationRequestID = request.id
        let manager = CLLocationManager()
        locationManager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: locationManagerDidChangeAuthorization(manager)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager, let id = locationRequestID else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationStarted else { return }
            locationStarted = true
            manager.requestLocation()
        case .denied, .restricted: Task { await complete(id, status: .denied, message: "Location permission is off on this phone.") }
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationManager, let id = locationRequestID,
              let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 60 else { return }
        Task { await complete(id, status: .completed, values: [
            "latitude": String(location.coordinate.latitude), "longitude": String(location.coordinate.longitude),
            "accuracy_meters": String(location.horizontalAccuracy),
            "timestamp": ISO8601DateFormatter().string(from: location.timestamp)
        ]) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === locationManager, let id = locationRequestID else { return }
        Task { await complete(id, status: .failed, message: error.localizedDescription) }
    }

    func picked(_ item: PhotosPickerItem, request: PhoneRequest) async {
        guard begin(request) else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw DeviceSyncError.underlying(message: "The selected photo could not be read.")
            }
            await finishPhoto(data, request: request)
        } catch { await complete(request.id, status: .failed, message: error.localizedDescription) }
    }

    func openCamera(_ request: PhoneRequest) async -> Bool {
        guard begin(request) else { return false }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            await complete(request.id, status: .failed, message: "This device has no available camera.")
            return false
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard allowed else {
            await complete(request.id, status: .denied, message: "Camera permission is off on this phone.")
            return false
        }
        return active?.id == request.id && request.expiresAt > Date()
    }

    func finishPhoto(_ data: Data, request: PhoneRequest) async {
        do {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1280
                  ] as CFDictionary),
                  let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) else {
                throw DeviceSyncError.underlying(message: "The selected photo could not be read.")
            }
            guard jpeg.count <= 450_000 else {
                throw DeviceSyncError.payloadTooLarge(actualBytes: jpeg.count, maximumBytes: 450_000)
            }
            await complete(request.id, status: .completed, attachments: [MultimodalAttachment(
                type: "image", base64: jpeg.base64EncodedString(), mime: "image/jpeg", name: "phone-photo.jpg", byteSize: jpeg.count)])
        } catch { await complete(request.id, status: .failed, message: error.localizedDescription) }
    }
}

private struct PhoneCamera: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion(info[.originalImage] as? UIImage)
        }
    }
}

struct PhoneRequestSheet: View {
    let request: PhoneRequest
    @ObservedObject var coordinator = PhoneRequestCoordinator.shared
    @State private var photo: PhotosPickerItem?
    @State private var working = false
    @State private var camera = false

    var body: some View {
        VStack(spacing: 24) {
            Text(iCloudSyncEngine.shared.agentDisplayName).font(.title2)
            Text(request.kind == .currentLocation ? "Share your current location?"
                 : request.kind == .capturePhoto ? "Take a photo to share." : "Choose a photo to share.")
            if request.kind == .currentLocation {
                Button("Share location") { working = true; coordinator.locate(request) }.disabled(working)
            } else if request.kind == .capturePhoto {
                Button("Open camera") {
                    working = true
                    Task { camera = await coordinator.openCamera(request) }
                }.disabled(working)
            } else {
                PhotosPicker("Choose photo", selection: $photo, matching: .images).disabled(working)
                    .onChange(of: photo) { _, item in
                        guard let item else { return }
                        working = true
                        Task { await coordinator.picked(item, request: request) }
                    }
            }
            if working { ProgressView() }
            Button("Cancel", role: .cancel) { Task { await coordinator.complete(request.id, status: .cancelled) } }
        }
        .fullScreenCover(isPresented: $camera) {
            PhoneCamera { image in
                camera = false
                Task {
                    guard let image else { await coordinator.complete(request.id, status: .cancelled); return }
                    guard let data = image.jpegData(compressionQuality: 0.9) else {
                        await coordinator.complete(request.id, status: .failed, message: "The captured photo could not be read.")
                        return
                    }
                    await coordinator.finishPhoto(data, request: request)
                }
            }.ignoresSafeArea()
        }
        .padding(32)
        .interactiveDismissDisabled()
    }
}
