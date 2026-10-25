/* NativeAgent ability
{"id":"telegram-model-picker","kind":"ability","version":1,
 "reach":{"capabilities":[]},"face":{"page":"telegram"},
 "record":{"description":"Interpret Telegram model requests and draw checked model menus. Native Telegram authenticates callbacks and commits compatible routing choices.","actions":[],"inputSchema":{"type":"object"}}}
*/
function run(input) {
    const menu = input.menu;
    const normalized = raw => {
        const text = raw.trim().toLowerCase();
        if (["xai","xai_oauth_direct","xai-oauth","grok-oauth","x-ai-oauth","xai-grok-oauth"].includes(text)) return "xai_oauth_direct";
        if (["moonshot","kimi"].includes(text)) return "moonshot";
        return text;
    };
    const matches = (a,b) => a.trim().toLowerCase() === b.trim().toLowerCase();
    const label = (id,name) => name && name.trim() && name.trim() !== id.trim() ? name.trim() + " [" + id.trim() + "]" : input.op === "command" ? id : id.trim();
    const all = menu ? menu.providers.flatMap(p => p.models.map(m => ({providerId:p.id,providerDisplayName:p.displayName,modelId:m.id,modelName:m.name,markedCurrent:m.isCurrent,isCurrent:m.isCurrent || m.id === menu.currentModel && normalized(p.id) === normalized(menu.currentProvider)}))) : [];
    const choices = [];
    const seen = new Set();
    for (const m of all) {
        const key = m.providerId + "\0" + m.modelId;
        if (!seen.has(key) && (choices.length < 30 || m.markedCurrent)) { seen.add(key); choices.push(m); }
    }
    const providerName = () => {
        const family = raw => {
            const text = normalized(raw);
            if (["anthropic","anthropic_oauth_direct","anthropic_mcp"].includes(text)) return "anthropic";
            if (["openai","openai_oauth_direct"].includes(text)) return "openai";
            return text;
        };
        const identity = input.op === "command" ? normalized : family;
        const current = menu.providers.find(p => identity(p.id) === identity(menu.currentProvider));
        return current ? current.displayName : menu.currentProvider;
    };
    const button = (text,key) => [{text,callback_data:key}];
    if (input.op === "command") {
        const args = input.args;
        let selection = null;
        const first = args.length ? args[0].trim() : "";
        let badIndex = false;
        if (first) {
            if (menu) {
                if (/^[+-]?\d+$/.test(first) && BigInt(first) >= -9223372036854775808n && BigInt(first) <= 9223372036854775807n) {
                    const index = Number(first);
                    selection = index >= 1 && index <= choices.length ? choices[index-1] : null;
                    badIndex = selection === null;
                } else {
                    let provider = menu.providers.find(p => matches(first,p.id) || matches(first,p.displayName));
                    if (!provider) {
                        const candidates = menu.providers.filter(p => normalized(first) === normalized(p.id));
                        if (candidates.length === 1) provider = candidates[0];
                    }
                    if (provider) {
                        const raw = args.slice(1).join(" ");
                        const model = args.length === 1 ? provider.models[0] : provider.models.find(m => matches(raw,m.id) || matches(raw,m.name));
                        if (model) selection = {providerId:provider.id,modelId:model.id};
                        else if (args.length > 1) selection = {providerId:provider.id,modelId:raw};
                        else badIndex = true;
                    } else {
                        const candidates = all.filter(m => matches(args.join(" "),m.modelId) || matches(args.join(" "),m.modelName || ""));
                        if (candidates.length === 1) selection = candidates[0];
                    }
                }
            }
            if (!selection && !badIndex) selection = {providerId:null,modelId:first};
        }
        if (selection) return {selection:{providerId:selection.providerId,modelId:selection.modelId},reply:"Chat model set to " + selection.modelId + (selection.providerId === null ? "" : " @ " + selection.providerId) + ". Providers → Chat now uses this model for Mac, iPhone, Telegram, and Slack."};
        if (args.length) return {reply:"Unknown model selection. Send /model to see available choices."};
        if (menu === null) {
            if (input.current.status !== "available") throw new Error("Telegram routing is unavailable.");
            return {reply:"Surface: telegram\nModel: " + input.current.model + "\nProvider: " + input.current.provider};
        }
        if (!choices.length) return {reply:"Surface: " + menu.surface + "\nModel: " + menu.currentModel + "\nProvider: " + menu.currentProvider};
        const lines = ["Telegram model: " + label(menu.currentModel,null),"Provider: " + providerName() + " (" + menu.currentProvider + ")","","Choose with /model <number>:"];
        choices.forEach((m,i) => lines.push((i+1) + ". " + (m.providerDisplayName || m.providerId || "Provider") + ": " + label(m.modelId,m.modelName) + (m.isCurrent ? " (current)" : "")));
        if (all.length > choices.length) lines.push("+ " + (all.length-choices.length) + " more; use /model <provider> <model-id>");
        lines.push("","Direct: /model <provider> <model-id>");
        return {reply:lines.join("\n")};
    }
    if (menu === null) throw new Error("Telegram model menu is unavailable.");
    if (input.op === "providers") return {text:"Telegram model\nCurrent: " + label(menu.currentModel,null) + "\nProvider: " + providerName() + " (" + menu.currentProvider + ")\n\nChoose a provider:",markup:{inline_keyboard:menu.providers.map(p => button(p.displayName + (p.isCurrent ? " (current)" : ""),p.callback))}};
    const provider = menu.providers.find(p => p.id === input.providerId);
    if (!provider) throw new Error("That provider is no longer available.");
    if (input.op === "models") {
        const current = all.find(m => m.modelId === menu.currentModel);
        const rows = provider.models.slice(0,40).map(m => button((m.name.trim() ? m.name : m.id) + (m.isCurrent ? " (current)" : ""),m.callback));
        rows.push(button("Back to providers",input.providersCallback));
        return {text:"Telegram model\nProvider: " + provider.displayName + " (" + provider.id + ")\nCurrent: " + label(menu.currentModel,current ? current.modelName : null) + "\n\nChoose a model:",markup:{inline_keyboard:rows}};
    }
    if (input.op === "selected") {
        const model = provider.models.find(m => m.id === input.modelId);
        if (!model) throw new Error("That model is no longer available.");
        return {text:"Chat model set\nProvider: " + provider.displayName + " (" + provider.id + ")\nModel: " + label(model.id,model.name) + "\n\nProviders → Chat now uses this model for Mac, iPhone, Telegram, and Slack.",markup:{inline_keyboard:[button("Choose another model",provider.callback),button("Change provider",input.providersCallback)]}};
    }
    throw new Error("Unknown Telegram model picker operation.");
}
