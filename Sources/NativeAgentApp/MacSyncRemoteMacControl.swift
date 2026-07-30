import Foundation
import NativeAgentCore

@MainActor
struct MacSyncRemoteMacControl {
    let api: NativeClient

    func dispatch(payload: [String: String]) async throws -> [String: String] {
        let method = payload["method"] ?? ""
        let endpoint = Self.endpoint(for: method)
        guard !endpoint.isEmpty else {
            return ["status": "error", "message": "Unknown mac_control method: \(method)"]
        }
        if Self.requiresFullRemoteMacControl(method: method) {
            guard let policy = try? await api.getTrustPolicy(), Self.fullRemoteMacControlAllowed(policy) else {
                return [
                    "status": "error",
                    "message": "\(method) requires Full Mac access with iOS remote enabled on the Mac.",
                ]
            }
        }

        var body: [String: Any] = ["trigger": "ios"]
        for (key, value) in payload where key != "method" && key != "trigger" {
            body[key] = value
        }
        let requestedTimeout = Double(payload["timeout"] ?? "") ?? 60
        let runTimeout = min(max(requestedTimeout + 30, 60), 660)
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let run = try await api.macControlRun(path: endpoint, bodyData: bodyData, timeout: runTimeout)
        let result: [String: Any]
        if let json = run.json {
            result = json
        } else if let parsed = try? JSONSerialization.jsonObject(with: run.rawData) as? [String: Any] {
            result = parsed
        } else {
            result = [:]
        }

        let statusOK = (200..<300).contains(run.statusCode)
        let nestedOutput = result["output"] as? [String: Any]
        func responseValue(_ key: String) -> Any? {
            result[key] ?? nestedOutput?[key]
        }

        var passthrough: [String: String] = [:]
        for (key, value) in result {
            if let string = value as? String {
                passthrough[key] = string
            } else {
                passthrough[key] = "\(value)"
            }
        }
        if let nestedOutput {
            for (key, value) in nestedOutput where passthrough[key] == nil {
                if let string = value as? String {
                    passthrough[key] = string
                } else {
                    passthrough[key] = "\(value)"
                }
            }
        }

        passthrough["status"] = (responseValue("status") as? String) ?? passthrough["status"] ?? "ok"
        let exitCode = responseValue("exit_code") as? Int ?? 0
        if !statusOK
            || (responseValue("blocked") as? Bool) == true
            || !(responseValue("block_reason") as? String ?? "").isEmpty
            || exitCode != 0 {
            passthrough["status"] = "error"
            passthrough["ok"] = "false"
            if passthrough["message"] == nil {
                passthrough["message"] = (responseValue("block_reason") as? String)
                    ?? (responseValue("error") as? String)
                    ?? "Mac control action was blocked."
            }
        }

        let resultText: String
        if (responseValue("output_kind") as? String) == "binary_data" {
            resultText = (responseValue("stdout") as? String) ?? "<binary output>"
        } else if let content = responseValue("content") as? String {
            resultText = content
        } else if let stdout = responseValue("stdout") as? String, !stdout.isEmpty {
            resultText = stdout
        } else if let stderr = responseValue("stderr") as? String, !stderr.isEmpty {
            resultText = stderr
        } else if let results = responseValue("results") as? [String] {
            resultText = results.joined(separator: "\n")
        } else if let results = responseValue("results") as? [Any] {
            resultText = results.map { "\($0)" }.joined(separator: "\n")
        } else {
            resultText = (responseValue("error") as? String) ?? ""
        }
        passthrough["result"] = resultText
        return passthrough
    }

    private static func endpoint(for method: String) -> String {
        let map: [String: String] = [
            "runAppleScript": "/v1/mac_control/applescript",
            "runJxa": "/v1/mac_control/jxa",
            "runShortcut": "/v1/mac_control/shortcut",
            "runSpotlight": "/v1/mac_control/spotlight",
            "focusApp": "/v1/mac_control/focus_app",
            "quitApp": "/v1/mac_control/quit_app",
            "keystroke": "/v1/mac_control/keystroke",
            "clickAt": "/v1/mac_control/click",
            "system": "/v1/mac_control/system",
            "readFile": "/v1/mac_control/file/read",
            "writeFile": "/v1/mac_control/file/write",
            "listDirectory": "/v1/mac_control/file/list",
            "moveFile": "/v1/mac_control/file/move",
            "trashFile": "/v1/mac_control/file/trash",
            "notify": "/v1/mac_control/notify",
            "runShell": "/v1/mac_control/shell",
            "selfTest": "/v1/mac_control/self_test",
        ]
        return map[method] ?? ""
    }

    private static func requiresFullRemoteMacControl(method: String) -> Bool {
        Set(["runShell", "readFile", "writeFile", "listDirectory", "moveFile", "trashFile"]).contains(method)
    }

    private static func fullRemoteMacControlAllowed(_ policy: TrustPolicy) -> Bool {
        guard policy.macControlPolicy?.remoteFromIosAllowed == true else { return false }
        guard policy.filePolicy?.outsideWorkspaceDefault == "allow"
            || policy.permissionLevel == "full_mac_os"
            || policy.permissionLevel == "wide_open_receipts" else { return false }
        if policy.fullMacNeverExpires == true || policy.fullMacExpiresAt?.lowercased() == "never" {
            return true
        }
        if let expiresAt = policy.fullMacExpiresAt,
           !expiresAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let expires = tolerantISO8601Date(from: expiresAt) else { return false }
            return Date() <= expires
        }
        if let confirmedAt = policy.fullMacConfirmedAt,
           let confirmed = tolerantISO8601Date(from: confirmedAt) {
            let rawHours = policy.fullMacMaxDurationHours ?? 4
            let hours = min(max(rawHours, 0.1), 24)
            return Date() <= confirmed.addingTimeInterval(hours * 3600)
        }
        return false
    }

    private static func tolerantISO8601Date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
