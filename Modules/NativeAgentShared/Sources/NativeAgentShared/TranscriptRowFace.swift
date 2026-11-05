import Foundation
// Blueprint: | `TranscriptRowFace.swift` | What the Mac read of one transcript row (where it sits, its tag, its fold line, the agent's words for it), read once on the Mac and carried to the phone with the row |

/// What a row shows, read once by the Mac, which owns the knowledge (bridges, envelopes, provenance, tool outcomes, persona receipts). The Mac's
/// build reads it in process; the phone receives it on the row (`ChatMessageRecord.face`). A row nobody read yet (the phone's own send in
/// flight, its streaming reply) reads `plain`. A face a newer Mac wrote that this build cannot read is left out, and the row reads plainly.
public struct TranscriptRowFace: Codable, Hashable, Sendable, LeftOutWhenUnreadable {
    /// The person's own words sit right; a delegated reply's envelope folds; everything else sits left.
    public enum Seat: String, Codable, Sendable {
        case right, left, envelope

        public init(from decoder: Decoder) throws {
            self = Seat(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .left
        }
    }

    public struct Tag: Codable, Hashable, Sendable {
        public var symbol: String
        public var label: String
        public var automated: Bool
        public init(symbol: String, label: String, automated: Bool) {
            (self.symbol, self.label, self.automated) = (symbol, label, automated)
        }
    }

    public var seat: Seat
    /// The words the row shows when they differ from its content (a bridge prefix stripped, an envelope's reply); nil reads the content.
    public var words: String?
    /// The provenance drawn above a right-seated bubble.
    public var tag: Tag?
    /// A left-seated row's quiet first line (its bridge agent or provenance).
    public var label: String?
    /// Left-seated words in quiet ink (another agent's or a bot's words in this conversation).
    public var quiet: Bool?
    /// A tool row's line when the agent's words for it are not prepared: the tool's title and target.
    public var line: String?
    public var failed: Bool?
    /// A persona write's receipt ("outcome · meta"), drawn open in its run.
    public var receipt: String?
    /// A decision still owed on this row: it draws its approval and never folds.
    public var asks: Bool?
    /// The agent's words for the run this row starts, and for this row's line, when the Mac had them prepared (the phone reads them here).
    public var headline: String?
    public var detail: String?

    public init(seat: Seat, words: String? = nil, tag: Tag? = nil, label: String? = nil, quiet: Bool? = nil, line: String? = nil,
                failed: Bool? = nil, receipt: String? = nil, asks: Bool? = nil, headline: String? = nil, detail: String? = nil) {
        (self.seat, self.words, self.tag, self.label, self.quiet, self.line) = (seat, words, tag, label, quiet, line)
        (self.failed, self.receipt, self.asks, self.headline, self.detail) = (failed, receipt, asks, headline, detail)
    }

    /// A row read without the Mac's knowledge: the person's words right, everything else left, its content as it is.
    public static func plain(_ row: some TranscriptRow) -> Self {
        Self(seat: row.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" ? .right : .left)
    }
}
