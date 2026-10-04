import SwiftUI
import WidgetKit

@available(macOS 27, *)
private struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: NativeAgentWidgetSnapshot?
}

@available(macOS 27, *)
private struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: try? NativeAgentWidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: .now, snapshot: try? NativeAgentWidgetSnapshot.read())
        var entries = [entry]
        if let expiry = entry.snapshot?.activityExpiresAt, expiry > entry.date {
            entries.append(StatusEntry(date: expiry, snapshot: entry.snapshot))
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
            Text(entry.snapshot?.status(at: entry.date) ?? "Status unavailable. Open NativeAgent.")
                .font(NativeAgentFont.body)
                .lineLimit(3)
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
        .configurationDisplayName("Her status")
        .description("What she's doing and what's waiting on you.")
        .supportedFamilies([.systemSmall])
    }
}
