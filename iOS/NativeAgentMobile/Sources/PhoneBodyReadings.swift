import AVFAudio
import Dispatch
import Foundation
import MediaPlayer
import MusicKit
import NativeAgentShared
import Network
import Photos
import UIKit

// Blueprint: | `PhoneBodyReadings.swift` | Wake-only battery, audio, network, Music/photo readings; scoped consent and bounded queries |
@MainActor
final class PhoneBodyReadings: NSObject, PHPhotoLibraryChangeObserver {
    private weak var owner: PhoneSenses?
    private var network: NWPathMonitor?
    private var networkQuery: UUID?
    private var networkDeadline: Task<Void, Never>?
    private var photoQuery: UUID?
    private var photoDeadline: Task<Void, Never>?
    private var observingPhotos = false
    private var observingMusic = false
    private var observers: [NSObjectProtocol] = []

    init(owner: PhoneSenses) {
        self.owner = owner
        super.init()
        // Observe only while iOS runs this process; do not acquire background assertions, cadence or location.
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     AVAudioSession.routeChangeNotification, .MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.owner?.wake() }
            })
        }
    }

    func stop() {
        network?.cancel(); network = nil; networkQuery = nil
        networkDeadline?.cancel(); networkDeadline = nil
        photoQuery = nil; photoDeadline?.cancel(); photoDeadline = nil
        if observingPhotos { PHPhotoLibrary.shared().unregisterChangeObserver(self); observingPhotos = false }
        if observingMusic { MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications(); observingMusic = false }
    }

    func requestPermission(for source: PhoneSenseEvent.Source) {
        if source == .music {
            Task { _ = await MusicAuthorization.request(); owner?.wake() }
        } else if source == .photos {
            // Use the async API so a system callback cannot violate MainActor isolation.
            Task { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite); owner?.wake() }
        }
    }

    func setup(for source: PhoneSenseEvent.Source, enabled: Bool) -> PhoneSenseEvent.Setup {
        var required = "no iOS permission", permission = "not required"
        var missing = enabled ? [] : ["turn on \(source.title) in NativeAgent Settings → Phone senses"]
        var detail = "Read only when the app is awake; iOS may delay changes."
        if source == .music {
            required = "Media & Apple Music"
            let status = MusicAuthorization.currentStatus
            permission = switch status {
            case .authorized: "authorized"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not determined"
            @unknown default: "unrecognized iOS status"
            }
            if status != .authorized { missing.append("allow Media & Apple Music in iPhone Settings") }
            detail = "Apple Music only; other apps' playback is not visible. Missing song metadata is not proof of silence."
        } else if source == .photos {
            required = "Photos read access (Limited Access is enough)"
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            permission = switch status {
            case .authorized: "full access"
            case .limited: "limited access"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not determined"
            @unknown default: "unrecognized iOS status"
            }
            if status != .authorized && status != .limited { missing.append("allow Limited Access or Full Access to Photos in iPhone Settings") }
            detail = "Count of visible photos dated today, including synced/imported; Limited Access is a partial count, even when zero."
        } else if source == .headphones {
            detail = "This app's audio output route only; Bluetooth may be a speaker or car. Other route does not prove no headphones connected."
        } else if source == .charging {
            detail = "Phone-local night plus charging; probably asleep requires fresh stationary motion and remains an inference."
        }
        return .init(enabled: enabled, required: required, permission: permission, missing: missing, detail: detail)
    }

    func sample(enabled: Set<PhoneSenseEvent.Source>, pairing: String?) {
        let at = Date()
        if enabled.contains(.battery) {
            let level = UIDevice.current.batteryLevel
            owner?.observed(.battery, value: (0...1).contains(level) ? String(Int((level * 100).rounded())) : "unknown", pairing: pairing, at: at)
        }
        if enabled.contains(.headphones) {
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let value: String
            if outputs.isEmpty { value = "unknown" }
            else if outputs.contains(where: { $0.portType == .headphones }) { value = "headphones_route" }
            else if outputs.contains(where: { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }) { value = "bluetooth_route" }
            else { value = "other_route" }
            owner?.observed(.headphones, value: value, pairing: pairing, at: at)
        }
        if enabled.contains(.music), MusicAuthorization.currentStatus == .authorized {
            let player = MPMusicPlayerController.systemMusicPlayer
            if !observingMusic { player.beginGeneratingPlaybackNotifications(); observingMusic = true }
            let value: String = switch player.playbackState {
            case .playing: "playing"
            case .paused: "paused"
            case .stopped: "stopped"
            case .interrupted: "interrupted"
            case .seekingForward, .seekingBackward: "seeking"
            @unknown default: "unknown"
            }
            let song = player.nowPlayingItem
            let summary = [song?.title, song?.artist].compactMap { $0 }.joined(separator: " — ")
            owner?.observed(.music, value: value, summary: summary.isEmpty ? "song metadata unavailable" : String(summary.prefix(300)), pairing: pairing,
                at: at)
        } else {
            if observingMusic { MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications(); observingMusic = false }
            if enabled.contains(.music) { owner?.observed(.music, value: "unknown", pairing: pairing, at: at) }
        }
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if enabled.contains(.photos), photoStatus == .authorized || photoStatus == .limited {
            if !observingPhotos { PHPhotoLibrary.shared().register(self); observingPhotos = true }
            queryPhotos(pairing: pairing, limited: photoStatus == .limited)
        } else {
            photoQuery = nil; photoDeadline?.cancel(); photoDeadline = nil
            if observingPhotos { PHPhotoLibrary.shared().unregisterChangeObserver(self); observingPhotos = false }
            if enabled.contains(.photos) { owner?.observed(.photos, value: "unknown", pairing: pairing, at: at) }
        }
        if enabled.contains(.network) { queryNetwork(pairing: pairing) }
        else {
            network?.cancel(); network = nil; networkQuery = nil
            networkDeadline?.cancel(); networkDeadline = nil
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // PHChange stays on PhotoKit's queue; only the invalidation crosses.
        Task { @MainActor [weak self] in self?.owner?.wake() }
    }

    private func queryNetwork(pairing: String?) {
        guard networkQuery == nil else { return }
        let query = UUID(), monitor = NWPathMonitor()
        networkQuery = query; network = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let value = path.status != .satisfied ? "unavailable"
                : path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            let at = Date()
            Task { @MainActor in self?.finishNetwork(query, value: value, pairing: pairing, at: at) }
        }
        networkDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.finishNetwork(query, value: "unknown", pairing: pairing, at: Date())
        }
        monitor.start(queue: DispatchQueue(label: "NativeAgent.phone-path"))
    }

    private func finishNetwork(_ query: UUID, value: String, pairing: String?, at: Date) {
        guard networkQuery == query else { return }
        network?.cancel(); network = nil; networkQuery = nil
        networkDeadline?.cancel(); networkDeadline = nil
        owner?.observed(.network, value: value, pairing: pairing, at: at)
    }

    private func queryPhotos(pairing: String?, limited: Bool) {
        guard photoQuery == nil else { return }
        let query = UUID(), at = Date(), calendar = Calendar.current
        let start = calendar.startOfDay(for: at)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: at)
        let zone = calendar.timeZone.identifier
        photoQuery = query
        photoDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.photoQuery == query else { return }
            self.photoQuery = nil; self.photoDeadline = nil
            self.owner?.observed(.photos, value: "unknown", summary: "Photo count did not answer during this wake", pairing: pairing, at: Date())
        }
        Task { [weak self] in
            let count = await Task.detached(priority: .utility) {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                    PHAssetMediaType.image.rawValue, start as NSDate, at as NSDate)
                options.includeHiddenAssets = false
                return PHAsset.fetchAssets(with: options).count
            }.value
            guard let self, self.photoQuery == query else { return }
            self.photoQuery = nil; self.photoDeadline?.cancel(); self.photoDeadline = nil
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard current == .authorized || current == .limited, (current == .limited) == limited else { self.owner?.wake(); return }
            self.owner?.observed(.photos, value: String(count),
                summary: """
                    \(day) (\(zone)); \(limited ? "selected photos only, partial count" : "visible library photos"); dated today, not \
                    necessarily captured here
                    """,
                pairing: pairing, at: at)
        }
    }
}
