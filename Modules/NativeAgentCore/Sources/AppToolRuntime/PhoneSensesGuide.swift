import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `PhoneSensesGuide.swift` | Phone senses guide on the existing pairing page: reads the one phone evidence owner, exact per-organ setup and missing-state instructions for any agent/person |
enum PhoneSensesGuide {
    static func read(dataRoot: URL) throws -> JSONValue {
        // A damaged history throws through the door's ordinary read failure. It
        // must never become an all-off or setup-complete reading.
        let lines = try PhoneSenseHistory.setupLines(dataRoot)
        return .object(["status": .string("ok"), "page": .string("pairing"), "item": .string("phone-senses"),
            "title": .string("Phone senses"),
            "content": .array(lines.map(JSONValue.string)), "guide": .string(steps)])
    }

    static let steps = """
    Guide for any agent helping its person. These are optional. Read the setup lines above first: they say what the phone last reported, not what silence proves. If setup has not arrived, ask the person to open the paired NativeAgent phone app with the Mac awake and NativeAgent running. Check again once; if still absent, inspect pairing rather than guessing permissions. An off switch, denied permission, unsupported device or no saved place each has its own remedy. A grant is the person's choice.

    In NativeAgent on iPhone, open the Settings tab (or More → Settings). Places and Phone senses are below the Mac settings. Every sense starts off; each switch explains its summary, paired iCloud delivery and use by the AI provider selected on the Mac. Turning it off stops new observations and shares disabled; previously accepted evidence stays historical. Setup state is shared to help with guidance, including when a sense is off. After a change in iPhone Settings, reopen NativeAgent to refresh setup. iOS may defer a background wake indefinitely; foreground is the direct way to request a reading. There is no promise of continuous sensing.

    Places: stand at the place. NativeAgent → Settings → Places → Place name → Home, Work or Custom (enter Place name) → Save this location. Turn on the saved place's own switch. No Home place is assumed or created for someone. Allow location when asked, then iPhone Settings → Apps → NativeAgent → Location → Always; turn Precise Location on. If global location is off: Settings → Privacy & Security → Location Services → on. Enabled place names and transition times leave the phone; a requested phone settings inspection also shares saved names and switches, including disabled places. Coordinates stay on the phone. 'No place added yet' means save one, not that the person is away.

    The person may ask their agent to change an existing phone switch. setting.get with setting phone.settings reads the current phone-owned directory; its ids use setting.get and setting.set. The phone app must be open. Enabling a sense or saved place asks on the existing phone request sheet before any permission acquisition; disabling uses the same owner without a card. No answer remains unconfirmed after the bounded wait. New current-location capture and place deletion remain the phone's Places actions.

    Motion: NativeAgent → Settings → Phone senses → Motion → on; allow Motion & Fitness when asked. To repair denial: iPhone Settings → Privacy & Security → Motion & Fitness → Fitness Tracking on and NativeAgent on (also exposed under Settings → Apps → NativeAgent → Motion & Fitness). Unsupported hardware, including the simulator, cannot produce activity; permission alone does not fix that. Running, walking, cycling, driving and stationary flags can overlap. Report them with confidence and activity time; low confidence is an estimate, never enough to establish absence or sleep.

    Focus: NativeAgent → Settings → Phone senses → Focus → on; allow Focus Status. In iPhone Settings → Focus → Focus Status, turn Share Focus Status on and enable the desired Focus; allow NativeAgent's Focus access under Settings → Apps → NativeAgent. iOS exposes a Boolean, not the Focus name. Nil means unavailable, never off.

    Sleep clues: NativeAgent → Settings → Phone senses → Sleep clues → on. No extra iOS permission. Shares charging and whether it is night on the phone. Probably asleep is an inference requiring fresh stationary Motion and no positive Mac-here input; it is never a HealthKit sleep reading.

    Battery: NativeAgent → Settings → Phone senses → Battery → on. No extra iOS permission. Shares percentage on a wake or battery notification while the app can run; an unavailable battery reading stays unknown.

    Headphones: NativeAgent → Settings → Phone senses → Headphones → on. No Bluetooth or microphone permission is requested for this read. Shares this app's current audio route without device names. A Bluetooth route could be a speaker or car; another route is not proof of disconnected headphones. It never activates an audio session to sense.

    Connection: NativeAgent → Settings → Phone senses → Connection → on. No extra iOS permission. Shares Wi-Fi/cellular/wired/other or an explicitly unavailable path, without SSID, carrier, IP address or network names. Missing path callback becomes unknown after five seconds. A satisfied path is not proof of Internet reachability or Mac delivery.

    Apple Music: NativeAgent → Settings → Phone senses → Apple Music → on; allow Media & Apple Music. To repair denial: iPhone Settings → Privacy & Security → Media & Apple Music → NativeAgent on (also exposed under Settings → Apps → NativeAgent). Open Music and play a song, then reopen NativeAgent. Shares the Music app's reported playback state and available title/artist; other music apps are outside this API. Missing now-playing metadata does not prove nothing is playing. No playback commands, audio or history are sent.

    Photos today: NativeAgent → Settings → Phone senses → Photos today → on. Choose Limited Access or Full Access when Photos asks. To repair/change selection: iPhone Settings → Apps → NativeAgent → Photos → Limited Access → Edit Selected Photos, or Full Access. Limited Access is enough; never ask for Full Access just to remove a warning. Shares only the number of visible non-hidden image assets dated today and the phone-local date/time zone, including imported/synced images. Limited Access is always labelled partial, including zero. This is not proof of photos captured here; no images, filenames, identifiers, locations or individual asset dates leave the phone. If the count does not answer in five seconds it is unknown; a late result cannot replace that query's outcome.

    Updates use launch/foreground, enabled Places events, significant location changes only with an existing Always grant, and existing background pushes. None of these senses keep the app running. No reading means unobserved; observations older than fifteen minutes are historical, with current state unknown. Setup is last reported too; reopen the app to refresh changed permissions.

    Excluded in this transport: daily pedometer fitness totals and HealthKit sleep/workouts. The CloudKit-to-model route has not established a compliant boundary for health/fitness information under App Store 5.1.3; a summary alone does not establish that. WeatherKit is not offered: this app has no WeatherKit signing entitlement or required Apple Weather attribution surface. No disabled controls pretend those sources exist.
    """
}
