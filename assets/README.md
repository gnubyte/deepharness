# assets

`screenshot.png` is referenced from the top of the project README. `logo/` holds the app icon
(`AppIcon.icns`), the in-app logo (`logo.png`), and the source `logo.svg`; `bundle.sh` copies the
first two into the app bundle.

## Regenerating the screenshot

Programmatic capture does work, as long as the process holding the Screen Recording permission is the
one calling it. Capture the app's own window by id rather than the whole screen:

```swift
// shot.swift — swift shot.swift assets/screenshot.png
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "shot.png"
guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for info in infos {
    guard (info[kCGWindowOwnerName as String] as? String) == "DSH",
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 400,
          let number = info[kCGWindowNumber as String] as? UInt32 else { continue }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), target]
    try capture.run(); capture.waitUntilExit()
    exit(capture.terminationStatus)
}
exit(1)
```

`-l <windowid>` captures just that window, `-o` drops the drop shadow, `-x` silences the shutter.

What does *not* work, and why: `cacheDisplay` and `CALayer.render(in:)` come back blank because
SwiftUI content is drawn by the compositor rather than into layer backing stores, and `ImageRenderer`
refuses `NavigationSplitView` offscreen. If `screencapture` returns an empty image, the calling
process has not been granted Screen Recording — grant it in System Settings ▸ Privacy & Security.

The manual route still works too: focus the window, press ⇧⌘4 then Space, click the window, and move
the file from your Desktop.
