import AppKit
import CoreFoundation
import AppToolRuntime
import ChatSessionWork
import EngineRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Cognition
import Observation
import PersistenceCore
// Blueprint: | `BodySettingsPreferences.swift` | Body dispatcher preference projection and declaration reads |

@MainActor
enum BodySettingsPreferences {
    private static var preferenceKeys: Set<String> = []
    private static let preferenceRead = LatestRead()
    private static var publishedPreferences: PreferenceReading?

    static var declaredPreferences: [String: PartFace.Value] {
        [SimpleViewMode.key: .string(SimpleViewMode.simple), HazeColor.key: .string(HazeColor.defaultValue.rawValue),
         AppearanceController.preferenceKey: .bool(true),
         WorkPaneState.openKey: .bool(false), WorkPaneState.sidebarsHiddenKey: .bool(false),
         WorkPaneState.widthKey: .double(WorkPane.defaultWidth), "voiceAutoRead": .bool(false),
         "nativeagent.showTour": .bool(false), ShotgunController.enabledKey: .bool(true),
         ShotgunShortcut.storageKey: .string(ShotgunShortcut.optionSpace.rawValue), MoodTintPreference.key: .bool(true),
         "studioWanderEnabled": .bool(true), "cognitiveSubstrateEnabled": .bool(true), "chatFileAccess": .string("auto")]
    }

    @discardableResult
    static func refreshPreferences(engine: NativeAgentEngine, keys: [String] = []) async throws -> [String: PartFace.Value] {
        preferenceKeys.formUnion(keys)
        let declared = declaredPreferences
        let keys = preferenceKeys.union(declared.keys)
        let feed = engine.settingsFeed
        let reading = await preferenceRead.read({ await readPreferences(keys, declared: declared) }, publish: { reading in
            guard reading != publishedPreferences else { return }
            publishedPreferences = reading
            feed.updatePreferences(reading.values, issues: reading.issues, declared: declared)
            NotificationCenter.default.post(name: SettingsFaceChange.platform, object: nil)
        })
        try await feed.deliverFaces()
        return reading.values
    }

    private struct PreferenceReading: Equatable, Sendable {
        var values: [String: PartFace.Value] = [:]
        var issues: [String: String] = [:]
    }

    @concurrent private static func readPreferences(_ keys: Set<String>, declared: [String: PartFace.Value]) async -> PreferenceReading {
        var reading = PreferenceReading()
        for key in keys {
            guard let saved = UserDefaults.standard.object(forKey: key) else {
                reading.values[key] = declared[key]
                continue
            }
            let value: PartFace.Value?
            if let number = saved as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { value = .bool(number.boolValue) }
                else { value = .double(number.doubleValue) }
            } else if let text = saved as? String { value = .string(text) }
            else { value = nil }
            let expected = declared[key]
            let valid: Bool
            switch (expected, value) {
            case (.some(.bool), .some(.bool)), (.some(.string), .some(.string)), (.some(.double), .some(.double)), (nil, .some): valid = true
            default: valid = false
            }
            if valid, let value {
                if key == SimpleViewMode.key, case .string(let mode) = value, !SimpleViewMode.choices.contains(mode) {
                    reading.issues[key] = "The saved view is unavailable. Choose Simple, Advanced or Agent explicitly."
                    reading.values[key] = value
                } else if key == HazeColor.key, case .string(let color) = value,
                          !HazeColor.allCases.contains(where: { $0.rawValue == color }) {
                    reading.issues[key] = "The saved glass color is unsupported. Choose a glass color explicitly in Settings."
                } else if case .double(let number) = value, !number.isFinite {
                    reading.issues[key] = "The saved preference \(key) is not a finite number. Set it explicitly in Settings."
                } else {
                    reading.values[key] = value
                }
            } else {
                reading.issues[key] = "The saved preference \(key) has an unsupported value. Set it explicitly in Settings."
            }
        }
        return reading
    }

}
