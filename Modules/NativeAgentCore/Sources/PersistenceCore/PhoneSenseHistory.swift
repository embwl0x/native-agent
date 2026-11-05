import Foundation
import NativeAgentShared

// Blueprint: | `PhoneSenseHistory.swift` | Bounded phone evidence preserves each source and first movement. |
public enum PhoneSenseHistory {
    public static let freshFor: TimeInterval = 15 * 60
    public static let changed = Notification.Name("NativeAgent.phonePresenceEvidence")
    public static func url(_ root: URL) -> URL { root.appendingPathComponent("mobile/sense-events.json") }
    public static func read(_ root: URL) throws -> [PhoneSenseEvent] {
        let file = url(root)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let events = try JSONDecoder().decode([PhoneSenseEvent].self, from: Data(contentsOf: file))
        guard events.count <= 64, events.allSatisfy(\.isValid) else {
            throw PersistenceCoreError.ioFailure("Phone sense history contains invalid evidence; preserve and repair \(file.path).")
        }
        return events
    }
    public static func observationLine(_ event: PhoneSenseEvent, now: Date = Date()) -> String {
        let fresh = (0...freshFor).contains(now.timeIntervalSince(event.timestamp))
        return "phone \(event.source.title) \(event.value)"
            + (event.confidence.map { " (\($0) confidence)" } ?? "")
            + (event.activityStartedAt.map { "; activity began \($0.formatted(.iso8601))" } ?? "")
            + (event.summary.map { "; \($0)" } ?? "")
            + " at \(event.timestamp.formatted(.iso8601)) (phone \(event.source.title)"
            + (event.source == .focus && event.value == "on" ? ", kind not shared by iOS" : "")
            + (event.source == .battery && Int(event.value) != nil ? ", percent" : "")
            + (fresh ? "" : ", current unknown") + ")"
    }
    public static func setupLines(_ root: URL, now: Date = Date()) throws -> [String] {
        let events = try read(root)
        return PhoneSenseEvent.Source.allCases.flatMap { source -> [String] in
            let setup = events.filter { $0.source == source && $0.isSetup }.max { $0.timestamp < $1.timestamp }
            var lines = [setup.map {
                "\(source.title): \($0.setup!.line); phone setup at \($0.timestamp.formatted(.iso8601))"
                    + ((0...freshFor).contains(now.timeIntervalSince($0.timestamp)) ? "" : "; last reported setup, current setup unconfirmed")
            } ?? """
                \(source.title): setup not reported yet; open the paired phone app with the Mac connected. Missing evidence does not mean off or \
                permission denied.
                """]
            if let reading = events.filter({ $0.source == source && !$0.isSetup }).max(by: { $0.timestamp < $1.timestamp }) {
                lines.append(observationLine(reading, now: now))
            } else if source != .places { lines.append(
                "\(source.title): no observation received; use its setup steps below, then open the phone app. Silence is not a verdict.") }
            return lines
        }
    }
    public static func record(_ event: PhoneSenseEvent, dataRoot: URL, afterPersonInput: Date?) throws {
        var events = try read(dataRoot)
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        // Keep every source's latest evidence even through a flood of another source.
        let latest = PhoneSenseEvent.Source.allCases.flatMap { source in
            [false, true].compactMap { setup in
                events.filter { $0.source == source && $0.isSetup == setup }.max { $0.timestamp < $1.timestamp }
            }
        }
        // Preserve the current absence's first movement through the cap. The Mac input owner supplies its current fact; no copied presence latch.
        let firstMovement = events.filter { observation in
            observation.isMovement
                && (afterPersonInput.map { observation.timestamp > $0 } ?? true)
        }.min { $0.timestamp < $1.timestamp }
        var kept = latest
        if let firstMovement, !kept.contains(where: { $0.id == firstMovement.id }) { kept.append(firstMovement) }
        let ids = Set(kept.map(\.id))
        events = Array(events.filter { !ids.contains($0.id) }.sorted { $0.timestamp < $1.timestamp }.suffix(64 - kept.count)) + kept
        let file = url(dataRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: file, options: .atomic)
        NotificationCenter.default.post(name: changed, object: dataRoot,
            userInfo: ["source": event.source.rawValue, "timestamp": event.timestamp])
    }
}
