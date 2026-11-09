import Foundation
import CryptoKit
import Darwin
// Blueprint: | `ContactCaller.swift` | `ContactCaller`: who calls through a contact's door, its own conversation id, its name and whether it still runs |

/// One caller of a contact's door: the host process that started the connector, named by its process id and the moment it started. A process id alone is
/// reused; with its start time it names one process for good, so a caller that is gone never returns under the same name.
public struct ContactCaller: Sendable, Hashable {
    /// The connector names its caller on every call: `<pid>.<start seconds>.<start microseconds>`, decimal digits.
    public static let header = "x-nativeagent-caller"
    public let pid: Int32
    public let seconds: Int64
    public let microseconds: Int32

    public struct Unreadable: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    init?(pid: Int32, seconds: Int64, microseconds: Int32) {
        guard pid > 0, (0..<(Int64(1) << 40)).contains(seconds), (0..<1_000_000).contains(microseconds) else { return nil }
        self.pid = pid; self.seconds = seconds; self.microseconds = microseconds
    }

    /// The header's value, strictly: anything else is refused, never read as a call without a caller.
    public init(header value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.utf8.count <= 40, parts.count == 3,
              parts.allSatisfy({ part in (1...13).contains(part.utf8.count) && part.utf8.allSatisfy { (0x30...0x39).contains($0) } }),
              let pid = Int32(parts[0]), let seconds = Int64(parts[1]), let microseconds = Int32(parts[2]),
              let caller = ContactCaller(pid: pid, seconds: seconds, microseconds: microseconds) else {
            throw Unreadable(message: "The \(Self.header) header must be <pid>.<start seconds>.<start microseconds>, in decimal digits.")
        }
        self = caller
    }

    public var headerValue: String { "\(pid).\(seconds).\(microseconds)" }

    /// The host that started this process: the connector's caller, read once when it starts.
    public static func parent() throws -> ContactCaller {
        let pid = getppid()
        guard let start = try started(pid: pid),
              let caller = ContactCaller(pid: pid, seconds: Int64(start.tv_sec), microseconds: start.tv_usec) else {
            throw Unreadable(message: "The connector's host process \(pid) has no readable start time, so it cannot name its caller.")
        }
        return caller
    }

    /// Whether this exact process still runs: its id exists and that process started when this caller did. A read the kernel refuses throws: it is
    /// neither live nor gone.
    public func isLive() throws -> Bool {
        guard let start = try Self.started(pid: pid) else { return false }
        return Int64(start.tv_sec) == seconds && start.tv_usec == microseconds
    }

    /// The start time of the process with this id; nil when no process has it.
    private static func started(pid: Int32) throws -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
            let failure = errno
            if failure == ESRCH { return nil }
            throw Unreadable(message: "The process table entry of process \(pid) could not be read (errno \(failure)).")
        }
        return size == 0 ? nil : info.kp_proc.p_un.__p_starttime
    }

    /// The contact's own conversation: every call whose door names no caller, and every held send that names no conversation.
    public static func shared(peer: String) -> String { "mcp-" + peer }

    /// This caller's conversation with the contact: `mcp-` and a UUID whose bytes are the caller's pid, its start time and a check binding both to the
    /// contact, so the id alone names its caller and only that contact reads it as one of its own.
    public func conversation(peer: String) -> String {
        let body = Self.body(pid: pid, seconds: seconds, microseconds: microseconds)
        let hex = (body + Self.check(body, peer: peer)).map { String(format: "%02x", $0) }.joined()
        let groups = [(0, 8), (8, 4), (12, 4), (16, 4), (20, 12)].map { String(hex.dropFirst($0.0).prefix($0.1)) }
        return "mcp-" + groups.joined(separator: "-")
    }

    /// The caller a conversation of this contact belongs to; nil for the contact's own conversation and for every other id.
    public init?(conversation: String, peer: String) {
        guard conversation != Self.shared(peer: peer), conversation.hasPrefix("mcp-"),
              let uuid = UUID(uuidString: String(conversation.dropFirst(4))) else { return nil }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let body = Array(bytes[0..<12])
        guard Array(bytes[12..<16]) == Self.check(body, peer: peer) else { return nil }
        func number(_ range: Range<Int>) -> Int64 { body[range].reduce(Int64(0)) { $0 << 8 | Int64($1) } }
        guard let pid = Int32(exactly: number(0..<4)), let microseconds = Int32(exactly: number(9..<12)),
              let caller = ContactCaller(pid: pid, seconds: number(4..<9), microseconds: microseconds) else { return nil }
        self = caller
    }

    /// The conversation, spelled as its owner writes it, when the contact opened it by calling in: its own, or one of its callers'. Nil for any other id.
    public static func held(_ conversation: String?, peer: String) -> String? {
        guard let conversation else { return nil }
        if conversation == shared(peer: peer) { return conversation }
        return ContactCaller(conversation: conversation, peer: peer)?.conversation(peer: peer)
    }

    /// The conversation's name, in words a person reads: the contact, when its caller opened on this Mac's clock, and that caller's process.
    public func name(contact: String) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "MMM d, HH:mm:ss"
        let opened = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
        return contact + ", opened " + clock.string(from: opened) + " (process \(pid))"
    }

    private static func body(pid: Int32, seconds: Int64, microseconds: Int32) -> [UInt8] {
        func bytes(_ value: Int64, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        return bytes(Int64(pid), 4) + bytes(seconds, 5) + bytes(Int64(microseconds), 3)
    }

    private static func check(_ body: [UInt8], peer: String) -> [UInt8] {
        Array(SHA256.hash(data: Data("nativeagent-caller\n".utf8) + Data(peer.utf8) + Data([0]) + Data(body)).prefix(4))
    }
}
