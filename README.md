# SkipLiveActivities

Cross-platform Live Activities for [Skip](https://skip.dev) apps. SkipLiveActivities gives you one Swift API that starts, updates and ends a Live Activity on iOS and a Live Update on Android 16.

- **iOS**: [ActivityKit](https://developer.apple.com/documentation/activitykit) Live Activities (lock screen and Dynamic Island)
- **Android 16 (API 36)**: a promoted ongoing notification using [`Notification.ProgressStyle`](https://developer.android.com/reference/android/app/Notification.ProgressStyle)
- **Older Android**: a plain ongoing notification with a progress bar and chronometer

The lock screen and Dynamic Island UI cannot be shared between the platforms. The library therefore uses a fixed template (title, subtitle, status chip, progress, countdown, stages) that renders on both sides. `SkipLiveActivitiesUI` ships the iOS template views for your widget extension.

## Installation

Add `skip-live-activities` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/skiptools/skip-live-activities.git", "0.0.0"..<"2.0.0")
]
```

And add it to your Skip target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "SkipLiveActivities", package: "skip-live-activities")
])
```

## Prerequisites

### iOS

1. Add `NSSupportsLiveActivities` to your app's `Info.plist`:

   ```xml
   <key>NSSupportsLiveActivities</key>
   <true/>
   ```

2. Add a **Widget Extension** target (Skip does not build extensions, so this is done once in Xcode) and link the `SkipLiveActivitiesUI` product to it. The whole extension is:

   ```swift
   import SwiftUI
   import WidgetKit
   import SkipLiveActivitiesUI

   @main
   struct MyWidgets: WidgetBundle {
       var body: some Widget {
           SkipLiveActivityWidget()
       }
   }
   ```

   The `Showcase/` app contains a working extension target to copy from.

### Android

Add the permissions to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<!-- API 36.1: lets the notification be promoted. Older systems ignore it. -->
<uses-permission android:name="android.permission.POST_PROMOTED_NOTIFICATIONS" />
```

`SkipLiveActivities.requestPermission()` asks for `POST_NOTIFICATIONS` at runtime. Promotion is a separate switch that only the user can change in system settings.

> **Android version note.** `Notification.ProgressStyle`, `setShortCriticalText` and `canPostPromotedNotifications()` are API 36. The request to be *promoted* (`setRequestPromotedOngoing` and `POST_PROMOTED_NOTIFICATIONS`) arrived in API 36.1 (Android 16 QPR2). The library sets the documented extra directly, so one build runs on every version: where promotion is unavailable you get the same notification without the promoted chip.

## Usage

```swift
import SkipLiveActivities

let manager = LiveActivityManager.shared

// permission (iOS has no prompt; Android asks for POST_NOTIFICATIONS)
let permission = await manager.requestPermission()
guard permission == .authorized || permission == .authorizedWithoutPromotion else { return }

// start: you choose the id, for example a workout id
let start = Date()
let content = LiveActivityContent(
    title: "Spinning",
    subtitle: "Studio 2",
    status: "45:00",                    // short chip text, about 7 characters
    symbol: "figure.indoor.cycle",
    timer: LiveActivityTimer(start: start, end: start.addingTimeInterval(45 * 60)),
    stages: [
        LiveActivityStage(title: "Warm-up", weight: 0.2),
        LiveActivityStage(title: "Main set", weight: 0.6),
        LiveActivityStage(title: "Cool-down", weight: 0.2)
    ],
    deepLink: URL(string: "myapp://workout/42"))
try await manager.start(id: "workout-42", content: content, staleDate: start.addingTimeInterval(60 * 60))

// update (for example app-driven progress instead of a timer)
try await manager.update(id: "workout-42", content: LiveActivityContent(title: "Spinning", progress: 0.5))

// end, keeping a final summary on screen
await manager.end(id: "workout-42",
                  finalContent: LiveActivityContent(title: "Workout done", status: "Done"),
                  dismissal: .afterSystemDefault)

// inspect and observe
let running = manager.activeIDs()
for await state in manager.observe(id: "workout-42") { /* active, stale, ended, dismissed */ }
```

### Content fields

| Field | iOS | Android 16+ | Android below 16 |
| --- | --- | --- | --- |
| `title`, `subtitle` | Lock screen text | Title and text | Title and text |
| `status` | Compact Dynamic Island trailing text | `setShortCriticalText` status chip | Not shown |
| `symbol` | SF Symbol | Drawable named like the symbol (`.` becomes `_`), else the app icon | Same |
| `timer` | `Text(timerInterval:)` and `ProgressView(timerInterval:)`, no updates needed | Chronometer (count down or up) and progress at post time | Chronometer |
| `progress` | `ProgressView(value:)` | `ProgressStyle` tracker | `setProgress` bar |
| `stages` | Stage labels | `ProgressStyle` segments | Not shown |
| `deepLink` | `widgetURL` | Tap opens the link in your app | Same |
| `staleDate` | Marks the activity stale | `setTimeoutAfter` removes it | Same |

### Permissions

`permissionStatus()` returns `.authorized`, `.authorizedWithoutPromotion` (Android: notifications work, but promotion is off or the OS is older than 36.1, so the plain notification is shown), `.notDetermined` (Android: not asked yet) or `.denied`. Callers never branch on the Android API level.

## What cannot be shared

- **The iOS UI** is SwiftUI inside a WidgetKit extension, which the app owner adds once (see Prerequisites).
- **Custom Android layouts.** Promoted notifications cannot use custom views, so the look differs per platform.
- **Typed attributes.** v1 uses one fixed `LiveActivityAttributes` type. Apps that need their own can use the iOS escape hatch below.
- **Starting from the background on iOS** needs a push-to-start from your backend (iOS 17.2+); see [Starting from a push](#starting-from-a-push). Android starts from a push data message the same way.
- **Lifetime.** iOS ends an activity after about 8 hours, with up to 4 more on the lock screen. Android has no such limit.

## Platform-specific access

### iOS: push tokens

```swift
#if !SKIP
LiveActivityManager.shared.requestsPushTokens = true   // before start(); needs the push entitlement
for await token in LiveActivityManager.shared.pushToken(for: "workout-42") {
    // send `token` to your backend to update the activity through APNs
}
#endif
```

`LiveActivityAttributes` (`ActivityAttributes` with `ContentState = LiveActivityContent`) is public on iOS, so you can use ActivityKit directly alongside the manager.

### Starting from a push

Both platforms can be started and updated by your backend while the app is closed. The mechanism differs, so the library gives you one hook per platform.

**iOS 17.2+: push-to-start token.** Send the token to your backend. With it the backend starts an activity through APNs (`event: "start"`, `attributes-type: "LiveActivityAttributes"`, `attributes: {"id": ...}`, and the encoded `LiveActivityContent` as `content-state`).

```swift
#if !SKIP
if #available(iOS 17.2, *) {
    // keep this running from launch: the system can issue a new token at any time
    for await token in LiveActivityManager.shared.pushToStartTokens() {
        // send `token` to your backend
    }
}
#endif
```

`pushToStartToken` returns the current token, or `nil` until the system issued one.

**Android: FCM data message.** A data message starts the app process even when it is closed. Hand its data to the library from your `FirebaseMessagingService.onMessageReceived` (or from Swift, where you receive the data):

```swift
if await LiveActivityManager.shared.handleRemoteMessage(message.data) { return }
```

It returns `true` for Live Activity messages (the others are left to you). The data values are strings:

| Key | Meaning |
| --- | --- |
| `type` | `live_activity` (required) |
| `action` | `show` starts the activity or updates it when running (default), `end` removes it |
| `id` | Activity id (required, the same ids as `start(id:...)`) |
| `title` | Main line (required for `show`) |
| `subtitle`, `status`, `symbol` | Optional, empty means none |
| `timerStart`, `timerEnd` | Epoch milliseconds |
| `countsDown` | `false` counts up, anything else counts down |
| `progress` | 0 to 1, ignored when a timer is set |
| `deepLink` | Opened when the user taps the activity |
| `staleDate` | Epoch milliseconds when the notification removes itself |

Send the message with high priority so it is delivered while the device is idle. The notification permission must already be granted: the library never prompts from a background message.

### Android

The notification uses the channel `skip.liveactivities` and the activity id as notification tag, so you can inspect it with `NotificationManager.getActiveNotifications()`.

## Showcase

`Showcase/` is a small Skip app that starts, advances and ends a 2 minute workout activity. It includes the iOS widget extension and the Android manifest permissions. Launch the iOS app with `-autostart` to start the activity without tapping.

## Building

This project is a Swift Package Manager module that uses the [Skip](https://skip.dev) plugin to build the package for both iOS and Android.

## Testing

The module can be tested using the standard `swift test` command or by running the test target for the macOS destination in Xcode, which will run the Swift tests as well as the transpiled Kotlin JUnit tests in the Robolectric Android simulation environment.

Parity testing can be performed with `skip test`, which will output a table of the test results for both platforms.

The iOS-only code (ActivityKit and the widget views) is not compiled by `swift test` on macOS. Build it with:

```bash
xcodebuild build -scheme SkipLiveActivitiesUI -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation
```

## License

Apache License 2.0. See [LICENSE.txt](LICENSE.txt).
