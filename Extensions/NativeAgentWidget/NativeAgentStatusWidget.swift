import NativeAgentShared
import SwiftUI
import WidgetKit

@available(macOS 27, *)
private struct StatusEntry: TimelineEntry {
    let date: Date
    enum Content: Sendable {
        case placeholder
        case snapshot(NativeAgentWidgetSnapshot)
        case unavailable(String)
    }
    let content: Content
    var snapshot: NativeAgentWidgetSnapshot? {
        if case .snapshot(let snapshot) = content { return snapshot }
        return nil
    }
    var status: String {
        switch content {
        case .placeholder: "Agent status"
        case .snapshot(let snapshot): snapshot.status(at: date)
        case .unavailable(let cause): "Status unavailable: \(cause). Open NativeAgent to repair or republish its widget snapshot."
        }
    }
    static func read(at date: Date = .now) -> Self {
        do { return Self(date: date, content: .snapshot(try NativeAgentWidgetSnapshot.read())) }
        catch { return Self(date: date, content: .unavailable(error.localizedDescription)) }
    }
}

@available(macOS 27, *)
private struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, content: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry.read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry.read()
        var entries = [entry]
        if let expiry = entry.snapshot?.activityExpiresAt, expiry > entry.date {
            entries.append(StatusEntry(date: expiry, content: entry.content))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

@available(macOS 27, *)
private struct StatusView: View {
    let entry: StatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Label(entry.snapshot?.name ?? "NativeAgent", systemImage: "sparkle")
                .font(NativeAgentFont.section)
                .foregroundStyle(NativeAgentBrand.accentDeep)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(entry.status)
                .font(NativeAgentFont.body)
                .lineLimit(nil)
            if let count = entry.snapshot?.waitingCount {
                Text("\(count) waiting on you")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let date = entry.snapshot?.updatedAt {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.thinMaterial, for: .widget)
        .privacySensitive()
    }
}

@main
@available(macOS 27, *)
struct NativeAgentStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NativeAgentWidgetSnapshot.kind, provider: StatusProvider()) { entry in
            StatusView(entry: entry)
        }
        .configurationDisplayName("Agent status")
        .description("What the agent is doing and what's waiting on you.")
        .supportedFamilies([.systemSmall])
    }
}
