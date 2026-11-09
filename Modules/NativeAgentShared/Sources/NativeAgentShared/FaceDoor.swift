import Foundation
// Blueprint: | `FaceDoor.swift` | Drawn acts, held document reads and navigation shared by native page doors |

public struct FaceActSubmission: Sendable {
    public let id: UUID
    public let row: String
    public let action: String
    public let value: String?
    public let values: [String: PartFace.Value]?
    public let formRevision: String?
    public let expectedCall: PartFace.Call
    public let undoOf: UUID?
    public let checking: Bool
    public init(id: UUID, row: String, action: String, value: String?, expectedCall: PartFace.Call, undoOf: UUID? = nil,
                checking: Bool = false, values: [String: PartFace.Value]? = nil, formRevision: String? = nil) {
        self.id = id; self.row = row; self.action = action; self.value = value; self.expectedCall = expectedCall
        self.undoOf = undoOf
        self.checking = checking
        self.values = values; self.formRevision = formRevision
    }
}

/// A terminal reply can leave effects unresolved. Only an owner can supply readback or an inverse call.
public struct FaceActOutcome: Codable, Sendable, Equatable {
    public var words: String?
    public var failure: WireFailure?
    public var effects: FaceEffects
    /// On a current-state check, true means that read established the original operation's settlement.
    public var accepted: Bool
    public var committed: [FaceCommittedField]?
    public var undo: PartFace.Call?
    public init(words: String? = nil, failure: WireFailure? = nil, effects: FaceEffects, accepted: Bool = false,
                committed: [FaceCommittedField]? = nil, undo: PartFace.Call? = nil) {
        self.words = words; self.failure = failure; self.effects = effects; self.committed = committed; self.undo = undo
        self.accepted = accepted
    }
    public var unresolved: Bool { effects == .unknown || failure?.effects == .unknown || (failure == nil && !accepted) }

    public static func interrupted(_ error: any Error) -> Self {
        let failure: WireFailure
        if let known = error as? WireFailure { failure = known }
        else {
            failure = WireFailure(code: "page_reply_unconfirmed", message: "The page action's reply is unavailable.",
                                  cause: error.localizedDescription, effects: .unknown)
        }
        return Self(failure: failure, effects: failure.effects, committed: failure.committed)
    }

    public func wireValue() throws -> PartFace.Value { try JSONDecoder().decode(PartFace.Value.self, from: JSONEncoder().encode(self)) }
    public static func reply(_ reply: FaceActReply) throws -> Self {
        switch reply {
        case .result(let value): return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        case .failed(let failure), .refused(let failure): return .interrupted(failure)
        default:
            throw WireFailure(code: "page_reply_unconfirmed", message: "The owner did not return this page action's outcome.",
                              cause: nil, effects: .unknown)
        }
    }
}

public struct FaceCommittedField: Codable, Sendable, Equatable {
    public let id: String
    public let value: PartFace.Value?
    public init(id: String, value: PartFace.Value? = nil) { self.id = id; self.value = value }
}

/// Optional page-specific metadata in an action owner's `pageSettlement` result member.
public struct FaceActSettlement: Codable, Sendable {
    public let committed: [FaceCommittedField]?
    public let undo: PartFace.Call?
    public init(committed: [FaceCommittedField]? = nil, undo: PartFace.Call? = nil) { self.committed = committed; self.undo = undo }
}

/// The presentation asks its owner to act or navigate; drawing owns neither effect.
@MainActor public protocol FaceDoor: Sendable {
    var answersOnRow: Bool { get }
    var cancellationLabel: String { get }
    var waitingOn: String { get }
    func open(_ link: String)
    func act(_ submission: FaceActSubmission) async -> FaceActOutcome
    func read(_ request: FaceReadRequest) async throws -> String
    func readFace(_ request: FaceReadRequest) async throws -> PartFace
    func releaseFace(_ request: FaceReadRequest) async
    func scoped(to item: String) -> any FaceDoor
}

extension FaceDoor {
    public func scoped(to item: String) -> any FaceDoor { self }
    public func releaseFace(_ request: FaceReadRequest) async {}
    public func readFace(_ request: FaceReadRequest) async throws -> PartFace {
        throw PartCallError(code: "page_read_unavailable", message: "This door has no collection or item reader.")
    }
}

