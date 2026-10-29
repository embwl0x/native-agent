import Foundation
import Darwin
import NativeAgentShared
import NativeAgentCore
import Speech
import AVFoundation
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Contacts
import OSLog
import PersistenceCore
import Photos
import MacControl
import UserNotifications
// Blueprint: | `MacLocationReader.swift` | One retained CoreLocation manager, cached authorization and bounded fresh-fix requests |

/// One retained manager answers with its held fix and age; only reads with no fix wait for the bounded fresh request.
@MainActor
public final class MacLocationReader: NSObject, @preconcurrency CLLocationManagerDelegate {
    private static let shared = MacLocationReader()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<JSONValue, Never>] = []
    private var deadline: Task<Void, Never>?
    /// The retained manager's authorization is protected by statusLock.
    nonisolated private static let statusLock = NSLock()
    nonisolated(unsafe) private static var knownStatus: CLAuthorizationStatus?
    public nonisolated static var authorizationStatus: CLAuthorizationStatus {
        if let knownStatus = statusLock.withLock({ knownStatus }) { return knownStatus }
        Task { @MainActor in _ = shared }
        return CLLocationManager().authorizationStatus
    }
    /// A held fix this old asks for a fresh one, for the next read.
    private static let freshness: TimeInterval = 300
    /// With no fix held: CoreLocation gives one this fast or not at all (measured 0.6–1.4 s).
    private static let answer: Duration = .seconds(2)

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        Self.statusLock.withLock { Self.knownStatus = manager.authorizationStatus }
    }

    public static func requestAuthorization() {
        if shared.manager.authorizationStatus == .notDetermined {
            shared.manager.requestWhenInUseAuthorization()
        }
    }

    public static func read() async -> JSONValue { await shared.read() }

    /// The newest fix CoreLocation gave this Mac.
    private var held: CLLocation? {
        guard let fix = manager.location, fix.horizontalAccuracy >= 0 else { return nil }
        return fix
    }

    private func read() async -> JSONValue {
        if let held {
            if -held.timestamp.timeIntervalSinceNow >= Self.freshness, deadline == nil { request() }
            return Self.fix(held)
        }
        guard !Task.isCancelled else { return Self.failure("cancelled", "The location read was cancelled.") }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 1 { request() }
        }
    }

    /// Not yet asked: macOS's own prompt asks, and its answer fetches the first fix.
    private func request() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
            deadline?.cancel()
            deadline = Task {
                do { try await Task.sleep(for: Self.answer) } catch { return }
                finish()
            }
        default: finish(Self.failure("location_not_allowed", "NativeAgent needs Location Services. Allow it on the permission card."))
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Self.statusLock.withLock { Self.knownStatus = manager.authorizationStatus }
        // A card waiting on this permission settles on the answer, whoever gave it.
        NotificationCenter.default.post(name: SystemPermissionPreflight.permissionDidChange, object: nil)
    }

    /// The fix just given is the one the manager now holds.
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish() }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(Self.noFix(error.localizedDescription))
    }

    private static func fix(_ location: CLLocation) -> JSONValue {
        // An answer under a grant settles any card still waiting on it.
        NotificationCenter.default.post(name: SystemPermissionPreflight.permissionDidChange, object: nil)
        return .object(["status": .string("ok"), "effects": .string("none"),
            "latitude": .double(location.coordinate.latitude), "longitude": .double(location.coordinate.longitude),
            "accuracy_m": .double(location.horizontalAccuracy),
            "at": .string(NativeTimestampFormat.plainZulu(location.timestamp)),
            "age_seconds": .int(Int64(max(0, -location.timestamp.timeIntervalSinceNow))), "source": .string("this Mac")])
    }

    private static func noFix(_ why: String) -> JSONValue {
        failure("location_unavailable", "This Mac has no location fix: \(why) Try phone.location or give a place.")
    }

    private static func failure(_ reason: String, _ detail: String) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string(reason), "detail": .string(detail), "effects": .string("none"),
                 "remedy": reason == "location_not_allowed" ? SystemPermissionPreflight.remedy("location") ?? .null : .null])
    }

    /// Every waiting read gets the fix the Mac holds, however old, with its age; with none, why not.
    private func finish(_ none: JSONValue = MacLocationReader.noFix("CoreLocation gave none.")) {
        deadline?.cancel()
        deadline = nil
        let result = held.map(Self.fix) ?? none
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume(returning: result) }
    }
}
