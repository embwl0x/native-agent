# AppKit accessibility leaks during sharing, page teardown, and scrolling

Prepared September 14, 2026. Local report draft; not submitted to Apple or any other service.

## September 14, 2026 — broader UI allocation ownership follow-up

The earlier sharing-window-only result below applies to retained Chat/Bots navigation. It does **not** describe all remaining leaks across the UI. A fresh stacklogged installed-app process on the same macOS version reproduced additional framework allocation paths when navigating other pages. These results precede the final Providers layout change and are ownership evidence, not a final-build performance comparison.

The same process was sampled cumulatively at four boundaries:

| Boundary | Leaked objects | Leaked bytes | Root allocation families |
| --- | ---: | ---: | --- |
| Fresh app, one settled Chat accessibility read | 0 | 0 | None detected at this boundary |
| Trust navigation, down/up scroll, return to Chat | 210 | 10,176 | 206 observer NSArray roots; one scroll-logger CFData root |
| Subsequent Providers roundtrip | 303 | 14,720 | 296 observer NSArray roots; the same one CFData root |
| Remaining root pages and return to Chat, no additional scrolling | 936 | 45,344 | 916 observer NSArray roots; one CFData root; three toolbar accessibility-action roots |

Counts include children, so object totals exceed root counts. Allocation logging is confirmed by symbolized multiline stacks. The reports still identify the signed process as restricted, which limits readable memory contents; the allocation stacks nevertheless identify the measured allocation paths. These short samples do not prove zero leaks elsewhere or establish a general leak rate.

All 206 initial Trust NSArray roots end in `_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification` and `NSArray initWithArray:range:copyItems:`. Their callers distinguish 106 SwiftUI accessibility-node destruction roots, 94 native view/control removal roots, four selective-sharing-window roots, and two segmented-control window-attachment roots. The later page samples add roots in this same cleanup family. Thus the larger page teardown effect must not be described as only the small sharing-window leak.

Two other allocation families now have specific framework stacks:

```text
Scroll gesture:
SwiftUI HostingScrollView.scrollWheel
AppKit NSScrollingAnimator / NSScrollingBehaviorSingleThreadedVBL
AppKit _NSScrollingPerfLogger.beginScrollGestureWithScrollView
AppKit NSScrollView._tokenForPerfLogger
AppKit NSAccessibilityCreateRemoteToken
HIServices _AXUIElementRemoteTokenCreate
CoreFoundation __CFDataInit

Toolbar accessibility action query:
HIServices _XCopyActionNames / _AXXMIGCopyActionNames
AppKit CopyActionNames
AppKit NSAccessibilityEntryPointActionNames
AppKit NSToolbarItemViewer.accessibilityCustomActions
libobjc _objc_rootAllocWithZone
```

The Trust scroll created one CFData root with its storage (112 bytes). Further page navigation did not increase that family. The final pass added three NSAccessibilityCustomAction roots through AppKit's toolbar action-query implementation. NativeAgent's only frames in these allocation stacks are its main-entry frames; no NativeAgent-owned allocating function or retained application object was identified. This is evidence about these samples, not proof that every possible application leak is framework-owned. Apple has not confirmed the diagnosis.

The preceding uninstrumented whole-page run reported 5,427 objects / 184,224 bytes, including 5,314 NSArray roots, 26 CFData roots, and eight custom-action roots. That report had no allocation stacks: the newer reproduction supports ownership of the families it reproduced, but cannot retroactively assign every older generic array or data object to the same owner. Different workloads and process lifetimes also prevent treating those totals as a before/after improvement measurement.

App-side implications: stable identity at selected navigation boundaries can reduce teardown, as demonstrated for Chat/Bots. Accessibility containment and lazy section layout address traversal and measurement costs; they do not repair framework observer cleanup. Retaining every page would introduce persistent memory and hidden-work costs and is not established here as a safe general fix. No documented cleanup hook was identified for AppKit's internal observer arrays, scrolling remote token, or toolbar action objects. The capture-client lifetime hypothesis below applies only to sharing-window transitions, not the additional teardown and scrolling paths.

Local source reports: `/tmp/nativeagent-whole-ui-stack-baseline.txt`, `/tmp/nativeagent-whole-ui-stack-trust.txt`, `/tmp/nativeagent-whole-ui-stack-providers.txt`, and `/tmp/nativeagent-whole-ui-stack-all-pages.txt`. Only sanitized framework stack excerpts are included here; no conversation contents, memory contents, or identifying process paths are reproduced.

## Environment

- macOS 26.6.2 (25G83), Apple silicon.
- Allocation stacks collected using `MallocStackLogging=1` and the system `leaks` tool.
- NativeAgent version 0.4.13-dev.cc124d47.dirty; the installed build includes uncommitted UI changes.
- Independent reproduction app imports only SwiftUI and AppKit, with no NativeAgent runtime, stores, network clients, or conversation data.
- Computer inspection used Codex's native computer-control tool, which causes selective window-sharing transitions. The exact internal capture-session implementation of that tool was not inspected.

## Problem

Repeated inspection/navigation leaves unreachable NSArray objects and AXObserverCookie children allocated by AppKit while it closes its local selective-sharing window. This is separate from a larger text-control teardown leak: retaining the transcript and Bots view hierarchies stopped new text-control roots at that navigation boundary, but the sharing-window roots continued to increase.

## Minimal reproduction

