import SwiftUI
import StandingBots
import ProviderRouting

struct BotsEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let definition: BotDefinition?
    let save: (BotDefinition) throws -> Void
    @State private var name = ""
    @State private var brief = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var think = ""
    @State private var fast: Bool?
    @State private var when = ""
    @State private var hours = ""
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
    private var loadsProviders = true

    init(definition: BotDefinition?, save: @escaping (BotDefinition) throws -> Void) {
        self.definition = definition
        self.save = save
    }

    #if DEBUG
    init(snapshotProviders: [ProviderThenModelPicker.Provider], provider: String = "", model: String = "") {
        self.definition = nil
        self.save = { _ in }
        self.loadsProviders = false
        _providers = State(initialValue: snapshotProviders)
        _provider = State(initialValue: provider)
        _model = State(initialValue: model)
    }
    #endif
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
                Button("Cancel") { dismiss() }
                Button(definition == nil ? "Create" : "Save") {
                    do { try save(makeDefinition()); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 570)
        .task {
            guard loadsProviders else { return }
            populate()
            switch await ProviderSettingsRefreshAction.perform(appModel: appModel, refreshCatalog: false) {
            case .loaded(let snapshot):
                providers = snapshot.providers.map { account in
                    ProviderThenModelPicker.Provider(id: account.provider_id, name: account.provider_id == "codex" ? "OpenAI (subscription)" : account.display_name,
                        ready: account.auth_status.state == "ready", models: account.models.map {
                            ProviderThenModelPicker.Model(id: $0.id, name: $0.name,
                                supportedEfforts: $0.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"], supportsFast: $0.supports_fast)
                        })
                }
                await preselectFromChat()
            case .failed(let message): error = message
            }
        }
    }

    /// A new bot opens on Chat's routing — the same provider, model and Think
    /// the composer shows — so one connected account is enough to press Create.
    /// Each of the three stays a choice: this only fills them in.
    private func preselectFromChat() async {
        guard definition == nil, provider.isEmpty else { return }
        var chatModel = appModel.chatModel
        var chatThink = appModel.chatReasoningEffort
        if chatModel.isEmpty,
           let preference = try? await SwiftNativeProviderRouting().modelForSurface("chat") {
            chatModel = preference.model
            if chatThink.isEmpty { chatThink = preference.reasoningEffort }
        }
        let ready = providers.filter(\.ready)
        guard let account = ready.first(where: { $0.id == appModel.chatProvider && $0.models.contains { $0.id == chatModel } })
                ?? ready.first(where: { $0.models.contains { $0.id == chatModel } }),
              let match = account.models.first(where: { $0.id == chatModel })
        else { return }
        provider = account.id
        model = match.id
        let efforts = match.supportedEfforts ?? []
        think = efforts.contains(chatThink) ? chatThink : (efforts.first ?? "")
    }

    private var fields: some View {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name", text: $name)
                    editor("What to do", text: $brief, height: 110)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model").font(.subheadline)
                        Text("Starts from Chat's model; a bot runs on what you choose here.").font(.caption).foregroundStyle(.secondary)
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
                            }
                        }
                        if !provider.isEmpty, let caption = ProviderToolCapability.caption(providerID: provider) {
                            Text(caption).font(.caption).foregroundStyle(NativeAgentShell.secondary)
                        }
                        Divider().padding(.vertical, 4)
                            Picker("When", selection: $when) {
                                Text("Manual only").tag("")
                                ForEach(["Twice daily", "Daily", "Every N hours", "Custom", "On an event", "Manual only"], id: \.self) { Text($0).tag($0) }
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
        tokens = String(bot.budget.tokens); seconds = String(Int(bot.budget.seconds)); daily = bot.dailyTokenCeiling.map(String.init) ?? ""
        tell = bot.notificationCondition != nil; condition = bot.notificationCondition ?? ""
        if let trigger = bot.eventTrigger {
            eventSource = trigger.source; eventFilter = trigger.filter; eventKeyword = trigger.keyword ?? ""
        }
        switch bot.cadence {
        case .manual: when = bot.eventTrigger == nil ? "Manual only" : "On an event"
        case .interval(let value):
            when = value == 43200 ? "Twice daily" : value == 86400 ? "Daily" : "Every N hours"
            hours = String(value / 3600)
        case .cron(let expression, let timeZone): when = "Custom"; cron = expression; zone = timeZone
        }
    }
    private func makeDefinition() throws -> BotDefinition {
        // User, 2026-09-13: "Bots has no default model; Agent is supposed to pick
        // the model when she makes one." There is no blank-means-Chat any more:
        // the route, model and Think level are part of the bot.
        guard let selectedModel, providers.first(where: { $0.id == provider })?.ready == true,
              selectedModel.supportedEfforts?.contains(think) == true else {
            throw EditorError.message("Choose a connected account, a model it serves, and a supported Think level. A bot runs on the model you choose, not on Chat's.")
        }
        let tokenLimit = tokens.isEmpty ? BotRunLimits.maximumTokens : Int(tokens) ?? 0
        let timeLimit = seconds.isEmpty ? BotRunLimits.maximumSeconds : Double(seconds) ?? 0
        let dailyLimit = daily.isEmpty ? BotRunLimits.dailyTokens : Int(daily) ?? 0
        guard tokenLimit > 0, timeLimit.isFinite, timeLimit > 0, dailyLimit > 0 else {
            throw EditorError.message("Limits must be positive numbers, or blank for the defaults.")
        }
        let timing: BotCadence
        switch when {
        case "Manual only": timing = .manual
        case "Twice daily": timing = .interval(seconds: 43200)
        case "Daily": timing = .interval(seconds: 86400)
        case "Every N hours":
            guard let value = Double(hours), value.isFinite, value > 0 else { throw EditorError.message("Enter the number of hours.") }
            timing = .interval(seconds: value * 3600)
        case "Custom": timing = .cron(expression: cron, timeZone: zone)
        // An event-woken bot keeps no schedule: the event is the occurrence.
        case "On an event": timing = .manual
        default: timing = .manual
        }
        var trigger: BotEventTrigger?
        if when == "On an event" {
            let target = eventFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                throw EditorError.message(eventSource == .github
                    ? "Enter the repository as owner/repo." : "Enter the Slack channel ID.")
            }
            if eventSource == .slack, !BotEventTrigger.isChannelID(target) {
                throw EditorError.message("Enter the Slack channel ID, such as C0123ABCD. In Slack, open the channel, choose View channel details, and copy the ID at the bottom.")
            }
            trigger = BotEventTrigger(source: eventSource,
                filter: eventSource == .slack ? target.uppercased() : target,
                keyword: eventKeyword)
        }
        var bot = definition ?? BotDefinition(name: name, brief: brief, cadence: timing,
            budget: BotBudget(tokens: tokenLimit, seconds: timeLimit))
        bot.name = name; bot.brief = brief; bot.outputFormat = nil
        bot.provider = provider; bot.model = model; bot.reasoningEffort = think
        bot.fast = selectedModel.supportsFast == true ? (fast ?? false) : false
        bot.eventTrigger = trigger
        bot.cadence = timing; bot.budget = BotBudget(tokens: tokenLimit, seconds: timeLimit); bot.dailyTokenCeiling = dailyLimit
        if tell && condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw EditorError.message("Enter a condition or turn Tell me if off.") }
        bot.notificationCondition = tell ? condition : nil
        return bot
    }
    private enum EditorError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let text): text } }
    }
}
