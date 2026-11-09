import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
#endif
// Blueprint: | `NativePersonInput.swift` | Shared person-event provenance for body input and renderer hand-back controls |

public enum NativePersonInput {
    #if os(macOS)
    public static func isPerson(_ event: CGEvent) -> Bool {
        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        if pid == 0 { return true }
        guard pid != getpid() else { return false }
        var name = [UInt8](repeating: 0, count: 64)
        let length = proc_name(pid, &name, UInt32(name.count))
        return length > 0 && String(decoding: name.prefix(Int(length)), as: UTF8.self) == "WindowServer"
    }

    @MainActor public static var currentActivation: Bool {
        guard let event = NSApp.currentEvent, [.leftMouseUp, .keyDown].contains(event.type), let input = event.cgEvent else { return false }
        return isPerson(input)
    }
    #endif
}
