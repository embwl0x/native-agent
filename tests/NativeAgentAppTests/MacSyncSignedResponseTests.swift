import CryptoKit
import Foundation
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fence `app.bridges`, row `macsync.signedResponse`
// (MacSyncEngine+Security.swift:66 signedResponse / :60 hmacSHA256).
//
// This is the OUTBOUND half of the pairing HMAC boundary. The inbound half
// (validateInboxAction) is already covered by MacSyncInboxSecurityBoundaryTests;
// the signer was not. Its silent-failure class is WRONG VALUE across a
// two-vocabulary seam: the iOS client recomputes the MAC over the canonical
// (sorted-keys, signature-excluded) body. Any drift — a different canonical
// form, the signature field folded into its own MAC, an uppercase hex digest —
// produces a response that is well-formed, delivered, and rejected on the
// phone. The Mac logs nothing; the phone just shows a request that never
// completes.
//
// The expected digest here is computed INDEPENDENTLY with CryptoKit rather than
// by calling the same helper, so the test cannot agree with a broken signer.
//
// `MacSyncEngine.init` is private (singleton-enforced), so these drive `.shared`
// with an INJECTED cached secret — `PairingSecretManager.loadOrGenerateSecret()`
// is never reached, so no keychain/disk pairing material is read or written.
// Every test body below is synchronous @MainActor code with no suspension
// point between installing the secret and restoring it, so the mutation window
// cannot interleave with any other MainActor test.
@Suite("MacSync signed response", .serialized)
@MainActor
struct MacSyncSignedResponseTests {

    private let secret = Data("pairing-secret-for-eval-only-0123456789".utf8)

    /// Install `key` as the cached pairing secret for the duration of `work`,
    /// then restore whatever the engine held before.
    private func withPairingSecret<T>(_ key: Data, _ work: (MacSyncEngine) throws -> T) rethrows -> T {
        let engine = MacSyncEngine.shared
        let previousSecret = engine._pairingSecret
        let previousRotation = engine.pairingSecretRotationInProgress
        defer {
            engine.pairingSecretRotationInProgress = previousRotation
            engine._pairingSecret = previousSecret
        }
        engine.pairingSecretRotationInProgress = false
        engine._pairingSecret = key
        return try work(engine)
    }

    /// The iOS verifier's algorithm, written out independently.
    private func expectedSignature(for body: [String: String]) throws -> String {
        var canonicalBody = body
        canonicalBody.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(withJSONObject: canonicalBody, options: [.sortedKeys])
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: secret))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    @Test("the signature is HMAC-SHA256 over the sorted-keys body, lowercase hex")
    func signatureMatchesTheIndependentComputation() throws {
        try withPairingSecret(secret) { engine in
        let response = ["status": "ok", "msgId": "A1", "result": "done", "at": "2026-08-23T00:00:00Z"]

        let signed = try engine.signedResponse(response)
        let signature = try #require(signed["signature"])

        #expect(signature == (try expectedSignature(for: response)))
        #expect(signature.count == 64, "not a SHA-256 digest: \(signature.count) chars")
        #expect(signature.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "the digest must be lowercase hex — the phone compares strings")

        // Every original field survives untouched; signing is additive.
        for (key, value) in response {
            #expect(signed[key] == value, "signing mutated \(key)")
        }
        #expect(Set(signed.keys) == Set(response.keys).union(["signature"]))
        }
    }

    @Test("key ORDER in the caller's dictionary cannot change the signature")
    func signatureIsIndependentOfDictionaryOrder() throws {
        try withPairingSecret(secret) { engine in
        // Dictionary iteration order is not stable across instances; the
        // canonicalization is what makes the MAC reproducible on the phone.
        let a = try engine.signedResponse(["zeta": "1", "alpha": "2", "mid": "3"])
        let b = try engine.signedResponse(["mid": "3", "zeta": "1", "alpha": "2"])
        #expect(a["signature"] == b["signature"])
        }
    }

    @Test("any field change changes the signature")
    func signatureCoversEveryField() throws {
        try withPairingSecret(secret) { engine in
        let base = ["status": "ok", "msgId": "A1", "result": "done"]
        let baseline = try #require(try engine.signedResponse(base)["signature"])

        for key in base.keys {
            var mutated = base
            mutated[key] = (base[key] ?? "") + "-tampered"
            let signature = try #require(try engine.signedResponse(mutated)["signature"])
            #expect(signature != baseline, "\(key) is outside the MAC — it can be tampered in flight")
        }

        // An added field is covered too.
        var extended = base
        extended["extra"] = "x"
        #expect(try engine.signedResponse(extended)["signature"] != baseline)
        }
    }

    @Test("a pre-existing signature field is excluded, so re-signing is stable")
    func resigningIsIdempotent() throws {
        try withPairingSecret(secret) { engine in
        let response = ["status": "ok", "msgId": "A1"]

        let once = try engine.signedResponse(response)
        let twice = try engine.signedResponse(once)
        #expect(once["signature"] == twice["signature"],
                "the previous signature leaked into the MAC input — re-signed rows verify differently")

        // A forged signature on the way in must not change the outcome either.
        var forged = response
        forged["signature"] = "deadbeef"
        #expect(try engine.signedResponse(forged)["signature"] == once["signature"])
        }
    }

    @Test("a different secret produces a different signature")
    func signatureIsKeyed() throws {
        let response = ["status": "ok", "msgId": "A1"]
        let mine = try withPairingSecret(secret) { engine in
            try #require(try engine.signedResponse(response)["signature"])
        }
        let theirs = try withPairingSecret(Data("a-completely-different-pairing-secret".utf8)) { engine in
            try #require(try engine.signedResponse(response)["signature"])
        }
        #expect(mine != theirs, "the MAC is not keyed by the pairing secret")
    }

    @Test("signing fails CLOSED while the pairing secret is rotating")
    func rotationWindowRefusesToSign() throws {
        try withPairingSecret(secret) { engine in
        engine.beginPairingSecretRotation()
        #expect(engine._pairingSecret == nil, "rotation must drop the cached secret")
        #expect(throws: (any Error).self) {
            _ = try engine.signedResponse(["status": "ok"])
        }

        // Finishing rotation with the exact persisted bytes restores signing,
        // and the new signature is keyed to the NEW secret.
        let rotated = Data("rotated-pairing-secret-value-abcdef".utf8)
        engine.finishPairingSecretRotation(with: rotated)
        let signed = try engine.signedResponse(["status": "ok"])
        let expected = Data(
            HMAC<SHA256>.authenticationCode(
                for: try JSONSerialization.data(withJSONObject: ["status": "ok"], options: [.sortedKeys]),
                using: SymmetricKey(data: rotated)
            )
        ).map { String(format: "%02x", $0) }.joined()
        #expect(signed["signature"] == expected)
        }
    }
}
