#!/usr/bin/env swift
//
// A2.1 round 2 (2026-07-24): derive the Ed25519 PUBLIC key from a Sparkle EdDSA
// private key file — the check that makes "am I signing with the key this build
// trusts?" independent of Sparkle's warning prose.
//
// WHY THIS EXISTS
//   generate_appcast.sh used to detect a wrong signing key by grepping Sparkle's
//   warning text ("does not match key"). Reword that line upstream and a release
//   signed with the wrong key sails through: `sign_update --verify --ed-key-file`
//   cannot catch it either, because it only proves the signature matches the key
//   we just signed with, never the key baked into the app as SUPublicEDKey.
//   Comparing derived-public-half against the bundle's SUPublicEDKey closes that
//   gap with arithmetic.
//
// Swift, not a helper script in another language: this repo is under a zero-Python
// source mandate (Modules/NativeAgentCore/Tests/DoctorChecksTests/
// NoPythonRegressionTests.swift), and CryptoKit gives the derivation for free.
//
// Usage:
//   script/sparkle_ed_public_key.swift <private-key-file>   # prints base64 public key
//   script/sparkle_ed_public_key.swift -                    # reads the base64 key on stdin
//   script/sparkle_ed_public_key.swift --new                # prints "<seed-b64> <public-b64>"
//                                                           # (throwaway pair for tests)

import Foundation
import CryptoKit

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
    exit(1)
}

/// The public half of whatever shape a Sparkle EdDSA private-key file comes in.
///
/// Sparkle accepts exactly two secret lengths — verified against its own
/// `common_cli/Secret.swift` (`decodePrivateAndPublicKeys`), not assumed:
///   * 32 bytes  — the private seed (what `generate_keys -x` writes today).
///                 The public key is DERIVED from it.
///   * 96 bytes  — legacy: the already SHA-512-expanded 64-byte orlp/Ed25519
///                 private key CONCATENATED with its 32-byte public key. Bytes
///                 64..<96 ARE the public key; re-deriving from the first 32
///                 bytes here would hash an already-hashed key and produce a
///                 plausible-looking WRONG answer — which would then be reported
///                 as "your key pair does not match" on a perfectly good key.
/// Anything else Sparkle itself rejects, so this does too.
func publicKeyBase64(fromKeyMaterial text: String) -> String {
    let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
    guard !compact.isEmpty else { die("private key file is empty") }
    guard let raw = Data(base64Encoded: compact) else {
        die("private key file is not valid base64 (expected the output of 'generate_keys -x')")
    }
    switch raw.count {
    case 32:
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return key.publicKey.rawRepresentation.base64EncodedString()
        } catch {
            die("could not derive the Ed25519 public key: \(error)")
        }
    case 96:
        return raw.suffix(32).base64EncodedString()
    default:
        die("""
            unexpected Sparkle key length: \(raw.count) decoded bytes.
                   Sparkle accepts only a 32-byte seed or the legacy 96-byte \
            (expanded-private || public) secret.
            """)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, args.count == 1 else {
    FileHandle.standardError.write(Data("usage: sparkle_ed_public_key.swift <private-key-file>|-|--new\n".utf8))
    exit(2)
}

switch first {
case "--new":
    let fresh = Curve25519.Signing.PrivateKey()
    print("\(fresh.rawRepresentation.base64EncodedString()) \(fresh.publicKey.rawRepresentation.base64EncodedString())")
case "-":
    let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(publicKeyBase64(fromKeyMaterial: text), terminator: "")
default:
    guard let text = try? String(contentsOfFile: first, encoding: .utf8) else {
        die("could not read the private key file: \(first)")
    }
    print(publicKeyBase64(fromKeyMaterial: text), terminator: "")
}
