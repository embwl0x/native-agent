import AppKit
import EngineRuntime
import Foundation
import MacIntegration
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `SettingsDock.swift` | Body-owned permission guidance readings; the window draws and closes the native card |

@MainActor
final class SettingsDock {
    static let shared = SettingsDock()
    private static let capabilities: Set<SystemPermissionCapability> = [.accessibility, .fullDiskAccess, .screenRecording, .inputMonitoring]
    private var target: (id: UUID, capability: SystemPermissionCapability, face: BodyFacePresentation)?
    private let reading = LatestRead()
    private var permissionSnapshot: SystemPermissionSnapshot?
    private var grantedAtOpen: Bool?
    private var opening: Task<Void, Error>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func show(for capability: SystemPermissionCapability, face: BodyFacePresentation) async throws {
        guard Self.capabilities.contains(capability) else { return }
        let previous = opening
        let next = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            try await self.open(capability, face: face)
        }
        opening = next
        defer { if opening == next { opening = nil } }
        try await withTaskCancellationHandler { try await next.value } onCancel: { next.cancel() }
    }

    private func open(_ capability: SystemPermissionCapability, face: BodyFacePresentation) async throws {
        await closeCurrent()
        try Task.checkCancellation()
        let id = UUID()
        target = (id, capability, face)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didBecomeActiveNotification, center: .default)
        observe(SystemPermissionPreflight.permissionDidChange, center: .default)
        observe(NSWorkspace.didActivateApplicationNotification, center: workspace)
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.systempreferences" else { return }
            Task { @MainActor in
                guard let self, self.target?.id == id else { return }
                await self.closeCurrent()
            }
        }
        observers.append((workspace, quit))
        do {
            try await refresh()
            try Task.checkCancellation()
            guard target?.id == id else { throw CancellationError() }
            try await face.present(.showPermissionGuidance(capability: capability.rawValue, bodyBundleURL: Bundle.main.bundleURL.absoluteString))
        } catch {
            if target?.id == id { await closeCurrent() }
            throw error
        }
    }

    func close() async {
        let pending = opening
        pending?.cancel()
        _ = await pending?.result
        await closeCurrent()
    }

    private func closeCurrent() async {
        let previous = target
        target = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        reading.write { grantedAtOpen = nil; permissionSnapshot = nil }
        guard let previous else { return }
        previous.face.model.engine.settingsFeed.updateDock(nil, capability: previous.capability.rawValue)
        guard previous.face.isConnected else { return }
        do { try await previous.face.present(.closePermissionGuidance(capability: previous.capability.rawValue)) }
        catch { previous.face.model.setFailureStatus(error, action: "close permission guidance") }
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                do { try await self?.refresh() }
                catch { self?.target?.face.model.setFailureStatus(error, action: "refresh permission guidance") }
            }
        }
        observers.append((center, token))
    }

    private func refresh() async throws {
        guard let target else { return }
        let capability = target.capability
        _ = await reading.read {
            await Self.snapshot(capability)
        } publish: { snapshot in
            guard self.target?.id == target.id else { return }
            self.permissionSnapshot = snapshot
            if self.grantedAtOpen == nil { self.grantedAtOpen = snapshot.status == .granted }
            target.face.model.engine.settingsFeed.updateDock(Self.line(snapshot), capability: capability.rawValue)
        }
        try Task.checkCancellation()
        try await target.face.model.engine.settingsFeed.deliverFaces()
        guard self.target?.id == target.id else { return }
        if grantedAtOpen == false, permissionSnapshot?.status == .granted { await closeCurrent() }
    }

    @concurrent private static func snapshot(_ capability: SystemPermissionCapability) async -> SystemPermissionSnapshot {
        SystemPermissionPreflight.snapshot(capability)
    }

    private static func line(_ snapshot: SystemPermissionSnapshot) -> PermissionSettingsFace.Dock {
        if snapshot.status == .unknown || snapshot.status == .restricted {
            return .init(line: SystemPermissionPreflight.warningSummary(for: snapshot), highlight: nil)
        }
        let capability = snapshot.capability
        let name = capability.displayName
        if snapshot.status == .granted {
            return .init(line: "NativeAgent is already on in \(name). If it is missing from the list, drag this icon in.", highlight: nil)
        }
        let words = capability == .fullDiskAccess
            ? "Drag this icon into the \(name) list, then turn it on."
            : "Turn NativeAgent on in \(name). If it is not listed, drag this icon into the list."
        return .init(line: words, highlight: name)
    }
}
