// Lane B (2026-09-02, ui-simplify): the value owners behind the Setup page.
// Pure mapping + a single settings key owner, kept out of the view so the
// switch wording and the storage it writes can be read in one place.

import Foundation

/// MOMENTS THE AGENT KEEPS — the one owner of the moments-lane switch key.
///
/// `AdaptiveMemoryPromoter` lives in a module that must never read
/// UserDefaults, so it receives this as an injected closure at launch
/// (AppDelegate+Launch). Default ON: the lane shipped on, and an install that
/// never opens Setup keeps the behavior it already had.
enum MomentsLaneSetting {
    static let defaultsKey = "momentsLaneEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
