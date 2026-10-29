# Security Policy

## Reporting security issues

Please report security vulnerabilities through the project's
[private security advisory form](https://github.com/embwl0x/native-agent/security/advisories/new).

Do not open a public GitHub issue for security vulnerabilities.

## Trust model

NativeAgent is a **single-operator, Swift-app-owned** system. `NativeAgent.app` owns the live runtime in-process; there is no live external interpreter runtime, launchd runtime, or LAN HTTP fallback.

- **Local app UI:** trusted user surface, still subject to NativeAgent policy gates for risky actions.
- **Local loopback bridges:** listener-bound to the loopback interface, with bearer-token authorization for protected routes, intended for same-user local agent CLIs. Accept-time peer checks remain enabled as defense in depth; loopback checks do not authenticate an operating-system user or process identity. See the live [loopback boundaries](docs/threat-model.md#trust-boundaries).
- **Paired iOS app:** remote paired trust over the selected Apple-native device transport: iCloud KVS + Drive or an entitlement-gated CloudKit private database. Action and chat envelopes are HMAC-SHA256 signed with pairing material; iOS does not use local network HTTP.
- **Browser, web, Telegram, Slack, and connector inputs:** untrusted or externally authenticated surfaces that must pass connector proof, policy gates, and receipts before side effects.
- **All other callers:** rejected by default or fail closed.

Pause everything is checked before non-chat Full Mac admission, driven-agent
launch and each Chrome effect, including Chrome's enabled-switch path. Memory
kind backfill rechecks that same refusal before staging or applying its result.

## Shell access

Shell commands use the shared process runner with policy-dependent Seatbelt
confinement, including modes that omit the wrapper. The
[threat model](docs/threat-model.md#shell-process-boundary) owns that boundary.
Broad shell access is not isolation from the operator's files; do not rely on
it to contain a compromised or malicious model.

## Sensitive data storage

Ability secrets use the keyring (`Keyring.swift`) in the macOS Keychain; Slack's door tokens use `SlackCredentials.swift`. Retired services' credential files and Keychain items stay untouched and unread. Other file-backed OAuth tokens, pairing secrets, and sensitive config files are stored at filesystem mode `0600`. Tokens are never written to logs.

## Scope

NativeAgent does not have a bug bounty program. Responsible disclosure is appreciated. Response time is best-effort.

See [docs/threat-model.md](docs/threat-model.md) for the full threat model including what is and isn't defended.