Use the standalone SwiftUI source `ChatUIWorkaroundProbe.swift` accompanying this report. Its window contains 100 short selectable text rows, a transcript visibility toggle, an optional NSTextView renderer, and a retention toggle. No private APIs are used.

1. Build the standalone source as a macOS application and launch it with `MallocStackLogging=1`.
2. Set **Native text view** off and **Retain views** on. Show the transcript and allow the window to settle.
3. Inspect the app through the native computer-control tool, then collect a baseline with `leaks <probe-pid>`.
4. Hide and show the transcript three times using **Toggle transcript**, reading accessibility state after each action. Retention keeps the same text views mounted; hidden content disables hit testing and accessibility exposure.
5. Collect another `leaks <probe-pid>` report. Compare allocation-stack groups, not just process footprint or the aggregate number of leaks.

The recorded standalone baseline came after earlier renderer/remount experiments in the same process. Its absolute total therefore includes existing text-control and other roots. The before/after delta and stable text-root groups are the relevant evidence; a clean-launch reproduction should be included in an upstream confirmation.

## Observed results

| Run | Before | After | Interpretation |
| --- | --- | --- | --- |
| Independent retained-view probe, three hide/show cycles | 711 leaked objects / 39,232 bytes | 726 / 40,048 bytes | +15 objects / 816 bytes. Selective-sharing NSArray root group grew from 7 to 13. Existing text teardown groups of 200, 100, and 100 roots did not increase. |
| Installed NativeAgent, three inspected Chat/Bots navigation cycles after warmup | 3 leaked objects / 160 bytes | 18 / 1,024 bytes | +15 objects / 864 bytes. Final report contains 10 NSArray roots, all in the selective-sharing-window stack; baseline had 2 roots in that same stack. No text-control teardown root group appeared. |

These are short, observed runs. They establish the allocation path and growth in the tested workflow, not a general leak rate, a claim about every macOS version, or proof that all other app memory is leak-free.

## Relevant allocation stack

Unrelated app entry frames, addresses, paths, process identifiers, and memory contents are omitted.

```text
SkyLight: CGSDatagramReadStream::dispatchMainQueueDatagrams
SkyLight: notify_datagram_handler
AppKit: _windowSelectiveSharingStateChangedNotification
AppKit: ___windowSelectiveSharingStateChangedNotification_block_invoke
AppKit: -[NSWindow _setIsSelectivelyShared:]
AppKit: -[NSWindow _destroyLocalWindowSharingWindowController]
AppKit: -[NSLocalWindowSharingWindowController close]
AppKit: -[NSWindow _close]
AppKit: -[NSWindow _finishClosingWindow]
AppKit: -[NSWindow _doOrderWindow:]
AppKit: -[NSWindow _reallyDoOrderWindow:]
AppKit: -[NSWindow _reallyDoOrderWindowOutRelativeTo:]
AppKit: _NSAccessibilityUnregisterUniqueIdForUIElementAndSendDestroyedNotification
AppKit: _NSAccessibilityRemoveAllObserversAndSendDestroyedNotification
CoreFoundation: -[NSArray initWithArray:range:copyItems:]
CoreFoundation: __NSArrayI_new
CoreFoundation: __CFAllocateObject
libobjc: class_createInstance
malloc: _calloc
```

## Expected result

After the system sharing window closes and its accessibility observers are removed, the observer array and associated cookies should be released. Repeated sharing-state transitions should not accumulate unreachable observer objects.

## Application-side investigation

NativeAgent source contains no calls to `sharingType`, window-sharing request/transfer APIs, `SCContentSharingPicker`, or persistent `SCStream` construction. Its screen capture entry points use one-shot `SCScreenshotManager.captureImage`. The independent probe contains no screen capture code at all.

The public NSWindow interface exposes sharing requests, transfers, and a read-only SharePlay-session indicator. Neither the inspected SDK headers nor the public documentation expose ownership or cleanup of `NSLocalWindowSharingWindowController` or the internal observer arrays. No supported app-side cleanup remedy was identified. Calling private selectors, manually releasing framework-owned memory, posting false destruction notifications, or disabling accessibility would not be a safe fix.

Changing `NSWindow.sharingType` to `.none` is not an appropriate workaround. Current Apple documentation identifies it as a legacy value and warns against using it to prevent capture; SDK comments also warn that it can prevent participation in system services.

## Capture-client hypothesis — unverified

A capture client that repeatedly starts and ends selective window capture may cause more system sharing-window creation/closure than a supported persistent capture session. Reusing such a session could potentially reduce these transitions. This is a hypothesis for the capture-tool owner to investigate, not a verified fix and not a NativeAgent UI change. A comparison would need to preserve the same accessibility and capture functionality while measuring the specific allocation-stack delta.

## Primary references

- [NSWindow public window-sharing APIs](https://developer.apple.com/documentation/appkit/nswindow)
- [Request sharing of a window](https://developer.apple.com/documentation/appkit/nswindow/requestsharingofwindow%28_%3Acompletionhandler%3A%29)
- [NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)
- [Apple guidance for diagnosing memory use and leaks](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use)
- [Feedback Assistant guidance and reproducing sample projects](https://developer.apple.com/feedback-assistant/)

The symbol and ownership conclusion is an inference from the measured stacks, standalone reproduction, source search, and public API review. Apple has not confirmed the diagnosis or provided a bug identifier.
