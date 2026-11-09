import AppKit
import AppToolRuntime
import Carbon.HIToolbox
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
// Blueprint: | `Shotgun.swift` | Body-owned global Shotgun shortcut and actual motor-event forwarding to the only window |

enum ShotgunShortcut: String, CaseIterable, Identifiable {
    case optionSpace = "option-space"
    case controlOptionSpace = "control-option-space"
    case shiftCommandSpace = "shift-command-space"
    case off

    static let storageKey = "NativeAgent.shotgun.shortcut"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .shiftCommandSpace: "⇧⌘Space"
        case .off: "Off"
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .shiftCommandSpace: UInt32(shiftKey | cmdKey)
        case .off: nil
        }
    }

    static var current: ShotgunShortcut? {
        guard let saved = UserDefaults.standard.object(forKey: storageKey) else { return .optionSpace }
        guard let raw = saved as? String else { return nil }
        return Self(rawValue: raw)
    }
}

@MainActor
@Observable
final class ShotgunController {
    static let shared = ShotgunController()
    static let enabledKey = ShotgunPreference.enabledKey
    private(set) var shortcutTaken: ShotgunShortcut?
    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var toldTaken: Set<ShotgunShortcut> = []

    private init() {}

    func attach(appModel: AppModel) {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        applyShortcut()
        Task { await Self.observeMotor() }
    }

    /// With no window process yet, the person's press opens the window.
    func toggle() {
        guard let acts = appModel?.engine.faceActs else { return }
        Task {
            if await acts.hasRenderer { forward(.toggleShotgun) }
            else { ApplicationLifetime.shared.request(.sidebar(.chat)) }
        }
    }

    private func forward(_ call: FaceCall) {
        guard let appModel else { return }
        Task {
            do {
                switch try await appModel.engine.faceActs.call(call) {
                case .acknowledged: break
                case .failed(let failure), .refused(let failure): throw failure
                case .cancelled: throw CancellationError()
                default: throw FaceWireError.invalidFeedOrder
                }
            } catch is CancellationError {
            } catch {
                appModel.setFailureStatus(error, action: "forward Shotgun to the window")
                NativeAgentNotifications.post(title: "Shotgun did not open", body: error.localizedDescription, deadline: nil)
            }
        }
    }

    @concurrent private static func observeMotor() async {
        PersonOnlyWindows.observeAgent(motor: {
            Task { @MainActor in ShotgunController.shared.handsMoved() }
        })
    }

    /// With no window open there is nothing to step aside: her hands never raise a notice about it.
    private func handsMoved() {
        guard let acts = appModel?.engine.faceActs else { return }
        Task { if await acts.hasRenderer { forward(.agentHandsMoved(driver: nil)) } }
    }

    /// Share shortcut persistence and registration so settings and agent actions cannot disagree.
    func setShortcut(_ shortcut: ShotgunShortcut) throws {
        if UserDefaults.standard.object(forKey: ShotgunShortcut.storageKey) as? String != shortcut.rawValue {
            UserDefaults.standard.set(shortcut.rawValue, forKey: ShotgunShortcut.storageKey)
        }
        applyShortcut()
        if shortcutTaken != nil {
            throw QuietSettingError.unavailable("""
                Saved \(shortcut.title), but macOS could not register it. Choose another Shotgun shortcut in Settings; View → Show \
                Shotgun remains available.
                """)
        }
    }

    /// Report shortcut conflicts while preserving the working View menu action.
    func applyShortcut() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        shortcutTaken = nil
        if hotKeyHandler == nil {
            var pressed = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ -> OSStatus in
                    guard let event, let id = hotKeyID(of: event),
                          id.signature == fourCharCode("NASG"), id.id == 2
                    else { return OSStatus(eventNotHandledErr) }
                    Task { @MainActor in ShotgunController.shared.toggle() }
                    return noErr
                },
                1,
                &pressed,
                nil,
                &hotKeyHandler
            )
        }
        guard let shortcut = ShotgunShortcut.current else { return }
        guard let modifiers = shortcut.carbonModifiers else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), modifiers, EventHotKeyID(signature: fourCharCode("NASG"), id: 2),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            shortcutTaken = shortcut
            ModuleLog.app("[Shotgun] %@ could not be registered: %d", shortcut.title, status)
            if toldTaken.insert(shortcut).inserted {
                NativeAgentNotifications.post(
                    title: "\(shortcut.title) is taken",
                    body: "Another app already uses \(shortcut.title), so it can't show Shotgun. Pick another in Settings, or use View ▸ Show Shotgun.",
                    deadline: nil
                )
            }
            return
        }
        hotKeyRef = ref
    }

}
