# Security Policy

## Reporting security issues

Please report security vulnerabilities through the project's
[private security advisory form](https://github.com/embwl0x/native-agent/security/advisories/new).

Do not open a public GitHub issue for security vulnerabilities.

## Trust model

NativeAgent is a **single-operator, Swift-app-owned** system. `NativeAgent.app` owns the live runtime in-process; there is no live external interpreter runtime, launchd runtime, or LAN HTTP fallback.

- **Local app UI:** trusted user surface, still subject to NativeAgent policy gates for risky actions.
- **Local loopback bridges:** listener-bound to the loopback interface and bearer-token gated, intended for same-user local agent CLIs. Accept-time peer checks remain enabled as defense in depth.
- **Paired iOS app:** remote paired trust over the selected Apple-native device transport: iCloud KVS + Drive or an entitlement-gated CloudKit private database. Action and chat envelopes are HMAC-SHA256 signed with pairing material; iOS does not use local network HTTP.
- **Browser, web, Telegram, Slack, and connector inputs:** untrusted or externally authenticated surfaces that must pass connector proof, policy gates, and receipts before side effects.
- **All other callers:** rejected by default or fail closed.

## Bash sandboxing is best-effort only

The `bash` tool applies a heuristic deny-list for dangerous patterns. It is **not** a security boundary. The trust model is app-owned runtime + single operator; bash heuristics are defense-in-depth, not containment. Do not rely on bash sandboxing to prevent a compromised or malicious model from executing arbitrary commands.

## Sensitive data storage

The GitHub connector PAT is stored in the macOS Keychain. Its JSON files contain non-secret metadata only and migrate legacy plaintext only after a verified Keychain write. Other file-backed OAuth tokens, pairing secrets, and sensitive config files are stored at filesystem mode `0600`. Tokens are never written to logs.

## Scope

NativeAgent does not have a bug bounty program. Responsible disclosure is appreciated. Response time is best-effort.

See [docs/threat-model.md](docs/threat-model.md) for the full threat model including what is and isn't defended.
