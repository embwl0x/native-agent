import Foundation
import NativeAgentShared
import CoreLocation
import PersistenceCore
import MacControl
// Blueprint: | `MacLocationReader.swift` | Held location fixes with age; fresh requests settle on CoreLocation callbacks or caller cancellation |

/// The manager owns held fixes; reads without one await its request result.
@MainActor
public final class MacLocationReader: NSObject, @preconcurrency CLLocationManagerDelegate {
    private static let shared = MacLocationReader()
    private let manager = CLLocationManager()
    private var waiters: [UUID: ScopedWaiter] = [:]
    private var results: [UUID: JSONValue] = [:]
    private var requesting = false
    public nonisolated static var authorizationStatus: CLAuthorizationStatus {
        return CLLocationManager().authorizationStatus
    }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public static func requestAuthorization() {
        if shared.manager.authorizationStatus == .notDetermined {
            shared.manager.requestWhenInUseAuthorization()
        }
    }

    public static func read(context: MacOperationContext) async throws -> JSONValue { try await shared.read(context: context) }

    private var held: CLLocation? {
        guard let fix = manager.location, fix.horizontalAccuracy >= 0 else { return nil }
        return fix
    }

    private func read(context: MacOperationContext) async throws -> JSONValue {
        guard !Task.isCancelled, !context.expired else { throw context.cancellationError }
        if let held {
            if !requesting { request() }
            return Self.fix(held)
        }
        let id = UUID(), done = ScopedWaiter()
        waiters[id] = done
        defer {
            waiters.removeValue(forKey: id)
            results.removeValue(forKey: id)
        }
        if !requesting { request() }
        await done.park(budget: context.waitBudget)
        guard !Task.isCancelled, !context.expired else { throw context.cancellationError }
        guard let result = results[id] else { throw CancellationError() }
        return result
    }

    private func request() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requesting = true
            manager.requestLocation()
        default: finish(Self.failure("location_not_allowed", "NativeAgent needs Location Services. Allow it on the permission card."))
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NotificationCenter.default.post(name: SystemPermissionPreflight.permissionDidChange, object: nil)
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish(Self.failure("location_not_allowed", "Location Services access was refused by macOS. Allow it on the permission card."))
        default: break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.filter({ $0.horizontalAccuracy >= 0 }).max(by: { $0.timestamp < $1.timestamp }) else {
            finish(.object(["status": .string("unknown"), "reason": .string("location_unconfirmed"), "effects": .string("none"),
                "detail": .string("CoreLocation answered without a valid location fix.")]))
            return
        }
        finish(Self.fix(fix))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(Self.noFix(error.localizedDescription))
    }

    private static func fix(_ location: CLLocation) -> JSONValue {
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

    private func finish(_ result: JSONValue) {
        requesting = false
        let waiting = waiters
        waiters = [:]
        for (id, done) in waiting {
            results[id] = result
            done.resume()
        }
    }
}
