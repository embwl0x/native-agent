import SwiftUI
import StandingBots
import ProviderRouting
import ChatOrchestration
import PersistenceCore

struct BotsEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let definition: BotDefinition?
    let save: (BotDefinition) async throws -> Void
    @State private var name = ""
    @State private var brief = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var modelPinned = false
    @State private var followingModel: String?
    @State private var think = ""
    @State private var fast: Bool?
    @State private var when = "Manual only"
    @State private var hours = ""
    /// The clock time for Daily, Weekdays and Weekly; only its hour and minute count.
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    /// Cron day-of-week, 0 is Sunday.
    @State private var weekday = 1
    /// The When section as it opened; saved untouched, the bot keeps its exact timing.
    @State private var loadedTiming: [String]?
    @State private var cron = ""
    @State private var zone = ""
    @State private var tokens = ""
    @State private var seconds = ""
    @State private var daily = ""
    @State private var eventSource = BotEventSource.github
    @State private var eventFilter = ""
    @State private var eventKeyword = ""
    @State private var tell = false
    @State private var condition = ""
    @State private var providers: [ProviderThenModelPicker.Provider] = []
    @State private var error: String?
    @State private var saving = false

    init(definition: BotDefinition?, save: @escaping (BotDefinition) async throws -> Void) {
        self.definition = definition
        self.save = save
    }

    private var selectedModel: ProviderThenModelPicker.Model? {
        providers.first { $0.id == provider }?.models.first { $0.id == model }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(definition == nil ? "New bot" : "Edit bot").font(.title2.weight(.semibold))
            ViewThatFits(in: .vertical) {
                fields.fixedSize(horizontal: false, vertical: true)
                ScrollView { fields }
            }
            .frame(maxHeight: 600)
            .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.subheadline).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(saving)
                Button(definition == nil ? "Create" : "Save") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(makeDefinition()); dismiss() }
                        catch { self.error = BotsShelfView.problem(error, action: "save that helper") }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 570)
        .houseSheet()
        .interactiveDismissDisabled(saving)
        .task {
            populate()
            switch await appModel.engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            case .loaded(let snapshot):
                providers = snapshot.providers.map { account in
                    ProviderThenModelPicker.Provider(id: account.provider_id, name: account.provider_id == "codex" ? "OpenAI (subscription)" : account.display_name,
                        ready: account.auth_status.state == "ready", models: account.models.map {
                            ProviderThenModelPicker.Model(id: $0.id, name: $0.name,
                                supportedEfforts: $0.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"], supportsFast: $0.supports_fast)
                        })
                }
                followingModel = try? await SwiftNativeProviderRouting(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()).modelForSurface("chat").model
            case .failed(let message): error = message
            }
        }
    }

    private var fields: some View {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name", text: $name)
                    editor("What to do", text: $brief, height: 110)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model").font(.subheadline)
                        Picker("Model selection", selection: $modelPinned) {
                            Text("Follow Providers").tag(false)
                            Text("Pin a model").tag(true)
                        }
                        if modelPinned == false {
                            Text("follows Providers (\(followingModel ?? "unavailable"))").font(.caption).foregroundStyle(.secondary)
                        } else {
                        ModelChoiceRow {
                            // A Picker, not a Menu: a pop-up button hands its
                            // options to accessibility, so a driver can set the
                            // account without a menu being popped first.
                            Picker("Provider", selection: Binding(get: { provider }, set: {
                                provider = $0; model = ""; think = ""; fast = nil
                            })) {
                                Text("Choose an account").tag("")
                                if !provider.isEmpty, providers.first(where: { $0.id == provider }) == nil {
                                    Text(provider + " · unavailable").tag(provider)
                                }
                                ForEach(providers.filter(\.ready)) { Text($0.name).tag($0.id) }
                            }.accessibilityLabel("Provider")
                        } model: {
                            Picker("Model", selection: Binding(get: { model }, set: {
                                model = $0; think = ""; fast = nil
                            })) {
                                Text("Choose").tag("")
                                if !model.isEmpty, selectedModel == nil {
                                    Text(model + " · unavailable").tag(model)
                                }
                                ForEach(providers.first { $0.id == provider }?.models ?? []) { Text($0.name).tag($0.id) }
                            }.disabled(provider.isEmpty).accessibilityLabel("Model")
                        } think: {
                            Picker("Think", selection: $think) {
                                Text("Choose").tag("")
                                ForEach(selectedModel?.supportedEfforts ?? [], id: \.self) { Text($0.capitalized).tag($0) }
                            }.disabled(selectedModel == nil).accessibilityLabel("Think")
                        } fast: {
                            if selectedModel?.supportsFast == true {
                                Toggle("Fast", isOn: Binding(get: { fast ?? false }, set: { fast = $0 }))
                                    .toggleStyle(.switch)
                                    .hazeTinted()
                            }
                        }
                        if !provider.isEmpty, let caption = ProviderToolCapability.caption(providerID: provider) {
                            Text(caption).font(.caption).foregroundStyle(NativeAgentShell.secondary)
                        }
                        }
                        Divider().padding(.vertical, 4)
                            Picker("When", selection: $when) {
                                ForEach(["Manual only", "Daily", "Weekdays", "Weekly", "Every N hours", "On an event"], id: \.self) { Text($0).tag($0) }
                                // A cron saved elsewhere still opens and saves as it was.
                                if when == "Custom" { Text("Custom (cron)").tag("Custom") }
                            }
                        if ["Daily", "Weekdays", "Weekly"].contains(when) {
                            HStack(spacing: 12) {
                                if when == "Weekly" {
                                    Picker("On", selection: $weekday) {
                                        ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                                    }.fixedSize()
                                }
                                DatePicker("At", selection: $time, displayedComponents: .hourAndMinute).fixedSize()
                            }
                        }
                        if when == "Every N hours" { field("Hours between runs", text: $hours) }
                        if when == "Custom" {
                            field("Schedule (cron)", text: $cron)
                            field("Time zone", text: $zone)
                        }
                        if when == "On an event" {
                            Picker("Event", selection: $eventSource) {
                                Text("GitHub issue or pull request").tag(BotEventSource.github)
                                Text("Slack message").tag(BotEventSource.slack)
                            }
                            field(eventSource == .github ? "Repository (owner/repo)" : "Channel ID", text: $eventFilter)
                            field("Keyword (optional)", text: $eventKeyword)
                            Text(eventSource == .github
                                ? "A new issue or pull request on that repository wakes the bot. GitHub events arrive with the connector's refresh."
                                : "A message in that channel wakes the bot. Slack delivers a channel ID, so paste the ID rather than the name: in Slack, open the channel, choose View channel details, and copy the ID at the bottom. Events arrive on the channels the Slack connector already receives.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Autonomy off holds the event instead of running it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Optional controls") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                field("Output tokens per run", text: $tokens)
                                field("Seconds per run", text: $seconds)
                                field("Daily token reservation", text: $daily)
                            }
                            Text("Choose execution limits before saving. Output limits do not include hidden reasoning or guarantee billed usage.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Tell me if", isOn: $tell)
                            if tell { field("Condition", text: $condition) }
                        }.padding(.top, 8)
                    }
                }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline)
            TextField("", text: text).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
    private func editor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline)
            TextEditor(text: text).font(.body).frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel(label)
        }
    }
    private func populate() {
        guard let bot = definition else { return }
        // One place describes the job. A definition written when "Desired
        // output" was its own field still reads: its output instructions are
        // shown after the brief and are stored back as one brief on save.
        name = bot.name
        brief = [bot.brief, bot.outputFormat ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        provider = bot.provider ?? ""; model = bot.model ?? ""; think = bot.reasoningEffort ?? ""; fast = bot.fast
        modelPinned = bot.modelPinned ?? false
        tokens = String(bot.budget.tokens); seconds = String(bot.budget.seconds); daily = bot.dailyTokenCeiling.map(String.init) ?? ""
        tell = bot.notificationCondition != nil; condition = bot.notificationCondition ?? ""
        if let trigger = bot.eventTrigger {
            eventSource = trigger.source; eventFilter = trigger.filter; eventKeyword = trigger.keyword ?? ""
        }
        switch bot.cadence {
        case .manual: when = bot.eventTrigger == nil ? "Manual only" : "On an event"
        case .interval(let value):
            // A rolling day or week from before clock times opens as one, at
            // its next run's time and day (09:00 when it has none).
            when = value == 86400 ? "Daily" : value == 604800 ? "Weekly" : "Every N hours"
            hours = String(value / 3600)
            if when != "Every N hours",
               let next = try? BotRunnerScheduler.scheduledDates(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())[bot.id] {
                time = next; weekday = Calendar.current.component(.weekday, from: next) - 1
            }
        case .cron(let expression, let timeZone):
            when = "Custom"; cron = expression; zone = timeZone ?? ""
            let parts = expression.split(separator: " ").map(String.init)
            if parts.count == 5, parts[2] == "*", parts[3] == "*",
               let minute = Int(parts[0]), let hour = Int(parts[1]), (0...59).contains(minute), (0...23).contains(hour),
               let clock = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) {
                if parts[4] == "*" { when = "Daily" } else if parts[4] == "1-5" { when = "Weekdays" }
                else if let day = Int(parts[4]), (0...6).contains(day) { when = "Weekly"; weekday = day }
                if when != "Custom" { time = clock }
            }
        }
        loadedTiming = timingKey
    }
    private var clockText: String {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", clock.hour ?? 9, clock.minute ?? 0)
    }
    private var timingKey: [String] { [when, hours, cron, zone, String(weekday), clockText] }
    private func makeDefinition() throws -> BotDefinition {
        try BotDefinitionStore.editorDefinition(definition, name: name, brief: brief,
            provider: provider, model: model, think: think, modelPinned: modelPinned,
            providerReady: providers.first(where: { $0.id == provider })?.ready == true,
            supportedEfforts: selectedModel?.supportedEfforts, supportsFast: selectedModel?.supportsFast == true,
            fast: fast, tokens: tokens, seconds: seconds, daily: daily, when: when, hours: hours,
            cron: cron, zone: zone, weekday: weekday, clockText: clockText, timingUnchanged: timingKey == loadedTiming,
            eventSource: eventSource, eventFilter: eventFilter, eventKeyword: eventKeyword, tell: tell, condition: condition)
    }
}
