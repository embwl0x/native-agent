import AuthoredCapabilities
import CryptoKit
import ChatTurnContracts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Privacy
// Blueprint: | `EngineDocumentRead.swift` | Canonical document and structured page reads with held revision-checked phone continuations |

extension NativeAgentEngine {
    @concurrent public nonisolated func documentPresentation(title: String, text: String, format: String = "plain") async throws
        -> FaceDocumentPresentation {
        let safe = NativeAppSecretRedactor.redactText(text)
        return FaceDocumentPresentation(text: safe, face: try await documentFace(
            title: NativeAppSecretRedactor.redactText(title), text: safe, format: format))
    }
    /// This native packet gives the editable document part no calls or levers to act through.
    @concurrent public nonisolated func documentFace(title: String, text: String, format: String = "plain") async throws -> PartFace {
        guard let file = try AbilityStore(dataRoot: dataRoot).read(id: "native-document"),
              file.record["status"] == .string("active"), let version = file.record["codeFingerprint"]?.stringValue else {
            throw PartCallError(code: "document_part_unavailable", message: "The native-document part has no active selected projection.")
        }
        let packet: JSONValue = .object(["title": .string(title), "format": .string(format),
                                        "read": .object(["opening": .string(String(text.prefix(240))), "bytes": .int(Int64(text.utf8.count))])])
        switch await tools.face(id: "native-document", input: packet, version: version) {
        case .failure(let error): throw error
        case .success(let face):
            guard face.sections.allSatisfy({ section in
                section.allRows.allSatisfy { $0.actions?.isEmpty != false && $0.control == nil && $0.open == nil
                    && $0.expands != true && $0.read == nil }
                    && section.more == nil && section.filter == nil
                    && (section.block == nil || (section.block?.kind == "document" && section.block?.key == "body"
                        && section.block?.text == nil && section.block?.read == nil))
            }), face.detail == nil, face.sections.compactMap(\.block).count == 1 else {
                throw PartCallError(code: "bad_face", message: "A passive document page holds one body document and read-only rows, without calls.")
            }
            return face
        }
    }

    @concurrent public nonisolated func readDocumentPresentation(subject: DocumentSubject) async throws -> FaceDocumentPresentation {
        let request = DocumentRequest(id: UUID(), subject: subject, presentation: true)
        let reply = try await EngineFaceProjection.document(request, engine: self, publish: false)
        guard case .result(let value) = reply else {
            throw PartCallError(code: "document_unconfirmed", message: "The owner did not return its document presentation.")
        }
        return try JSONDecoder().decode(FaceDocumentPresentation.self, from: JSONEncoder().encode(value))
    }

    @concurrent public nonisolated func readDocument(subject: DocumentSubject, expectedCall: PartFace.Call? = nil,
                                                      surface: String? = nil, readUsing: PartFaces.DemandRead? = nil) async throws -> String {
        let request = DocumentRequest(id: UUID(), subject: subject, expectedCall: expectedCall, textOnly: true)
        let reply = try await EngineFaceProjection.document(request, engine: self, surface: surface, publish: false, readUsing: readUsing)
        guard case .result(.string(let text)) = reply else {
            throw PartCallError(code: "document_unconfirmed", message: "The document owner did not return its text.")
        }
        return text
    }

    @concurrent public nonisolated func documentPage(_ request: DocumentRequest, cursor: Int, revision: String?, device: String) async throws
        -> FaceReadPage {
        guard cursor >= 0, (cursor == 0) == (revision == nil) else {
            throw PartCallError(code: "invalid_cursor", message: "A document continuation needs its revision and a nonnegative cursor.")
        }
        let envelope = TurnEnvelope(surface: "ios", agent: "self", verifiedUserId: device, commandSignatureVerified: true,
                                    workIdentity: "faceRead:" + request.id.uuidString)
        let turn = Turn().with(\.envelope, envelope)
        if let read = request.pageRead {
            guard read.id == request.id, case .pageItem(let page, let item) = request.subject, item == read.key else {
                throw PartCallError(code: "invalid_page_read", message: "A page demand uses its own item and request identity.")
            }
            let owner = page == "memories" ? phoneMemoryPages : self.pages
            if request.release == true {
                guard cursor == 0, revision == nil else {
                    throw PartCallError(code: "invalid_page_read", message: "Releasing a page demand takes no continuation.")
                }
                await owner.releaseItem(page: page, item: read.scope, request: read.id)
                return FaceReadPage(id: request.id, cursor: 0, text: "", next: nil, revision: "released")
            }
            let face: PartFace
            if cursor == 0 {
                face = try await owner.presentation(page: page, item: item, request: read, readUsing: { [tools] call in
                    try await tools.pageRead(call, envelope: envelope, turn: turn)
                })
            } else { face = try await owner.heldPresentation(page: page, request: read) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(face)
            guard encoded.count <= 4 * 1024 * 1024 else {
                throw PartCallError(code: "page_read_too_large", message: "The page demand exceeds 4 MiB; its owner must provide a continuation.")
            }
            let current = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
            if let revision, revision != current {
                throw PartCallError(code: "page_read_changed", message: "This held page changed. Open it again to read a complete revision.")
            }
            let text = String(decoding: encoded, as: UTF8.self)
            let scalars = text.unicodeScalars
            guard let start = scalars.index(scalars.startIndex, offsetBy: cursor, limitedBy: scalars.endIndex) else {
                throw PartCallError(code: "invalid_cursor", message: "The page cursor is outside this held revision.")
            }
            let end = scalars.index(start, offsetBy: 4096, limitedBy: scalars.endIndex) ?? scalars.endIndex
            let count = scalars.distance(from: start, to: end)
            let (next, overflow) = cursor.addingReportingOverflow(count)
            guard !overflow else { throw PartCallError(code: "invalid_cursor", message: "The page cursor exceeds this platform's range.") }
            try Task.checkCancellation()
            return FaceReadPage(id: request.id, cursor: cursor, text: String(scalars[start..<end]),
                                next: end == scalars.endIndex ? nil : next, revision: current)
        }
        let text = try await readDocument(subject: request.subject, expectedCall: request.expectedCall, surface: "ios", readUsing: { [tools] call in
            try await tools.pageRead(call, envelope: envelope, turn: turn)
        })
        let current = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if let revision, revision != current {
            throw PartCallError(code: "document_changed", message: "This document changed during the read. Open it again to read its current revision.")
        }
        let scalars = text.unicodeScalars
        guard let start = scalars.index(scalars.startIndex, offsetBy: cursor, limitedBy: scalars.endIndex) else {
            throw PartCallError(code: "invalid_cursor", message: "The document cursor is outside this revision.")
        }
        let end = scalars.index(start, offsetBy: 4096, limitedBy: scalars.endIndex) ?? scalars.endIndex
        let count = scalars.distance(from: start, to: end)
        let (next, overflow) = cursor.addingReportingOverflow(count)
        guard !overflow else { throw PartCallError(code: "invalid_cursor", message: "The document cursor exceeds this platform's range.") }
        try Task.checkCancellation()
        let face: PartFace?
        if cursor == 0 {
            face = try await documentFace(title: "Document", text: text, format: request.subject.documentFormat)
        }
        else { face = nil }
        return FaceReadPage(id: request.id, cursor: cursor, text: String(scalars[start..<end]),
                            next: end == scalars.endIndex ? nil : next, revision: current, face: face)
    }
}
