import Foundation
import Darwin
// Blueprint: | `FaceLinkLog.swift` | Body and face append-only link record; correlation identities and redacted failures exclude payloads |

public actor FaceLinkLog {
    public enum Role: String, Sendable { case body, face }
    private let handle: FileHandle
    private let role: Role

    private init(handle: FileHandle, role: Role) { self.handle = handle; self.role = role }

    @concurrent public static func open(dataRoot: URL, role: Role) async throws -> FaceLinkLog {
        let directory = dataRoot.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("FaceLink.log")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw WireFailure(code: "face_log_open_failed", message: "The \(role.rawValue) could not open its link record.",
                cause: "POSIX \(errno): \(url.path)", effects: .none)
        }
        return FaceLinkLog(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), role: role)
    }

    public func record(_ line: String) throws {
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let line = TurnSecretRedactor.redactText(line).replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let prefix = "\(stamp) pid=\(ProcessInfo.processInfo.processIdentifier) role=\(role.rawValue) "
        try handle.write(contentsOf: Data((prefix + line + "\n").utf8))
    }

    public func close() throws { try handle.close() }

    nonisolated public static func name<T>(_ value: T) -> String {
        Mirror(reflecting: value).children.first?.label ?? String(describing: value)
    }

    nonisolated public static func key(_ key: FaceKey) -> String {
        switch key {
        case .conversation(let session), .turn(let session), .transcript(let session), .session(let session):
            return name(key) + " session=" + session
        case .page(let page): return "page=" + page
        default: return name(key)
        }
    }

    nonisolated public static func act(_ act: FaceAct) -> String {
        switch act {
        case .attach(let version): return "attach version=\(version)"
        case .frameApplied(let epoch, let sequence, let barriers):
            return "frameApplied epoch=\(epoch) sequence=\(sequence) barriers=" + barriers.map(\.uuidString).joined(separator: ",")
        case .cancelRequest(let request): return "cancelRequest request=\(request)"
        case .selectConversation(let session, _): return "selectConversation session=" + session
        case .openTranscriptReader(let request):
            return "openTranscriptReader session=\(request.session) presentation=\(request.presentation) " + geometry(request.geometry)
        case .resizeTranscriptReader(let value): return "resizeTranscriptReader " + geometry(value)
        case .releaseTranscriptReader(let reader): return "releaseTranscriptReader reader=\(reader)"
        case .transcriptReceipt(let reader, let receipt):
            let detail: String
            switch receipt {
            case .applied(let script), .painted(let script), .rejected(let script, _): detail = " script=\(script)"
            case .viewport(let blocks): detail = " blocks=\(blocks.count)"
            case .complete, .rebase, .revealed: detail = ""
            }
            return "transcriptReceipt reader=\(reader) receipt=\(name(receipt))" + detail
        case .observe(let id, let demand):
            let key: String
            switch demand {
            case .key(let value): key = Self.key(value)
            case .composer(let session): key = "composer session=" + session
            default: key = name(demand)
            }
            return "observe id=\(id) key=\(key)"
        case .unobserve(let id): return "unobserve id=\(id)"
        default: return name(act)
        }
    }

    nonisolated private static func geometry(_ value: TranscriptReaderGeometry) -> String {
        "reader=\(value.reader) width=\(value.width) height=\(value.viewportHeight) scale=\(value.scale) blocks=\(value.viewport.count)"
    }

    nonisolated public static func feed(_ batch: FaceBatch) -> String {
        let keys = batch.values.keys.map { key($0) }.sorted().joined(separator: ",")
        var identities: [String] = []
        for value in batch.values.values {
            if let transcript = value.base as? TranscriptFace {
                for (reader, script) in transcript.readers {
                    identities.append("reader=\(reader) script=\(script.id) base=\(script.base?.uuidString ?? "nil")")
                }
            }
            if let settings = value.base as? SettingsFace {
                identities.append("composers=" + settings.providers.sessions.keys.sorted().joined(separator: ","))
            }
        }
        return "feed sequence=\(batch.sequence) keys=\(keys)" + (identities.isEmpty ? "" : " " + identities.sorted().joined(separator: " "))
    }

    nonisolated public static func reply(_ reply: FaceActReply) -> String {
        switch reply {
        case .failed(let error), .refused(let error): return name(reply) + " " + failure(error)
        case .committed(let result):
            return "committed" + (result.publicationFailure.map { " publicationFailure " + failure($0) } ?? "")
        case .operation(.completed(let result)):
            return "operation completed" + (result.publicationFailure.map { " publicationFailure " + failure($0) } ?? "")
        case .card(let result):
            return "card" + (result.failure.map { " failure " + failure($0) } ?? "")
        default: return name(reply)
        }
    }

    nonisolated public static func reply(_ reply: FaceReply) -> String {
        switch reply {
        case .failed(let error), .refused(let error): return name(reply) + " " + failure(error)
        default: return name(reply)
        }
    }

    nonisolated public static func failure(_ error: any Error) -> String {
        if let error = error as? WireFailure {
            return "code=\(error.code) message=\(error.message) cause=\(error.cause ?? "none") effects=\(error.effects)"
        }
        var parts = ["type=\(String(reflecting: type(of: error)))"]
        var current: NSError? = error as NSError
        var seen: Set<ObjectIdentifier> = []
        while let cause = current, seen.insert(ObjectIdentifier(cause)).inserted {
            parts.append("domain=\(cause.domain) code=\(cause.code) message=\(cause.localizedDescription)")
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " underlying=")
    }
}
