#!/usr/bin/env swift
//
// Derive the signing key's public half for comparison with the app's SUPublicEDKey.
// Signature verification with the private key alone cannot prove the app trusts it.
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

/// Sparkle accepts a 32-byte seed or a 96-byte expanded-private || public secret.
/// Derive from the seed; expanded keys already hold the public half at bytes 64..<96.
/// Re-deriving from an expanded key would hash an already-hashed key and give the wrong answer.
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
