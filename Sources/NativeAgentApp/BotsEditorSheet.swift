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
    @State private var output = ""
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
            case .failed(let message): error = message
            }
        }
    }

    private var fields: some View {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name", text: $name)
                    editor("What to do", text: $brief, height: 65)
                    editor("Desired output (optional)", text: $output, height: 45)
                    Text("Leave desired output blank for an ordinary reply.").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model").font(.subheadline)
                        Text("Leave blank to use the same model and Think level as Chat.").font(.caption).foregroundStyle(.secondary)
                        ModelChoiceRow {
                            Menu {
                                ForEach(providers.filter(\.ready)) { account in
                                    Button(account.name) {
                                        provider = account.id; model = ""; think = ""; fast = nil
                                    }
                                }
                            } label: {
                                let account = providers.first { $0.id == provider }
                                Text(provider.isEmpty ? "Same as Chat" : (account?.name ?? provider))
                                    .lineLimit(1)
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
                            }.disabled(provider.isEmpty)
                        } think: {
                            Picker("Think", selection: $think) {
                                Text("Choose").tag("")
                                ForEach(selectedModel?.supportedEfforts ?? [], id: \.self) { Text($0.capitalized).tag($0) }
                            }.disabled(selectedModel == nil)
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
                                ForEach(["Twice daily", "Daily", "Every N hours", "Custom", "Manual only"], id: \.self) { Text($0).tag($0) }
                            }
                        if when == "Every N hours" { field("Hours between runs", text: $hours) }
                        if when == "Custom" {
                            field("Schedule (cron)", text: $cron)
                            field("Time zone", text: $zone)
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
        name = bot.name; brief = bot.brief; output = bot.outputFormat ?? ""
        provider = bot.provider ?? ""; model = bot.model ?? ""; think = bot.reasoningEffort ?? ""; fast = bot.fast
        tokens = String(bot.budget.tokens); seconds = String(Int(bot.budget.seconds)); daily = bot.dailyTokenCeiling.map(String.init) ?? ""
        tell = bot.notificationCondition != nil; condition = bot.notificationCondition ?? ""
        switch bot.cadence {
        case .manual: when = "Manual only"
        case .interval(let value):
            when = value == 43200 ? "Twice daily" : value == 86400 ? "Daily" : "Every N hours"
            hours = String(value / 3600)
        case .cron(let expression, let timeZone): when = "Custom"; cron = expression; zone = timeZone
        }
    }
    private func makeDefinition() throws -> BotDefinition {
        // A bot with nothing chosen here runs on the same route as Chat.
        let choseModel = !provider.isEmpty || !model.isEmpty || !think.isEmpty
        if choseModel {
            guard let selectedModel, providers.first(where: { $0.id == provider })?.ready == true,
                  selectedModel.supportedEfforts?.contains(think) == true else {
                throw EditorError.message("Choose a connected model and supported Think level, or leave all three blank to use Chat's.")
            }
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
        default: timing = .manual
        }
        var bot = definition ?? BotDefinition(name: name, brief: brief, cadence: timing,
            budget: BotBudget(tokens: tokenLimit, seconds: timeLimit))
        bot.name = name; bot.brief = brief; bot.outputFormat = output.isEmpty ? nil : output
        bot.provider = choseModel ? provider : nil; bot.model = choseModel ? model : nil; bot.reasoningEffort = choseModel ? think : nil
        bot.fast = choseModel ? (selectedModel?.supportsFast == true ? (fast ?? false) : false) : nil
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
