import Foundation
import MacControl
import SQLite3
// Blueprint: | `FoldedText.swift` | case- and diacritic-insensitive matching and the `folded_contains` SQLite function |

/// Matching as people expect it, case and accents aside ("elodie" finds "Élodie"). SQLite's LIKE folds ASCII only, so the Mail read registers
/// `folded_contains(text, needle)`, `needle` already `fold`ed.
enum FoldedText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func register(_ database: OpaquePointer, context: MacOperationContext) {
        sqlite3_create_function_v2(database, "folded_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let hay = sqlite3_value_text(values[0]), let needle = sqlite3_value_text(values[1]) else {
                sqlite3_result_int(context, 0)
                return
            }
            let text = UnsafeBufferPointer(start: hay, count: Int(sqlite3_value_bytes(values[0])))
            let wanted = UnsafeBufferPointer(start: needle, count: Int(sqlite3_value_bytes(values[1])))
            // ASCII on both sides (most subjects and addresses) folds as lowercase, without a String.
            let found = text.allSatisfy({ $0 < 0x80 }) && wanted.allSatisfy({ $0 < 0x80 })
                ? FoldedText.asciiContains(text, wanted)
                : FoldedText.fold(String(decoding: text, as: UTF8.self)).contains(String(decoding: wanted, as: UTF8.self))
            sqlite3_result_int(context, found ? 1 : 0)
        }, nil, nil, nil)
    }

    private static func asciiContains(_ text: UnsafeBufferPointer<UInt8>, _ wanted: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !wanted.isEmpty else { return true }
        guard text.count >= wanted.count else { return false }
        func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte | 0x20 : byte }
        next: for start in 0...(text.count - wanted.count) {
            for offset in 0..<wanted.count where lower(text[start + offset]) != wanted[offset] { continue next }
            return true
        }
        return false
    }
}
