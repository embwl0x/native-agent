import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `FacePreference.swift` | Typed settings preference values read by body-owned settings helpers |

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
    static func read(_ value: PartFace.Value) -> Double? { if case .double(let value) = value { value } else { nil } }
    var faceValue: PartFace.Value { .double(self) }
}
