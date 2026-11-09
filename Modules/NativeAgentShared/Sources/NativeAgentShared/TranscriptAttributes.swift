import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Blueprint: | `TranscriptAttributes.swift` | Codable transcript attributes preserved by the press and TextKit's native bridge |

public enum TranscriptKey {
    public static let blockID = NSAttributedString.Key("transcript.blockID")
    public static let kind = NSAttributedString.Key("transcript.kind")
    public static let topGap = NSAttributedString.Key("transcript.topGap")
    public static let foldOpens = NSAttributedString.Key("transcript.foldOpens")
    public static let foldGroup = NSAttributedString.Key("transcript.foldGroup")
    public static let tagSymbol = NSAttributedString.Key("transcript.tagSymbol")
    public static let tagLabel = NSAttributedString.Key("transcript.tagLabel")
    public static let tagAutomated = NSAttributedString.Key("transcript.tagAutomated")
    public static let language = NSAttributedString.Key("transcript.language")
    public static let languageFontSize = NSAttributedString.Key("transcript.languageFontSize")
    public static let liveHidden = NSAttributedString.Key("transcript.liveHidden")
}

public struct TranscriptAttributes: AttributeScope {
#if os(macOS)
    public let appKit: AttributeScopes.AppKitAttributes
#elseif os(iOS)
    public let uiKit: AttributeScopes.UIKitAttributes
#else
    public let foundation: AttributeScopes.FoundationAttributes
#endif
    public let blockID: BlockID
    public let kind: Kind
    public let topGap: TopGap
    public let foldOpens: FoldOpens
    public let foldGroup: FoldGroup
    public let tagSymbol: TagSymbol
    public let tagLabel: TagLabel
    public let tagAutomated: TagAutomated
    public let language: Language
    public let languageFontSize: LanguageFontSize
    public let liveHidden: LiveHidden

    public enum LiveHidden: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Bool
        public typealias ObjectiveCValue = NSNumber
        public static let name = "transcript.liveHidden"
        public static func objectiveCValue(for value: Bool) -> NSNumber { NSNumber(value: value) }
        public static func value(for object: NSNumber) -> Bool { object.boolValue }
    }

    public enum LanguageFontSize: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Double
        public typealias ObjectiveCValue = NSNumber
        public static let name = "transcript.languageFontSize"
        public static func objectiveCValue(for value: Double) -> NSNumber { NSNumber(value: value) }
        public static func value(for object: NSNumber) -> Double { object.doubleValue }
    }

    public enum BlockID: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.blockID"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }

    public enum Kind: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.kind"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }

    public enum TopGap: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Double
        public typealias ObjectiveCValue = NSNumber
        public static let name = "transcript.topGap"
        public static func objectiveCValue(for value: Double) -> ObjectiveCValue { NSNumber(value: value) }
        public static func value(for object: ObjectiveCValue) -> Double { object.doubleValue }
    }

    public enum FoldOpens: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.foldOpens"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }

    public enum FoldGroup: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.foldGroup"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }

    public enum TagSymbol: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.tagSymbol"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }

    public enum TagLabel: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.tagLabel"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }

    public enum TagAutomated: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Bool
        public typealias ObjectiveCValue = NSNumber
        public static let name = "transcript.tagAutomated"
        public static func objectiveCValue(for value: Bool) -> ObjectiveCValue { NSNumber(value: value) }
        public static func value(for object: ObjectiveCValue) -> Bool { object.boolValue }
    }

    public enum Language: CodableAttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = String
        public typealias ObjectiveCValue = NSString
        public static let name = "transcript.language"
        public static func objectiveCValue(for value: String) -> ObjectiveCValue { value as NSString }
        public static func value(for object: ObjectiveCValue) -> String { object as String }
    }
}