public struct ReadOnlyFaceDoor: FaceDoor {
    private let opening: (String) -> Void
    public let answersOnRow = true
    public let cancellationLabel = "Cancel"
    public let waitingOn = "the page"
    public init(open: @escaping (String) -> Void = { _ in }) { opening = open }
    public func open(_ link: String) { opening(link) }
    public func act(_ submission: FaceActSubmission) async -> FaceActOutcome {
        .interrupted(WireFailure(code: "read_only_page", message: "This readout has no command owner.", cause: nil, effects: .none))
    }
    public func read(_ request: FaceReadRequest) async throws -> String {
        throw PartCallError(code: "read_unavailable", message: "This readout has no document reader.")
    }
}

public struct ClosureFaceDoor: FaceDoor {
    public let answersOnRow: Bool
    public let cancellationLabel: String
    public let waitingOn: String
    private let opening: (String) -> Void
    private let acting: (FaceActSubmission) async -> FaceActOutcome
    private let reading: (FaceReadRequest) async throws -> String
    private let pageReading: (FaceReadRequest) async throws -> PartFace
    private let pageReleasing: (FaceReadRequest) async -> Void
    private let scoping: ((String) -> any FaceDoor)?

    public init(open: @escaping (String) -> Void, cancellationLabel: String = "Cancel", waitingOn: String = "the document",
                read: @escaping (FaceReadRequest) async throws -> String = { _ in
                    throw PartCallError(code: "read_unavailable", message: "This door has no document reader.")
                },
                pageRead: @escaping (FaceReadRequest) async throws -> PartFace = { _ in
                    throw PartCallError(code: "page_read_unavailable", message: "This door has no collection or item reader.")
                }, releaseFace: @escaping (FaceReadRequest) async -> Void = { _ in },
                scope: ((String) -> any FaceDoor)? = nil,
                perform: @escaping (FaceActSubmission) async -> FaceActOutcome) {
        opening = open
        acting = perform
        answersOnRow = true
        self.cancellationLabel = cancellationLabel
        self.waitingOn = waitingOn
        reading = read
        pageReading = pageRead
        pageReleasing = releaseFace
        scoping = scope
    }

    public init(open: @escaping (String) -> Void, act: @escaping (String, String, String?) async -> Void) {
        opening = open
        answersOnRow = false
        cancellationLabel = "Cancel waiting"
        waitingOn = "the document"
        reading = { _ in throw PartCallError(code: "read_unavailable", message: "This door has no document reader.") }
        pageReading = { _ in throw PartCallError(code: "page_read_unavailable", message: "This door has no collection or item reader.") }
        pageReleasing = { _ in }
        scoping = nil
        acting = { submission in
            guard submission.values == nil else {
                return .interrupted(WireFailure(code: "form_door_unavailable", message: "This page needs an answering form door.",
                                                cause: nil, effects: .none))
            }
            await act(submission.row, submission.action, submission.value)
            return FaceActOutcome(effects: .unknown)
        }
    }

    public func open(_ link: String) { opening(link) }
    public func act(_ submission: FaceActSubmission) async -> FaceActOutcome { await acting(submission) }
    public func read(_ request: FaceReadRequest) async throws -> String { try await reading(request) }
    public func readFace(_ request: FaceReadRequest) async throws -> PartFace { try await pageReading(request) }
    public func releaseFace(_ request: FaceReadRequest) async { await pageReleasing(request) }
    public func scoped(to item: String) -> any FaceDoor { scoping?(item) ?? self }
}
public struct FaceReadRequest: Codable, Sendable, Equatable {
    /// Every held answer, child door and release names one read lifetime, even across doors reading the same item.
    public var scope: String {
        key + "/request:" + id.uuidString + (cursor.map { "/cursor:" + String($0.utf8.count) + ":" + $0 } ?? "")
    }
    public let id: UUID
    public let key: String
    public let expectedCall: PartFace.Call?
    public let revision: String?
    public let cursor: String?
    public let anchor: String?
    public let query: String?
    public init(id: UUID, key: String, expectedCall: PartFace.Call?, revision: String? = nil,
                cursor: String? = nil, anchor: String? = nil, query: String? = nil) {
        self.id = id; self.key = key; self.expectedCall = expectedCall; self.revision = revision
        self.cursor = cursor; self.anchor = anchor; self.query = query
    }
}
