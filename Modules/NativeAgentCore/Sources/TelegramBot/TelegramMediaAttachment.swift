import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `TelegramMediaAttachment.swift` | `TelegramMediaDownloader`: two-stage file metadata/download admission with declared-size and actual-byte bounds |

// MARK: - TelegramMediaAttachment

/// A Telegram media attachment (photo, voice, video, document, …).
public struct TelegramMediaAttachment: Sendable, Codable {
    public let kind: String
    public let fileId: String
    public let mimeType: String?
    public let sizeBytes: Int?
    public let bytes: Data?
    public let captureFilename: String?
    public var utterance: SpeechUtterance?

    public var chatTypeAndMime: (type: String, mime: String)? {
        if utterance != nil { return ("audio", mimeType ?? "audio/ogg") }
        if let mimeType, mimeType.lowercased().hasPrefix("image/") {
            return ("image", mimeType.lowercased())
        }
        let ext = captureFilename.map { URL(fileURLWithPath: $0).pathExtension } ?? ""
        if let resolved = ChatAttachmentTypeResolver.typeAndMime(forExtension: ext) {
            return resolved
        }
        switch mimeType?.lowercased() {
        case "application/pdf": return ChatAttachmentTypeResolver.typeAndMime(forExtension: "pdf")
        case "text/plain": return ChatAttachmentTypeResolver.typeAndMime(forExtension: "txt")
        case "text/markdown", "text/x-markdown": return ChatAttachmentTypeResolver.typeAndMime(forExtension: "md")
        default: return nil
        }
    }

    public init(
        kind: String,
        fileId: String,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        bytes: Data? = nil,
        captureFilename: String? = nil
    ) {
        self.kind = kind
        self.fileId = fileId
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.bytes = bytes
        self.captureFilename = captureFilename
    }
}

// MARK: - TelegramMediaDownloadError

public enum TelegramMediaDownloadError: Error, Equatable {
    case oversized(reportedBytes: Int, capBytes: Int)
    case missingFilePath
    case httpError(status: Int)
    case malformedResponse
}

// MARK: - TelegramMediaDownloader

/// Two-stage media downloader:
///   1. POST https://api.telegram.org/bot<token>/getFile { file_id } → learn file_path + file_size
///   2. GET  https://api.telegram.org/file/bot<token>/<file_path>  → raw bytes
///
/// Honors a max-size cap: if getFile reports file_size > maxBytes the download is
/// refused with `.oversized` before any byte transfer occurs. The actual body is
/// also bounded while downloading, even when the reported size is absent/wrong.
public actor TelegramMediaDownloader {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Normalize URLSession cancellation so admission can release the saved message.
    public func download(
        token: String,
        attachment: TelegramMediaAttachment,
        maxBytes: Int = 25 * 1024 * 1024
    ) async throws -> TelegramMediaAttachment {
        do {
            return try await performDownload(
                token: token,
                attachment: attachment,
                maxBytes: maxBytes
            )
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func performDownload(
        token: String,
        attachment: TelegramMediaAttachment,
        maxBytes: Int
    ) async throws -> TelegramMediaAttachment {
        let encodedToken = _tgEncodeBotToken(token)
        let result: [String: JSONValue]
        do {
            result = try await TelegramPollLoop._tgPostJSON(token: token, method: "getFile",
                resultType: [String: JSONValue].self, session: session) {
                try JSONSerialization.data(withJSONObject: ["file_id": attachment.fileId])
            }.value
        } catch let failure as TelegramAPIFailure {
            if failure.kind == .httpStatus, let status = failure.httpStatus {
                throw TelegramMediaDownloadError.httpError(status: status)
            }
            throw failure
        }

        if let reportedSize = (result["file_size"]?.integerValue.flatMap(Int.init(exactly:)) ?? result["file_size"]?.stringValue.flatMap(Int.init)), reportedSize > maxBytes {
            throw TelegramMediaDownloadError.oversized(reportedBytes: reportedSize, capBytes: maxBytes)
        }

        guard let filePath = result["file_path"]?.stringValue, !filePath.isEmpty else {
            throw TelegramMediaDownloadError.missingFilePath
        }

        let encodedPath = filePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
        var comps2 = URLComponents()
        comps2.scheme = "https"
        comps2.host = "api.telegram.org"
        comps2.percentEncodedPath = "/file/bot\(encodedToken)/\(encodedPath)"
        guard let fileURL = comps2.url else {
            throw TelegramMediaDownloadError.malformedResponse
        }

        let (body, resp2) = try await session.bytes(for: URLRequest(url: fileURL))
        defer { body.task.cancel() }
        try Task.checkCancellation()
        if let http = resp2 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramMediaDownloadError.httpError(status: http.statusCode)
        }
        let bytes = try await withTaskCancellationHandler {
            var downloaded = Data()
            for try await byte in body {
                try Task.checkCancellation()
                guard downloaded.count < maxBytes else {
                    throw TelegramMediaDownloadError.oversized(
                        reportedBytes: downloaded.count + 1, capBytes: maxBytes
                    )
                }
                downloaded.append(byte)
            }
            try Task.checkCancellation()
            return downloaded
        } onCancel: {
            body.task.cancel()
        }

        let filename = attachment.captureFilename ?? URL(fileURLWithPath: filePath).lastPathComponent

        return TelegramMediaAttachment(
            kind: attachment.kind,
            fileId: attachment.fileId,
            mimeType: attachment.mimeType,
            sizeBytes: bytes.count,
            bytes: bytes,
            captureFilename: filename.isEmpty ? nil : filename
        )
    }
}
