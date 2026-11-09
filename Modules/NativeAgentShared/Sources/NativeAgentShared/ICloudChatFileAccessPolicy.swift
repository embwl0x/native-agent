import Foundation

// Blueprint: | `ICloudChatFileAccessPolicy.swift` | `ICloudChatFileAccessPolicy.Mode`, `normalized`: invalid modes stay refused |

/// Canonical file-access IDs carried by signed iPhone chat envelopes and admitted by the Mac iCloud chat route. Keeping this at the transport
/// boundary prevents the control pill from advertising a mode the router does not recognize.
public enum ICloudChatFileAccessPolicy {
    public enum Mode: String, CaseIterable, Sendable {
        case auto, readOnly = "read_only", workspace, full, none

        public init?(_ rawValue: String) {
            self.init(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    public static let acceptedIDs = Set(Mode.allCases.map(\.rawValue))

    /// A chain holds every declared restriction. `none` and `read_only` constrain different effects;
    /// neither can stand in for their intersection. Wire controls still use the five Mode IDs.
    public struct Ceiling: Codable, Sendable, Equatable {
        public private(set) var modes: [String]

        public init(_ mode: String? = nil) {
            modes = mode.map { [Mode($0)?.rawValue ?? $0] } ?? []
        }

        private enum CodingKeys: String, CodingKey { case modes }
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let saved = try fields.decode([String].self, forKey: .modes)
            modes = try Array(Set(saved.map { raw in
                guard let mode = Mode(raw) else {
                    throw DecodingError.dataCorruptedError(forKey: .modes, in: fields,
                        debugDescription: "The file-access ceiling contains an unrecognized mode.")
                }
                return mode.rawValue
            })).sorted()
        }

        public var invalidMode: String? { modes.first { Mode($0) == nil } }
        public var readOnly: Bool { modes.contains(Mode.readOnly.rawValue) }
        public var noPathfulReads: Bool { modes.contains(Mode.none.rawValue) }
        public var signatureMaterial: String { modes.map { "\($0.utf8.count):\($0)" }.joined() }
        /// A control's existing scalar label; authority always reads the complete ceiling.
        public var mode: String? {
            if let invalidMode { return invalidMode }
            if noPathfulReads { return Mode.none.rawValue }
            if readOnly { return Mode.readOnly.rawValue }
            return modes.first
        }

        public func intersecting(_ other: Self) -> Self {
            var ceiling = self
            ceiling.modes = Array(Set(modes + other.modes)).sorted()
            return ceiling
        }

        /// Undeclared or invalid authority never permits steering into another turn.
        public func holds(_ other: Self) -> Bool {
            !modes.isEmpty && !other.modes.isEmpty && invalidMode == nil && other.invalidMode == nil
                && (!other.readOnly || readOnly) && (!other.noPathfulReads || noPathfulReads)
        }
    }

    /// Unknown or malformed remote metadata never reaches the chat dispatcher as a permissive access mode.
    public static func normalized(_ rawValue: String) -> String {
        Mode(rawValue)?.rawValue ?? rawValue
    }
}
