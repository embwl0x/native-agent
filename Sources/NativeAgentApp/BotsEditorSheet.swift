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
    private struct Draft: Codable, Equatable {
        var name = ""
        var brief = ""
        var provider = ""
        var model = ""
        var modelPinned = false
        var think = ""
        var fast: Bool?
        var when = "Manual only"
        var hours = ""
        /// The clock time for Daily, Weekdays and Weekly; only its hour and minute count.
        var time = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0)).addingTimeInterval(9 * 3600)
        /// Cron day-of-week, 0 is Sunday.
        var weekday = 1
        /// The When section as it opened; saved untouched, the bot keeps its exact timing.
        var loadedTiming: [String]?
        var cron = ""
        var zone = ""
        var tokens = ""
        var seconds = ""
        var daily = ""
        var eventSource = BotEventSource.github
        var eventFilter = ""
        var eventKeyword = ""
        var tell = false
        var condition = ""
        var clockText: String {
            let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
            return String(format: "%02d:%02d", clock.hour ?? 9, clock.minute ?? 0)
        }
        var timingKey: [String] { [when, hours, cron, zone, String(weekday), clockText] }
    }

    private var draftSubject: String { "bot/\(definition?.id.uuidString ?? "new")" }
    @State private var seed: Draft?
    private var draft: Draft {
        get { appModel.editDraft(draftSubject, seed: seed ?? Draft()) }
        nonmutating set { appModel.setEditDraft(newValue, for: draftSubject, baseline: seed ?? Draft()) }
    }
    private var draftBinding: Binding<Draft> { Binding(get: { draft }, set: { draft = $0 }) }
    @State private var followingModel: String?
    @State private var providers: [ProviderThenModelPicker.Provider] = []
    @State private var error: String?
    @State private var saving = false

    init(definition: BotDefinition?, save: @escaping (BotDefinition) async throws -> Void) {
        self.definition = definition
        self.save = save
    }

    private var selectedModel: ProviderThenModelPicker.Model? {
        providers.first { $0.id == draft.provider }?.models.first { $0.id == draft.model }
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
                Button("Cancel") { appModel.clearEditDraft(draftSubject); dismiss() }.disabled(saving)
                Button(definition == nil ? "Create" : "Save") {
                    saving = true
                    let subject = draftSubject
                    let submitted = draft
                    let submission = Result { try makeDefinition() }
                    Task {
                        defer { saving = false }
                        do {
                            let saved = try submission.get()
                            try await save(saved)
                            appModel.acceptEditDraft(subject, submitted: submitted, saved: initialDraft(saved))
                            dismiss()
                        }
                        catch { self.error = BotsShelfView.problem(error, action: "save that helper") }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 570)
        .houseSheet()
        .interactiveDismissDisabled(saving)
        .onAppear { if seed == nil { seed = initialDraft(definition) } }
        .task {
            switch await appModel.engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            case .loaded(let snapshot):
                providers = snapshot.providers.map { account in
                    ProviderThenModelPicker.Provider(id: account.provider_id, name: account.provider_id == "codex" ? "OpenAI (subscription)" : account.display_name,
                        ready: account.auth_status.eligible, models: account.models.map {
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
                    field("Name", text: draftBinding.name)
                    editor("What to do", text: draftBinding.brief, height: 110)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model").font(.subheadline)
                        Picker("Model selection", selection: draftBinding.modelPinned) {
                            Text("Follow Providers").tag(false)
                            Text("Pin a model").tag(true)
                        }
                        if draft.modelPinned == false {
                            Text("follows Providers (\(followingModel ?? "unavailable"))").font(.caption).foregroundStyle(.secondary)
                        } else {
                        ModelChoiceRow {
                            // A Picker, not a Menu: a pop-up button hands its
                            // options to accessibility, so a driver can set the
                            // account without a menu being popped first.
                            Picker("Provider", selection: Binding(get: { draft.provider }, set: {
                                draft.provider = $0; draft.model = ""; draft.think = ""; draft.fast = nil
                            })) {
                                Text("Choose an account").tag("")
                                if !draft.provider.isEmpty, providers.first(where: { $0.id == draft.provider }) == nil {
                                    Text(draft.provider + " · unavailable").tag(draft.provider)
                                }
                                ForEach(providers.filter(\.ready)) { Text($0.name).tag($0.id) }
                            }.accessibilityLabel("Provider")
                        } model: {
                            Picker("Model", selection: Binding(get: { draft.model }, set: {
                                draft.model = $0; draft.think = ""; draft.fast = nil
                            })) {
                                Text("Choose").tag("")
                                if !draft.model.isEmpty, selectedModel == nil {
                                    Text(draft.model + " · unavailable").tag(draft.model)
                                }
                                ForEach(providers.first { $0.id == draft.provider }?.models ?? []) { Text($0.name).tag($0.id) }
                            }.disabled(draft.provider.isEmpty).accessibilityLabel("Model")
                        } think: {
                            Picker("Think", selection: draftBinding.think) {
                                Text("Choose").tag("")
                                ForEach(selectedModel?.supportedEfforts ?? [], id: \.self) { Text($0.capitalized).tag($0) }
                            }.disabled(selectedModel == nil).accessibilityLabel("Think")
                        } fast: {
                            if selectedModel?.supportsFast == true {
                                Toggle("Fast", isOn: Binding(get: { draft.fast ?? false }, set: { draft.fast = $0 }))
                                    .toggleStyle(.switch)
                                    .hazeTinted()
                            }
                        }
                        if !draft.provider.isEmpty, let caption = ProviderToolCapability.caption(providerID: draft.provider) {
                            Text(caption).font(.caption).foregroundStyle(NativeAgentShell.secondary)
                        }
                        }
                        Divider().padding(.vertical, 4)
                            Picker("When", selection: draftBinding.when) {
                                ForEach(["Manual only", "Daily", "Weekdays", "Weekly", "Every N hours", "On an event"], id: \.self) { Text($0).tag($0) }
                                // A cron saved elsewhere still opens and saves as it was.
                                if draft.when == "Custom" { Text("Custom (cron)").tag("Custom") }
                            }
                        if ["Daily", "Weekdays", "Weekly"].contains(draft.when) {
                            HStack(spacing: 12) {
                                if draft.when == "Weekly" {
                                    Picker("On", selection: draftBinding.weekday) {
                                        ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                                    }.fixedSize()
                                }
                                DatePicker("At", selection: draftBinding.time, displayedComponents: .hourAndMinute).fixedSize()
                            }
                        }
                        if draft.when == "Every N hours" { field("Hours between runs", text: draftBinding.hours) }
                        if draft.when == "Custom" {
                            field("Schedule (cron)", text: draftBinding.cron)
                            field("Time zone", text: draftBinding.zone)
                        }
                        if draft.when == "On an event" {
                            Picker("Event", selection: draftBinding.eventSource) {
                                Text("GitHub issue or pull request").tag(BotEventSource.github)
                                Text("Slack message").tag(BotEventSource.slack)
                            }
                            field(draft.eventSource == .github ? "Repository (owner/repo)" : "Channel ID", text: draftBinding.eventFilter)
                            field("Keyword (optional)", text: draftBinding.eventKeyword)
                            Text(draft.eventSource == .github
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
                                field("Output tokens per run", text: draftBinding.tokens)
                                field("Seconds per run", text: draftBinding.seconds)
                                field("Daily token reservation", text: draftBinding.daily)
                            }
                            Text("Choose execution limits before saving. Output limits do not include hidden reasoning or guarantee billed usage.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Tell me if", isOn: draftBinding.tell)
                            if draft.tell { field("Condition", text: draftBinding.condition) }
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
    private func initialDraft(_ definition: BotDefinition?) -> Draft {
        var draft = Draft()
        guard let bot = definition else { return draft }
        // One place describes the job. A definition written when "Desired
        // output" was its own field still reads: its output instructions are
        // shown after the brief and are stored back as one brief on save.
        draft.name = bot.name
        draft.brief = [bot.brief, bot.outputFormat ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        draft.provider = bot.provider ?? ""; draft.model = bot.model ?? ""; draft.think = bot.reasoningEffort ?? ""; draft.fast = bot.fast
        draft.modelPinned = bot.modelPinned ?? false
        draft.tokens = String(bot.budget.tokens); draft.seconds = String(bot.budget.seconds); draft.daily = bot.dailyTokenCeiling.map(String.init) ?? ""
        draft.tell = bot.notificationCondition != nil; draft.condition = bot.notificationCondition ?? ""
        if let trigger = bot.eventTrigger {
            draft.eventSource = trigger.source; draft.eventFilter = trigger.filter; draft.eventKeyword = trigger.keyword ?? ""
        }
        switch bot.cadence {
        case .manual: draft.when = bot.eventTrigger == nil ? "Manual only" : "On an event"
        case .interval(let value):
            // A rolling day or week from before clock times opens as one, at
            // its next run's time and day (09:00 when it has none).
            draft.when = value == 86400 ? "Daily" : value == 604800 ? "Weekly" : "Every N hours"
            draft.hours = String(value / 3600)
            if draft.when != "Every N hours",
               let next = try? BotRunnerScheduler.scheduledDates(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())[bot.id] {
                draft.time = next; draft.weekday = Calendar.current.component(.weekday, from: next) - 1
            }
        case .cron(let expression, let timeZone):
            draft.when = "Custom"; draft.cron = expression; draft.zone = timeZone ?? ""
            let parts = expression.split(separator: " ").map(String.init)
            if parts.count == 5, parts[2] == "*", parts[3] == "*",
               let minute = Int(parts[0]), let hour = Int(parts[1]), (0...59).contains(minute), (0...23).contains(hour),
               let clock = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: draft.time) {
                if parts[4] == "*" { draft.when = "Daily" } else if parts[4] == "1-5" { draft.when = "Weekdays" }
                else if let day = Int(parts[4]), (0...6).contains(day) { draft.when = "Weekly"; draft.weekday = day }
                if draft.when != "Custom" { draft.time = clock }
            }
        }
        draft.loadedTiming = draft.timingKey
        return draft
    }
    private func makeDefinition() throws -> BotDefinition {
        let current = try definition.map {
            try BotDefinitionStore(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()).get($0.id)
        }
        let draft = try appModel.mergingEditDraft(draftSubject, edited: draft, into: initialDraft(current))
        let selectedModel = providers.first { $0.id == draft.provider }?.models.first { $0.id == draft.model }
        return try BotDefinitionStore.editorDefinition(current, name: draft.name, brief: draft.brief,
            provider: draft.provider, model: draft.model, think: draft.think, modelPinned: draft.modelPinned,
            providerReady: providers.first(where: { $0.id == draft.provider })?.ready == true,
            supportedEfforts: selectedModel?.supportedEfforts, supportsFast: selectedModel?.supportsFast == true,
            fast: draft.fast, tokens: draft.tokens, seconds: draft.seconds, daily: draft.daily, when: draft.when, hours: draft.hours,
            cron: draft.cron, zone: draft.zone, weekday: draft.weekday, clockText: draft.clockText, timingUnchanged: draft.timingKey == draft.loadedTiming,
            eventSource: draft.eventSource, eventFilter: draft.eventFilter, eventKeyword: draft.eventKeyword, tell: draft.tell, condition: draft.condition)
    }
}
