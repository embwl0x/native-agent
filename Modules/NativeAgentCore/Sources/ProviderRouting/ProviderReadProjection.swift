import Foundation

public enum ProviderReadProjection {
    public static func verifyCodex(dataRoot: URL) async throws -> CodexCheckResponse {
        // fix2/F6 (2026-06-02): the prior stub returned `ok: true` unconditionally,
        // which is the lie this fix is meant to eliminate — a user with no codex
        // CLI session was being told "verified". Now we actually check
        // `<dataRoot>/codex_home/auth.json` for a non-empty `tokens.access_token`,
        // matching the source-3 codex-auth probe in `getProviders`.
        let codexAuthPath = dataRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: codexAuthPath), !data.isEmpty else {
            return CodexCheckResponse(ok: false, model: "no codex auth.json or empty access_token")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexCheckResponse(ok: false, model: "no codex auth.json or empty access_token")
        }
        // Accept either {tokens: {access_token}} (new codex schema) or a top-level
        // access_token key (older schema). Both shapes appear in the wild; either
        // a non-empty access_token string counts as verified.
        let nested = (obj["tokens"] as? [String: Any])?["access_token"] as? String
        let flat = obj["access_token"] as? String
        let token = (nested?.isEmpty == false) ? nested : flat
        if let token, !token.isEmpty {
            return CodexCheckResponse(ok: true, model: "codex auth.json verified")
        }
        return CodexCheckResponse(ok: false, model: "no codex auth.json or empty access_token")
    }
}
