import AppKit
import CommandPalette
import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac app behavior evaluations — wave 2")
struct MacAppBehaviorWave2EvalTests {
    private final class WakeResetRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var dispatches = 0
        private var completions = 0

        func reset(_ completion: @escaping @Sendable () -> Void) {
            lock.lock()
            dispatches += 1
            lock.unlock()
            completion()
        }

        func complete() {
            lock.lock()
            completions += 1
            lock.unlock()
        }

        var counts: (dispatches: Int, completions: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (dispatches, completions)
        }
    }

    // User authorized retiring the Spotlight overlay, 2026-09-01. The catalog
    // this asserts on is the ⌘K command palette's, which outlived the panel.
    @Test("every command-palette route resolves to a real destination")
    func commandEntriesResolveToNativeDestinations() {
        let entries = commandPaletteEntries().map {
            CoordinationCommandEntry(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                category: $0.category,
                systemImage: $0.systemImage,
                route: $0.route,
                endpoint: $0.endpoint,
                keywords: $0.keywords,
                status: $0.status,
                count: $0.count
            )
        }
        #expect(entries.count == 14)
        for entry in entries {
            #expect(NativeAgentNavigationDestination.commandEntry(entry) != nil)
        }
        #expect(NativeAgentNavigationDestination.commandEntry(.init(id: "bad", route: "not-a-route")) == nil)
    }

    @Test("hotkey tap, hold, and interleaved presses settle exactly once")
    func globalHotkeyPressStateHasNoStuckVoiceHold() {
        let t0 = Date(timeIntervalSinceReferenceDate: 10)
        var state = GlobalHotkeyPressState()
        let first = state.keyDown(now: t0)
        #expect(state.keyUp(now: t0.addingTimeInterval(0.1)) == .openWindow)
        #expect(!state.isVoiceHoldCurrent)

        let held = state.keyDown(now: t0.addingTimeInterval(1))
        let startedHeldVoice = state.activateVoice(for: held)
        #expect(startedHeldVoice)
        #expect(state.keyUp(now: t0.addingTimeInterval(1.25)) == .endVoice)
        #expect(!state.isVoiceHoldCurrent)

        _ = state.keyDown(now: t0.addingTimeInterval(2))
        let replacement = state.keyDown(now: t0.addingTimeInterval(2.05))
        let staleVoiceStart = state.activateVoice(for: first)
        #expect(!staleVoiceStart)
        let replacementVoiceStart = state.activateVoice(for: replacement)
        #expect(replacementVoiceStart)
        #expect(state.keyUp(now: t0.addingTimeInterval(2.3)) == .endVoice)
        #expect(!state.isVoiceHoldCurrent)
    }

    @Test("wake reset throttle recovers after a backwards wall-clock correction")
    func wakeResetThrottleDoesNotLatchAfterClockCorrection() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let throttle = WakeResetThrottle()
        #expect(throttle.shouldFire(now: t0))
        #expect(!throttle.shouldFire(now: t0.addingTimeInterval(10)))
        #expect(throttle.shouldFire(now: t0.addingTimeInterval(-120)))
        #expect(!throttle.shouldFire(now: t0.addingTimeInterval(-110)))
        #expect(throttle.shouldFire(now: t0.addingTimeInterval(-80)))
    }

    @Test("an accepted wake dispatches one reset effect and completes while an immediate repeat is suppressed")
    func wakeResetRouteDispatchesAndCompletesExactlyOnce() {
        let throttle = WakeResetThrottle()
        let recorder = WakeResetRecorder()

        let accepted = throttle.handleWake(
            resetEffect: recorder.reset,
            resetCompleted: recorder.complete
        )
        let suppressed = throttle.handleWake(
            resetEffect: recorder.reset,
            resetCompleted: recorder.complete
        )

        #expect(accepted)
        #expect(!suppressed)
        #expect(recorder.counts.dispatches == 1)
        #expect(recorder.counts.completions == 1)
    }

    @Test("Grant All stays visible until every real system permission is granted")
    func grantAllRequiresEveryVerifiedStatus() {
        let renderedKeys: Set<String> = [
            "speech_recognition", "microphone", "calendar", "reminders", "contacts",
            "apple_events_mail", "apple_events_messages", "apple_events_notes", "apple_events_music",
        ]
        #expect(MacIntegrationSystemPermissionPresentation.statusKeys.count == 9)
        #expect(Set(MacIntegrationSystemPermissionPresentation.statusKeys) == renderedKeys)
        var statuses = Dictionary(
            uniqueKeysWithValues: MacIntegrationSystemPermissionPresentation.statusKeys.map { ($0, "granted") }
        )
        #expect(MacIntegrationSystemPermissionPresentation.allGranted(statuses))

        for key in MacIntegrationSystemPermissionPresentation.statusKeys {
            statuses.removeValue(forKey: key)
            #expect(!MacIntegrationSystemPermissionPresentation.allGranted(statuses))
            statuses[key] = "granted"
        }
        for rejected in ["unknown", "not_determined", "denied", "restricted", "granted_offline"] {
            statuses[MacIntegrationSystemPermissionPresentation.microphoneKey] = rejected
            #expect(!MacIntegrationSystemPermissionPresentation.allGranted(statuses))
        }
        statuses[MacIntegrationSystemPermissionPresentation.microphoneKey] = "authorized"
        #expect(MacIntegrationSystemPermissionPresentation.allGranted(statuses))
    }

    @Test("AppleEvents cache only round-trips AppleEvents statuses")
    func appleEventCacheCannotPaintFrameworkPermissions() throws {
        let raw: [String: Any] = [
            "apple_events_mail": "granted",
            "apple_events_notes": "denied",
            "calendar": "granted",
            "apple_events_bad": 1,
        ]
        #expect(MacIntegrationSystemPermissionPresentation.cachedAppleEventStatuses(from: raw) == [
            "apple_events_mail": "granted",
            "apple_events_notes": "denied",
        ])
        #expect(MacIntegrationSystemPermissionPresentation.appleEventStatusesForCache([
            "apple_events_music": "unknown", "contacts": "granted",
        ]) == ["apple_events_music": "unknown"])

        let suite = "NativeAgentAppleEventsEval-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        MacIntegrationSystemPermissionPresentation.saveAppleEventStatuses(
            ["apple_events_mail": "denied", "calendar": "granted"],
            to: defaults,
            key: "cache"
        )
        let cached = MacIntegrationSystemPermissionPresentation.loadAppleEventStatuses(from: defaults, key: "cache")
        #expect(cached == ["apple_events_mail": "denied"])
        #expect(MacIntegrationSystemPermissionPresentation.mergingCachedAppleEvents(
            cached,
            withProbed: ["apple_events_mail": "granted"]
        ) == ["apple_events_mail": "granted"])
    }

    @Test("audit reader preserves valid entries and exposes malformed or absent sources")
    func auditReaderDoesNotConvertProblemsIntoAnEmptyLog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentAuditEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = root.appendingPathComponent("mac_control_audit.jsonl")
        try "{\"ts\":\"t\",\"action\":\"screen\",\"allowed\":true}\nnot-json\n"
            .write(to: audit, atomically: true, encoding: .utf8)

        switch MacControlAuditLogRead.read(from: audit) {
        case .entries(let entries, let malformed):
            #expect(entries.count == 1)
            #expect(entries.first?.action == "screen")
            #expect(malformed == 1)
        default:
            Issue.record("valid audit fixture should remain readable")
        }
        #expect({ if case .sourceAbsent = MacControlAuditLogRead.read(from: root.appendingPathComponent("missing.jsonl")) { return true }; return false }())
    }

    @Test("OAuth callback consumes one matching state and refuses mismatches")
    func oauthCallbackRegistryIsSingleUseAndStateBound() throws {
        let state = "wave2-state-\(UUID().uuidString)"
        var deliveries: [URL] = []
        PendingCallbacks.shared.register(state: state) { deliveries.append($0) }
        let matching = try #require(URL(string: "nativeagent://oauth/callback?code=ok&state=\(state)"))
        let mismatched = try #require(URL(string: "nativeagent://oauth/callback?code=bad&state=other"))

        #expect(!NativeOAuthFlow.handleCallbackURL(mismatched))
        #expect(NativeOAuthFlow.handleCallbackURL(matching))
        #expect(deliveries == [matching])
        #expect(!NativeOAuthFlow.handleCallbackURL(matching))
    }

    @Test("System Settings deep links are HTTPS-like system URLs only for known capability anchors")
    func systemPermissionDeepLinksAreCapabilityBound() {
        for capability in SystemPermissionCapability.allCases where capability != .notifications {
            let url = SystemPermissionPreflight.settingsURL(for: capability)
            #expect(url?.absoluteString.hasPrefix(SystemPermissionPreflight.settingsPanePrefix) == true)
            #expect(url?.query?.isEmpty == false)
        }
        #expect(SystemPermissionPreflight.settingsURL(for: .notifications) == nil)
        #expect(SystemPermissionPreflight.settingsURL(for: .accessibility)?.query == "Privacy_Accessibility")
        #expect(SystemPermissionPreflight.settingsURL(for: .automation)?.query == "Privacy_Automation")
        #expect(SystemPermissionPreflight.settingsURL(for: .fullDiskAccess)?.query == "Privacy_AllFiles")
    }

    @Test("screen attachment resizing preserves the image while enforcing the transport edge cap")
    func screenCaptureResizingHasARealDimensionBound() throws {
        let source = try #require(makeImage(width: 10_000, height: 400))
        let resized = NativeScreenCapture.resizedForChat(source)
        #expect(max(resized.width, resized.height) == 1_600)
        #expect(resized.width == 1_600)
        #expect(resized.height > 0)

        let exact = try #require(makeImage(width: 1_600, height: 160))
        let unchanged = NativeScreenCapture.resizedForChat(exact)
        #expect(unchanged.width == 1_600)
        #expect(unchanged.height == 160)

        let encoded = try NativeScreenCapture.encodeForChat(source)
        #expect(encoded.data.count <= 6 * 1024 * 1024)
        do {
            _ = try NativeScreenCapture.fittingEncodedPayload(
                maxBytes: 10,
                jpegData: { _ in Data(repeating: 1, count: 11) },
                pngData: { Data(repeating: 2, count: 11) }
            )
            Issue.record("an unfittable capture must fail rather than return an oversized buffer")
        } catch NativeScreenCapture.CaptureError.tooLarge {
            // Expected: no payload can cross the transport budget.
        }
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
