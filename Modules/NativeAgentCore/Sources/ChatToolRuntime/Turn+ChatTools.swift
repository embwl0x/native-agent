import Foundation
import NativeAgentCore
import Studio
// Blueprint: | `Turn+ChatTools.swift` | `Turn` holds approved model override, image-generation admission and Make evidence |

private enum ModelOverridePart: TurnPart { static let unset: InlineInteractionModelOverride.Binding? = nil }
private enum ImageGenerationFullMacPart: TurnPart { static let unset: Bool = false }
private enum MakeRegistrationPart: TurnPart { static let unset: MakeRegistration? = nil }

extension Turn {
    /// Only the native generation receipt supplies paths for this registration's nested make.add call.
    public var makeRegistration: MakeRegistration? {
        get { self[MakeRegistrationPart.self] }
        set { self[MakeRegistrationPart.self] = newValue }
    }
    /// The person-approved model/provider override for a resumed request.
    public var modelOverride: InlineInteractionModelOverride.Binding? {
        get { self[ModelOverridePart.self] }
        set { self[ModelOverridePart.self] = newValue }
    }
    /// Full Mac admitted for this explicit image-generation act.
    var imageGenerationFullMac: Bool {
        get { self[ImageGenerationFullMacPart.self] }
        set { self[ImageGenerationFullMacPart.self] = newValue }
    }
}
