# Retained native host leak check — September 14, 2026

Same instrumented installed-app process, 96931, with allocation stacks enabled. These are cumulative counts within this process, including children of root allocations.

| Boundary | Leaked objects | Bytes | Roots and allocation stack |
| --- | ---: | ---: | --- |
| Initial baseline | 3 | 176 | 2 NSArray roots, selective-sharing window cleanup |
| Chat/Bots warmed | 8 | 464 | 4 NSArray roots, same stack |
| After three more Chat/Bots cycles | 26 | 1,504 | 13 NSArray roots, same stack |

Three-cycle delta from warm baseline: **18 objects / 1,040 bytes**, comprising **nine additional NSArray roots** and their observer-cookie children. Every root is allocated through:

```text
SkyLight window sharing-state notification
AppKit NSWindow._setIsSelectivelyShared
AppKit NSWindow._destroyLocalWindowSharingWindowController
AppKit NSLocalWindowSharingWindowController.close
AppKit accessibility unregister / destruction notification
AppKit _NSAccessibilityRemoveAllObserversAndSendDestroyedNotification
CoreFoundation NSArray.initWithArray
```

No new text-control teardown, SwiftUI AccessibilityNode teardown, native retained-host, or application-owned allocation root appeared in these samples. This supports stable Chat/Bots view lifetime across the tested navigation cycles. It does not establish that the whole UI is leak-free, and the sharing-window leak remains observable.

Source reports:

- `/tmp/nativeagent-retained-final-leaks-baseline.txt`
- `/tmp/nativeagent-retained-final-leaks-warm.txt`
- `/tmp/nativeagent-retained-final-leaks-cycles.txt`

The signed process report restricts readable memory contents, but provides symbolized allocation stacks. Framework attribution above is based on those stacks, not generic NSArray type. Apple has not confirmed the diagnosis. Other-page teardown is a separate known path and requires its own measured boundary.

## Subsequent Trust roundtrip

After visiting Trust, scrolling down/up, and returning to Chat, the same process reports **164 leaked objects / 8,288 bytes**. This is **138 objects / 6,784 bytes** more than the preceding Chat/Bots-cycle boundary. This measurement predates the subsequent fix for repeated loading when Trust's lazy sections reappear; it does not validate that upcoming change.

| Allocation path | Roots | Objects including children | Bytes |
| --- | ---: | ---: | ---: |
| View/control and accessibility-node teardown through AppKit observer cleanup | 126 | 129 | 6,256 |
| Selective-sharing window observer cleanup | 18 | 33 | 1,888 |
| AppKit scroll-performance logger accessibility remote token (CFData) | 1 | 2 | 144 |
| **Total** | **145** | **164** | **8,288** |

Relative to the preceding boundary, the sharing group adds five roots / seven objects / 384 bytes. The 126 teardown roots and one scrolling-token root are additional families for this process, matching framework paths previously reproduced in the wider UI audit. No new allocation path involving an application allocator or retained-host object appears; NativeAgent frames only enter the main event loop. This confirms that retaining Chat/Bots does not remove ordinary Trust teardown leaks. It does not establish whether the later Trust load-lifetime fix will reduce teardown frequency.

Source: `/tmp/nativeagent-retained-final-leaks-trust.txt`.
