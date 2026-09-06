import Foundation

// MARK: - TelegramMediaAttachment

/// A Telegram media attachment (photo, voice, video, document, …).
public struct TelegramMediaAttachment: Sendable, Codable {
    public let kind: String
    public let fileId: String
    public let mimeType: String?
    public let sizeBytes: Int?
    public let bytes: Data?
    public let captureFilename: String?

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

public protocol TelegramMediaDownloading: Sendable {
    func download(
        token: String,
        attachment: TelegramMediaAttachment,
        maxBytes: Int
    ) async throws -> TelegramMediaAttachment
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

    /// 2026-09-06: URLSession reports cooperative task cancellation as
    /// NSURLError -999 (`URLError.cancelled`), not `CancellationError` — and
    /// both `session.bytes` and the byte loop torn down by `body.task.cancel()`
    /// surface it. The poll loop's photo branch releases the admitted claim on
    /// `CancellationError` only, so an unnormalised -999 was read as an
    /// ordinary download failure: the photo was consumed, the claim settled,
    /// and the sender never got an answer. `TelegramBot+Client.longPoll`
    /// normalises the same way.
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
        // --- Stage 1: getFile ---
        let encodedToken = _tgPctEncode(token)
        var comps1 = URLComponents()
        comps1.scheme = "https"
        comps1.host = "api.telegram.org"
        comps1.percentEncodedPath = "/bot\(encodedToken)/getFile"
        guard let getFileURL = comps1.url else {
            throw TelegramMediaDownloadError.malformedResponse
        }
        var req1 = URLRequest(url: getFileURL)
        req1.httpMethod = "POST"
        req1.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body1 = try JSONSerialization.data(withJSONObject: ["file_id": attachment.fileId])
        req1.httpBody = body1

        let (data1, resp1) = try await session.data(for: req1)
        if let http = resp1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramMediaDownloadError.httpError(status: http.statusCode)
        }

        guard
            let json1 = try? JSONSerialization.jsonObject(with: data1) as? [String: Any],
            let result = json1["result"] as? [String: Any]
        else {
            throw TelegramMediaDownloadError.malformedResponse
        }

        // Check reported file size before transferring bytes.
        if let reportedSize = result["file_size"] as? Int, reportedSize > maxBytes {
            throw TelegramMediaDownloadError.oversized(reportedBytes: reportedSize, capBytes: maxBytes)
        }

        guard let filePath = result["file_path"] as? String, !filePath.isEmpty else {
            throw TelegramMediaDownloadError.missingFilePath
        }

        // --- Stage 2: download bytes ---
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

        let filename = URL(fileURLWithPath: filePath).lastPathComponent

        return TelegramMediaAttachment(
            kind: attachment.kind,
            fileId: attachment.fileId,
            mimeType: attachment.mimeType,
            sizeBytes: bytes.count,
            bytes: bytes,
            captureFilename: filename.isEmpty ? nil : filename
        )
    }

    // MARK: - private helpers

    private func _tgPctEncode(_ token: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
    }
}

extension TelegramMediaDownloader: TelegramMediaDownloading {}
