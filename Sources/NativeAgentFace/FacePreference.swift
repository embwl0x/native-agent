import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `FacePreference.swift` | Preference leaf selections and explicit read availability; person edits reach the settings owner |

protocol FacePreferenceScalar: Equatable, Sendable {
    static func read(_ value: PartFace.Value) -> Self?
    var faceValue: PartFace.Value { get }
}

extension Bool: FacePreferenceScalar {
    static func read(_ value: PartFace.Value) -> Bool? { if case .bool(let value) = value { value } else { nil } }
    var faceValue: PartFace.Value { .bool(self) }
}
extension String: FacePreferenceScalar {
    static func read(_ value: PartFace.Value) -> String? { if case .string(let value) = value { value } else { nil } }
    var faceValue: PartFace.Value { .string(self) }
}
extension Double: FacePreferenceScalar {
    /// A whole number crosses the link as an int, whichever way it was written.
    static func read(_ value: PartFace.Value) -> Double? {
        switch value {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }
    var faceValue: PartFace.Value { .double(self) }
}

@propertyWrapper
@MainActor
struct FacePreference<Value: FacePreferenceScalar>: DynamicProperty {
    @Environment(AppModel.self) private var appModel
    private let key: String
    private let declaredDefault: Value
    init(wrappedValue: Value, _ key: String) { declaredDefault = wrappedValue; self.key = key }

    var wrappedValue: Value {
        get {
            appModel.face.slot(.settings).select("preference.value:\(key)", as: SettingsFace.self) {
                $0?.preferences[key].flatMap(Value.read)
            } ?? declaredDefault
        }
        nonmutating set {
            appModel.setFacePreference(newValue.faceValue, for: key)
        }
    }
    var projectedValue: Binding<Value> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
}

private struct FacePreferenceAvailability: Equatable {
    let isReady: Bool
    let hasValues: Bool
    let issues: [String: String]
}

/// A control group draws no inferred settings while the owner reads or reports an invalid value.
struct FacePreferences<Content: View>: View {
    @Environment(AppModel.self) private var appModel
    let keys: [String]
    private let content: () -> Content

    init(keys: [String], @ViewBuilder content: @escaping () -> Content) {
        self.keys = keys
        self.content = content
    }
    var body: some View {
        let status = appModel.face.slot(.settings).select("preference.availability:" + keys.sorted().joined(separator: ","), as: SettingsFace.self) { value in
            FacePreferenceAvailability(isReady: value?.hasReadPreferences == true,
                                       hasValues: keys.allSatisfy { key in value?.preferences[key] != nil },
                                       issues: value?.preferenceIssues.filter { keys.contains($0.key) } ?? [:])
        }
        if !status.isReady {
            Text("Reading preferences…").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
        } else if !status.hasValues || !status.issues.isEmpty {
            VStack(alignment: .leading) {
                ForEach(status.issues.keys.sorted(), id: \.self) { key in
                    Text(status.issues[key] ?? "").font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
                    Button("Use default") {
                        appModel.setFacePreference(.null, for: key)
                    }
                }
            }
        } else {
            content()
        }
    }
}
