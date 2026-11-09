import Foundation
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+FaceReads.swift` | Signed document and structured page demands, revision-checked cursors and owner release |

extension iCloudSyncEngine {
    func releaseFaceRead(page: String, request: FaceReadRequest) async throws {
        let document = DocumentRequest(id: request.id, subject: .pageItem(page: page, item: request.key), pageRead: request, release: true)
        let rawRequest = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let result = try requireSuccessfulActionResponse(await sendActionAndWait(.make(action: "faceRead", payload: [
            "request": rawRequest, "cursor": "0"
        ])))
        guard let raw = result["page"] else { throw SyncError.persistence("The Mac did not acknowledge releasing this page demand.") }
        let response = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(FaceReadPage.self, from: Data(raw.utf8))
        }.value
        guard response.id == request.id, response.revision == "released" else {
            throw SyncError.persistence("The Mac release reply does not name this page demand.")
        }
    }

    func faceReadFace(page: String, request: FaceReadRequest) async throws -> PartFace {
        let lifecycle = lifecycleGeneration
        let document = DocumentRequest(id: request.id, subject: .pageItem(page: page, item: request.key), pageRead: request)
        let rawRequest = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        var cursor = 0
        var revision: String?
        var chunks: [String] = []
        while true {
            try Task.checkCancellation()
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            var payload = ["request": rawRequest, "cursor": String(cursor)]
            payload["revision"] = revision
            let result = try requireSuccessfulActionResponse(await sendActionAndWait(.make(action: "faceRead", payload: payload)))
            guard let raw = result["page"] else { throw SyncError.persistence("The Mac did not return the requested page demand.") }
            let response = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(FaceReadPage.self, from: Data(raw.utf8))
            }.value
            try Task.checkCancellation()
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            guard response.id == request.id, response.cursor == cursor, revision == nil || revision == response.revision else {
                throw SyncError.persistence("The Mac page reply does not match this demand's identity and revision.")
            }
            chunks.append(response.text)
            if let next = response.next {
                guard next > cursor, !response.text.isEmpty else { throw SyncError.persistence("The Mac page cursor did not advance.") }
                cursor = next
                revision = response.revision
            } else {
                let collected = chunks
                return try await Task.detached(priority: .userInitiated) {
                    try JSONDecoder().decode(PartFace.self, from: Data(collected.joined().utf8))
                }.value
            }
        }
    }

    func faceRead(_ request: DocumentRequest) async throws -> String {
        try await faceReadPresentation(request).text
    }

    func faceReadPresentation(_ request: DocumentRequest) async throws -> FaceDocumentPresentation {
        let lifecycle = lifecycleGeneration
        let rawRequest = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        var cursor = 0
        var revision: String?
        var chunks: [String] = []
        var face: PartFace?
        while true {
            try Task.checkCancellation()
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            var payload = ["request": rawRequest, "cursor": String(cursor)]
            payload["revision"] = revision
            let result = try requireSuccessfulActionResponse(await sendActionAndWait(.make(action: "faceRead", payload: payload)))
            guard let raw = result["page"] else { throw SyncError.persistence("The Mac did not return the requested document page.") }
            let page = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(FaceReadPage.self, from: Data(raw.utf8))
            }.value
            try Task.checkCancellation()
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            guard page.id == request.id, page.cursor == cursor, revision == nil || revision == page.revision else {
                throw SyncError.persistence("The Mac document reply does not match this read and revision.")
            }
            chunks.append(page.text)
            if cursor == 0 {
                guard let projection = page.face else { throw SyncError.persistence("The Mac did not return this document's page.") }
                face = projection
            }
            guard let next = page.next else {
                guard let face else { throw SyncError.persistence("The document has no page presentation.") }
                return FaceDocumentPresentation(text: chunks.joined(), face: face)
            }
            guard next > cursor, !page.text.isEmpty else { throw SyncError.persistence("The Mac document cursor did not advance.") }
            cursor = next
            revision = page.revision
        }
    }
}
