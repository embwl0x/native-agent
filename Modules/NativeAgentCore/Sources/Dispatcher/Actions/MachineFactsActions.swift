import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import MacControl
import PersistenceCore
import TrustCenter
import CoreWLAN
import SystemConfiguration
#if canImport(Darwin)
import Darwin
#endif
// Blueprint: | `MachineFactsActions.swift` | `FileSystemActions.systemInfo`: machine and application facts, disk capacity, memory, processes, network, boot, presence and battery; existing bounded process reads |

extension FileSystemActions {
    // MARK: - system_info

    static func systemInfo(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        if input["person"] == .bool(true) {
            // The shape the line promises: {here, idle_seconds} at the top.
            var out: [String: JSONValue] = ["ok": .bool(true), "status": .string("ok")]
            if case .object(let fact) = MacPersonInput.presenceDetail { out.merge(fact) { $1 } }
            return .object(out)
        }
        if let speed = input["speed_test"], speed != .null {
            guard case .bool = speed else { return errResult("speed_test must be true or false.", code: "bad_input") }
            guard speed != .bool(true) || ((input["app"] == nil || input["app"] == .null) && input["check_updates"] != .bool(true)) else {
                return errResult("speed_test must be true or false and cannot combine with app or check_updates.", code: "bad_input")
            }
        }
        if case .string(let name)? = input["app"] {
            let app = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard input["check_updates"] != .bool(true) else {
                return errResult("Use app for an installed app version or check_updates for macOS updates, separately.", code: "bad_input")
            }
            let installedURL: URL?
            do { installedURL = try MacApplications.installedApplicationURL(named: app) }
            catch { return errResult(error.localizedDescription, code: "app_index_unavailable") }
            guard !app.isEmpty, let url = installedURL,
                  let bundle = Bundle(url: url), let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !version.isEmpty else {
                return errResult("No readable version for that exact installed app name. Supply its exact name or full .app path.", code: "app_version_unavailable")
            }
            return .object(["ok": .bool(true), "status": .string("ok"), "app": .string(url.deletingPathExtension().lastPathComponent),
                "path": .string(url.path), "version": .string(version),
                "build": (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).map(JSONValue.string) ?? .null])
        }
        if input["check_updates"] == .bool(true) {
            let run = runProcess("/usr/sbin/softwareupdate", ["--list"], timeout: 30, captureByteLimit: 64 * 1024)
            guard run.launched, !run.timedOut, run.status == 0, !run.captureReadFailed,
                  !run.stdoutTruncated, !run.stderrTruncated else {
                return errResult(run.timedOut ? "macOS update check exceeded 30 seconds; no update status is known. Check System Settings → General → Software Update."
                    : "macOS update check failed: \(run.stderr). Check System Settings → General → Software Update.", code: "software_update_unavailable")
            }
            return .object(["ok": .bool(true), "status": .string("ok"), "source": .string("softwareupdate --list"),
                "updates": .string(run.stdout + run.stderr),
                "scope": .string("macOS and software offered by Software Update. NativeAgent and App Store app updates are separate; check App Store → Updates for App Store apps.")])
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var fields: [String: JSONValue] = [
            "macos_version": .string("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"),
        ]
        var failures: [String] = []

        // APFS separates the sealed system volume from the writable data volume.
        // Name both; everyday disk capacity is the data volume's observation.
        for (key, path, name) in [("disk", "/System/Volumes/Data", "Data"), ("system_disk", "/", "System")] {
            var st = statfs()
            if statfs(path, &st) == 0 {
                // Used includes reserved blocks; free counts user-available blocks.
                let blockSize = UInt64(st.f_bsize)
                let total = UInt64(st.f_blocks) * blockSize
                let free = UInt64(st.f_bavail) * blockSize
                let used = UInt64(st.f_blocks >= st.f_bfree ? st.f_blocks - st.f_bfree : 0) * blockSize
                func gb(_ v: UInt64) -> Double { round2(Double(v) / 1_073_741_824.0) }
                let pct = total > 0 ? round1(Double(used) / Double(total) * 100.0) : 0.0
                fields[key] = .object([
                    "name": .string(name),
                    "path": .string(path),
                    "total_gb": .double(gb(total)),
                    "used_gb": .double(gb(used)),
                    "free_gb": .double(gb(free)),
                    "percent_used": .double(pct),
                ])
            } else {
                failures.append("\(name) volume (\(path)): statfs failed")
            }
        }

        // Memory: vm_stat output → pages × page_size → MB.
        if let vmOut = runCommand("/usr/bin/vm_stat", []) , vmOut.status == 0 {
            let text = vmOut.stdout
            var pageSize = 4096
            if let ps = firstCapturedInt(in: text, pattern: #"page size of (\d+) bytes"#) {
                pageSize = ps
            }
            func pages(_ label: String) -> Int {
                firstCapturedInt(in: text, pattern: "\(NSRegularExpression.escapedPattern(for: label)):\\s+([\\d.]+)") ?? 0
            }
            let free = pages("Pages free")
            let active = pages("Pages active")
            let inactive = pages("Pages inactive")
            let wired = pages("Pages wired down")
            let speculative = pages("Pages speculative")
            func toMB(_ p: Int) -> Int64 { Int64((Double(p) * Double(pageSize) / (1024.0 * 1024.0)).rounded()) }
            let totalPages = free + active + inactive + wired + speculative
            fields["memory"] = .object([
                "free_mb": .int(toMB(free)),
                "active_mb": .int(toMB(active)),
                "inactive_mb": .int(toMB(inactive)),
                "wired_mb": .int(toMB(wired)),
                "total_mb": .int(toMB(totalPages)),
            ])
        } else {
            failures.append("memory: vm_stat failed")
        }

        let processes = runProcess("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="],
            timeout: 5, captureByteLimit: 256 * 1024)
        if processes.launched, processes.status == 0, !processes.timedOut,
           !processes.stdoutTruncated, !processes.captureReadFailed {
            let rows: [(cpu: Double, memory: Int64, row: JSONValue)] = processes.stdout.split(separator: "\n").compactMap { line in
                let parts = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
                guard parts.count == 4, let pid = Int64(parts[0]),
                      let cpu = Double(parts[1]), cpu.isFinite, let rss = Int64(parts[2]) else { return nil }
                return (cpu, rss, .object(["pid": .int(pid), "name": .string(String(parts[3])),
                    "cpu_percent": .double(cpu), "resident_memory_mb": .double(Double(rss) / 1024)]))
            }
            fields["top_processes"] = .object([
                "by_cpu": .array(rows.sorted { $0.cpu > $1.cpu }.prefix(5).map(\.row)),
                "by_memory": .array(rows.sorted { $0.memory > $1.memory }.prefix(5).map(\.row)),
                "note": .string("Top five processes per ranking from one ps read. CPU is ps's scheduler estimate; memory is resident MB. Process arguments are not read."),
            ])
        } else { failures.append("top_processes: ps did not return a complete bounded snapshot") }

        // Network: ping 8.8.8.8 → reachable bool.
        var network: [String: JSONValue] = ["local_ip": .null, "vpn": .null]
        if let ping = runCommand("/sbin/ping", ["-c", "1", "-W", "1000", "8.8.8.8"]) {
            network["reachable"] = .bool(ping.status == 0)
        } else {
            failures.append("network: ping failed")
        }
        if let store = SCDynamicStoreCreate(nil, "NativeAgent system info" as CFString, nil, nil),
           let primary = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            network["primary_interface"] = (primary["PrimaryInterface"] as? String).map(JSONValue.string) ?? .null
            network["router"] = (primary["Router"] as? String).map(JSONValue.string) ?? .null
            if let interface = primary["PrimaryInterface"] as? String {
                let addresses = ["IPv4", "IPv6"].flatMap { family -> [String] in
                    let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/\(family)" as CFString) as? [String: Any]
                    return state?["Addresses"] as? [String] ?? []
                }
                network["local_ip"] = .array(addresses.map(JSONValue.string))
            }
        }
        let publicIP = runProcess("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--connect-timeout", "2", "--max-time", "3", "https://api.ipify.org"], timeout: 5, captureByteLimit: 1024)
        let address = publicIP.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if publicIP.launched, publicIP.status == 0, !publicIP.timedOut, !publicIP.stdoutTruncated,
           !publicIP.captureReadFailed, inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 {
            network["public_ip"] = .string(address)
        } else {
            network["public_ip"] = .null
            failures.append("public_ip: HTTPS lookup unavailable within its 3-second limit")
        }
        let vpn = runProcess("/usr/sbin/scutil", ["--nc", "list"], timeout: 3, captureByteLimit: 16 * 1024)
        if vpn.launched, vpn.status == 0, !vpn.timedOut, !vpn.stdoutTruncated, !vpn.captureReadFailed {
            let connected = vpn.stdout.split(separator: "\n").filter { $0.contains("(Connected)") }.map { JSONValue.string(String($0)) }
            network["vpn"] = .object(["connected": .bool(!connected.isEmpty), "services": .array(connected),
                "source": .string("scutil --nc list"),
                "note": .string("Connected macOS VPN services. VPN apps that do not register a network connection service may not appear; this does not prove all traffic uses a VPN.")])
        } else { failures.append("vpn: macOS network connection services could not be read") }
        if input["speed_test"] == .bool(true) {
            let speed = runProcess("/usr/bin/networkQuality", ["-s", "-c", "-M", "20"], timeout: 25, captureByteLimit: 64 * 1024)
            if speed.launched, speed.status == 0, !speed.timedOut, !speed.stdoutTruncated, !speed.captureReadFailed,
               let measured = try? JSONValue.parse(Data(speed.stdout.utf8)), case .object = measured {
                network["speed_test"] = .object(["source": .string("networkQuality -s -c -M 20"), "measurement": measured,
                    "note": .string("Requested sequential upload/download measurement, limited to 20 seconds. Throughput is bits per second; responsiveness is round trips per minute. This uses internet bandwidth.")])
            } else { failures.append("speed_test: no complete networkQuality measurement; request a new measurement when the connection is available") }
        }
        if let wifi = CWWiFiClient.shared().interface() {
            let ssid = wifi.ssid()
            network["wifi"] = .object([
                "interface": wifi.interfaceName.map(JSONValue.string) ?? .null,
                "power_on": .bool(wifi.powerOn()), "ssid": ssid.map(JSONValue.string) ?? .null,
                "note": .string(ssid == nil
                    ? "Wi-Fi SSID is unavailable: Wi-Fi may be disconnected or macOS may withhold it without Location Services access. No permission was requested."
                    : "Current Wi-Fi SSID from CoreWLAN; primary_interface identifies the Mac's active IPv4 route."),
            ])
        } else { network["wifi_note"] = .string("No Wi-Fi interface is available.") }
        fields["network"] = .object(network)
        // Boot time keeps uptime advancing through sleep.
        var boot = timeval(), size = MemoryLayout<timeval>.stride
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 {
            let booted = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
            let bootISO = ISO8601DateFormatter()
            bootISO.timeZone = .current
            fields["uptime_seconds"] = .int(Int64(Date().timeIntervalSince(booted)))
            fields["booted_at"] = .string(bootISO.string(from: booted))
        }

        fields["screen_lock"] = .object(["locked": .bool(MacScreenLock.isLocked())])
        fields["person"] = MacPersonInput.presenceDetail

        // Battery: pmset -g batt → percent/charging/source.
        if let batt = runCommand("/usr/bin/pmset", ["-g", "batt"]), batt.status == 0 {
            let out = batt.stdout
            let source: JSONValue = firstCapturedString(in: out, pattern: #"Now drawing from '([^']+)'"#)
                .map { .string($0) } ?? .null
            let percent: JSONValue = firstCapturedInt(in: out, pattern: #"(\d+)%;"#)
                .map { .int(Int64($0)) } ?? .null
            var charging: JSONValue = .null
            let lower = out.lowercased()
            if lower.contains("charging") {
                charging = .bool(!lower.contains("discharging"))
            }
            fields["battery"] = .object([
                "percent": percent,
                "charging": charging,
                "source": source,
            ])
        } else {
            // Desktop Mac — no battery.
            fields["battery"] = .object([
                "percent": .null,
                "charging": .null,
                "source": .string("AC Power"),
            ])
        }

        if !failures.isEmpty && fields.isEmpty {
            return .object([
                "ok": .bool(false),
                "error": .string(failures.joined(separator: "; ")),
                "error_code": .string("system_info_partial"),
            ])
        }
        var result: [String: JSONValue] = ["ok": .bool(true), "status": .string(failures.isEmpty ? "ok" : "partial")]
        for (k, v) in fields { result[k] = v }
        if !failures.isEmpty {
            result["partial_failures"] = .array(failures.map { .string($0) })
            result["error_code"] = .string("system_info_partial")
        }
        return .object(result)
    }
}

private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

private struct CommandResult { let status: Int32; let stdout: String }

private func runCommand(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> CommandResult? {
    let result = runProcess(launchPath, args, timeout: timeout)
    guard result.launched, !result.timedOut, !result.captureReadFailed else { return nil }
    return CommandResult(status: result.status, stdout: result.stdout)
}

private func firstCapturedString(in text: String, pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges >= 2,
          m.range(at: 1).location != NSNotFound else { return nil }
    return ns.substring(with: m.range(at: 1))
}

private func firstCapturedInt(in text: String, pattern: String) -> Int? {
    guard let s = firstCapturedString(in: text, pattern: pattern) else { return nil }
    // Page counts tolerate a decimal point.
    if let i = Int(s) { return i }
    if let d = Double(s) { return Int(d) }
    return nil
}
