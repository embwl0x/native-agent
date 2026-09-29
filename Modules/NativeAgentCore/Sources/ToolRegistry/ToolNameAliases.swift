import Foundation

// MARK: - Tool-name aliases

/// The ONE table of alternate spellings for a tool name (2026-09-26). Trust,
/// dispatch, receipts, traces and the chat pill all resolve a requested name
/// here, so an alias can never be judged as one tool and executed as another
/// (`browser_navigate` used to be `browser.navigate` to the Trust Center and
/// `browser.open_url` to the app dispatcher).
///
/// Every canonical name is a real, model-visible tool name. An alias is never
/// a tool of its own: it adds nothing to a catalog or schema list, and the
/// model is only ever offered the canonical spelling. This is not the wire
/// encoder — `ProviderToolNameMap` still owns provider-safe names at ingress.
public enum ToolNameAliases {
    /// canonical name → the spellings that mean it. Both are matched trimmed
    /// and case-insensitively.
    static let aliasesByCanonical: [String: [String]] = [
        "mobile_notify": [
            "mobile.notify", "iphone.notify", "iphone_notify", "ios.notify", "ios_notify",
            "apns.notify", "apns_notify", "push.notify", "push_notify",
        ],
        "mac_notify": ["mac.notify", "native.notify", "native_notify"],
        "market_quote": ["markets_quote"],
        "mac_spotlight_search": ["spotlight_search"],
        "github_list_notifications": ["github_notifications"],
        // The Trust Center speaks these tools' connector-action ids; a model
        // that read one called the dotted form (2026-08-22).
        "mac_look": ["mac.look"],
        "mac_view": ["mac.view"],
        "browser.status": ["browser_status", "browser.get_status", "browser_get_status"],
        "browser.open_url": [
            "browser_open_url", "browser.open", "browser_open",
            "browser.navigate", "browser_navigate", "navigate_browser",
        ],
        "browser.read_text": [
            "browser_read_text", "browser.text", "browser_text", "browser_get_text",
            "browser.dom_text", "browser_dom_text",
        ],
        "browser.read_links": ["browser_read_links", "browser.links", "browser_links"],
        "browser.screenshot": [
            "browser_screenshot", "browser.capture_screenshot", "browser_capture_screenshot",
        ],
        "browser.chrome_setup": ["browser_chrome_setup"],
        "browser.chrome_status": ["browser_chrome_status"],
        "doctor_status": ["doctor.status"],
        "telegram_status": ["telegram.status"],
        "reflex_review": ["reflex.review"],
        "app_page_read": ["app.page_read", "app_read_page"],
        "app_page_screenshot": ["app.page_screenshot", "app_screenshot"],
        "app_settings_list": ["app.settings_list", "app_list_settings"],
        "app_setting_set": ["app.setting_set", "app_set_setting"],
        "interaction_act": ["app.interaction_act", "card_act", "answer_card"],
    ].merging(Dictionary(uniqueKeysWithValues: [
        "acquire", "renew", "navigate", "snapshot", "click", "fill", "type", "select",
        "keypress", "set_checked", "double_click", "drag", "wait", "scroll", "release",
    ].map { verb in
        ("browser.chrome_\(verb)", ["browser_chrome_\(verb)", "chrome.\(verb)", "chrome_\(verb)"])
    })) { $0 + $1 }

    /// alias → canonical. Built with `uniqueKeysWithValues` on purpose: one
    /// spelling naming two tools is the bug this table exists to end.
    public static let table: [String: String] = Dictionary(uniqueKeysWithValues:
        aliasesByCanonical.flatMap { canonical, aliases in aliases.map { ($0, canonical) } })

    /// The canonical name for `name`. A name `known` already knows stays as
    /// it is. A table alias resolves to its tool. Anything else comes back
    /// exactly as given — an alias, not a fuzzy match.
    public static func canonical(
        _ name: String,
        known: (String) -> Bool = { _ in false }
    ) -> String {
        if known(name) { return name }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return table[key] ?? (aliasesByCanonical[key] != nil ? key : name)
    }
}
