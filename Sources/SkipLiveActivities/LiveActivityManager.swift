#if !SKIP_BRIDGE
import Foundation
import OSLog
import SkipKit

#if !SKIP
#if os(iOS)
import ActivityKit
#endif
#else
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
#endif

/// Starts, updates and ends Live Activities (iOS) and Live Updates (Android 16) from one Swift API.
///
/// Use `LiveActivityManager.shared`. The caller picks the activity `id`
/// (for example a workout id), so the library keeps no mapping table.
public final class LiveActivityManager {
    /// Shared singleton instance
    public nonisolated(unsafe) static let shared = LiveActivityManager()

    private init() {
    }

    #if !SKIP
    /// iOS only: ask ActivityKit for a push token when starting an activity, so a backend can update it.
    /// Requires the push notification entitlement. Set before calling `start`.
    public nonisolated(unsafe) var requestsPushTokens = false
    #endif

    // MARK: - Capability and permission

    /// Whether this device can show Live Activities at all.
    ///
    /// iOS: iOS 16.2 or later. Android: always `true`, since a plain ongoing notification is the floor.
    public var isSupported: Bool {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *) { return true }
        #endif
        return false
        #else
        return true
        #endif
    }

    /// The current permission state. Does not prompt.
    public func permissionStatus() -> LiveActivityPermission {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled ? LiveActivityPermission.authorized : LiveActivityPermission.denied
        }
        #endif
        return LiveActivityPermission.denied
        #else
        return androidPermissionStatus()
        #endif
    }

    /// Requests permission where the platform has a prompt.
    ///
    /// iOS has no prompt: the user toggles Live Activities in Settings, so this returns the current state.
    /// Android asks for `POST_NOTIFICATIONS` (Android 13+). The separate promoted-notification switch can
    /// only be changed by the user in system settings; `.authorizedWithoutPromotion` reports that case.
    public func requestPermission() async -> LiveActivityPermission {
        #if !SKIP
        return permissionStatus()
        #else
        if Build.VERSION.SDK_INT >= 33 && PermissionManager.queryPermission(.POST_NOTIFICATIONS) != PermissionAuthorization.authorized {
            _ = await PermissionManager.requestPermission(.POST_NOTIFICATIONS)
        }
        return androidPermissionStatus()
        #endif
    }

    // MARK: - Lifecycle

    /// Starts an activity.
    /// - Parameters:
    ///   - id: Caller-chosen identifier, unique among running activities.
    ///   - content: What to show.
    ///   - staleDate: When the content stops being current. iOS marks the activity stale; Android removes the notification.
    public func start(id: String, content: LiveActivityContent, staleDate: Date?) async throws {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw LiveActivityError.notPermitted }
            if findActivity(id) != nil { throw LiveActivityError.alreadyExists(id) }
            do {
                let activityContent = ActivityContent(state: content, staleDate: staleDate)
                _ = try Activity<LiveActivityAttributes>.request(
                    attributes: LiveActivityAttributes(id: id),
                    content: activityContent,
                    pushType: requestsPushTokens ? PushType.token : nil)
            } catch {
                throw LiveActivityError.failed("\(error)")
            }
            return
        }
        #endif
        throw LiveActivityError.unsupported
        #else
        if permissionStatus() == LiveActivityPermission.denied || permissionStatus() == LiveActivityPermission.notDetermined {
            throw LiveActivityError.notPermitted
        }
        if activeIDs().contains(id) { throw LiveActivityError.alreadyExists(id) }
        postAndroidNotification(id: id, content: content, staleDate: staleDate)
        #endif
    }

    /// Replaces the content of a running activity.
    public func update(id: String, content: LiveActivityContent) async throws {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *) {
            guard let activity = findActivity(id) else { throw LiveActivityError.notFound(id) }
            await activity.update(ActivityContent(state: content, staleDate: nil))
            return
        }
        #endif
        throw LiveActivityError.unsupported
        #else
        if !activeIDs().contains(id) { throw LiveActivityError.notFound(id) }
        postAndroidNotification(id: id, content: content, staleDate: nil)
        #endif
    }

    /// Ends an activity, optionally showing final content.
    public func end(id: String, finalContent: LiveActivityContent?, dismissal: LiveActivityDismissal) async {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *) {
            guard let activity = findActivity(id) else { return }
            let final: ActivityContent<LiveActivityContent>? = finalContent.map { ActivityContent(state: $0, staleDate: nil) }
            switch dismissal {
            case .immediate:
                await activity.end(final, dismissalPolicy: ActivityUIDismissalPolicy.immediate)
            case .afterSystemDefault:
                await activity.end(final, dismissalPolicy: ActivityUIDismissalPolicy.default)
            case .after(let date):
                await activity.end(final, dismissalPolicy: ActivityUIDismissalPolicy.after(date))
            }
        }
        #endif
        #else
        endAndroidNotification(id: id, finalContent: finalContent, dismissal: dismissal)
        #endif
    }

    /// The ids of the activities that are currently running.
    public func activeIDs() -> [String] {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *) {
            return Activity<LiveActivityAttributes>.activities
                .filter { $0.activityState == ActivityState.active || $0.activityState == ActivityState.stale }
                .map { $0.attributes.id }
        }
        #endif
        return []
        #else
        return androidActiveIDs()
        #endif
    }

    /// A stream of lifecycle changes for one activity. It finishes when the activity ends or is dismissed.
    ///
    /// Android has no callback for user dismissal of a notification, so the state is polled once a second.
    /* SKIP @nobridge */ public func observe(id: String) -> AsyncStream<LiveActivityState> {
        #if !SKIP
        #if os(iOS)
        if #available(iOS 16.2, *), let found = findActivity(id) {
            // ActivityKit's Activity is not Sendable; it is only read from the single task below
            nonisolated(unsafe) let activity = found
            return AsyncStream { continuation in
                let task = Task {
                    for await state in activity.activityStateUpdates {
                        switch state {
                        case .active: continuation.yield(LiveActivityState.active)
                        case .stale: continuation.yield(LiveActivityState.stale)
                        case .ended: continuation.yield(LiveActivityState.ended)
                        case .dismissed: continuation.yield(LiveActivityState.dismissed)
                        @unknown default: break
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        #endif
        return AsyncStream { continuation in
            continuation.yield(LiveActivityState.ended)
            continuation.finish()
        }
        #else
        return observeAndroid(id: id)
        #endif
    }

    #if !SKIP
    #if os(iOS)
    /// iOS only: the stream of APNs push tokens for an activity, for backend updates.
    /// Only produces tokens if `requestsPushTokens` was `true` when the activity started.
    @available(iOS 16.2, *)
    public func pushToken(for id: String) -> AsyncStream<Data> {
        guard let found = findActivity(id) else {
            return AsyncStream { $0.finish() }
        }
        nonisolated(unsafe) let activity = found
        return AsyncStream { continuation in
            let task = Task {
                for await token in activity.pushTokenUpdates {
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// iOS 17.2 and later: the current push-to-start token, or `nil` until the system has issued one.
    ///
    /// Send it to your backend: with it, the backend can start a `LiveActivityAttributes` activity through
    /// APNs while the app is not running. Tokens can change, so also observe ``pushToStartTokens()``.
    @available(iOS 17.2, *)
    public var pushToStartToken: Data? {
        Activity<LiveActivityAttributes>.pushToStartToken
    }

    /// iOS 17.2 and later: a stream of push-to-start tokens, starting with the current one when there is one.
    ///
    /// Start collecting it early at launch (and keep it running), because the system can issue a new token
    /// at any time. Only needs `NSSupportsLiveActivities` and the push notification entitlement.
    @available(iOS 17.2, *)
    public func pushToStartTokens() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                for await token in Activity<LiveActivityAttributes>.pushToStartTokenUpdates {
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @available(iOS 16.2, *)
    private func findActivity(_ id: String) -> Activity<LiveActivityAttributes>? {
        Activity<LiveActivityAttributes>.activities.first {
            $0.attributes.id == id && ($0.activityState == ActivityState.active || $0.activityState == ActivityState.stale)
        }
    }
    #endif
    #endif

    // MARK: - Remote messages

    /// Handles a Live Activity command that arrived as a push data message (Android, for example FCM).
    ///
    /// iOS starts and updates activities through APNs (see ``pushToStartTokens()``), so this is meant for
    /// Android, where a data message wakes the app even when it is closed. Call it from your messaging
    /// service with the message's data, before any other handling:
    ///
    /// ```swift
    /// if await LiveActivityManager.shared.handleRemoteMessage(data) { return }
    /// ```
    ///
    /// Messages with `type` `live_activity` are consumed. The `action` is `show` (start the activity, or
    /// update it when it is already running) or `end`. See the README for the full payload.
    /// - Parameter data: The string key/value data of the message.
    /// - Returns: `true` when the message was a Live Activity message (whether or not the platform showed it),
    ///   `false` when it is not ours and should be handled elsewhere.
    @discardableResult
    public func handleRemoteMessage(_ data: [String: String]) async -> Bool {
        guard let command = LiveActivityRemoteCommand(data: data) else { return false }
        if command.isEnd {
            await end(id: command.id, finalContent: nil, dismissal: LiveActivityDismissal.immediate)
            return true
        }
        guard let content = command.content else { return true }
        do {
            if activeIDs().contains(command.id) {
                try await update(id: command.id, content: content)
            } else {
                try await start(id: command.id, content: content, staleDate: command.staleDate)
            }
        } catch {
            // Showing is best effort: a refused permission or an unsupported device is not an error for the sender.
        }
        return true
    }

    // MARK: - Android implementation

    #if SKIP
    private static let channelID = "skip.liveactivities"
    private static let channelName = "Live updates"

    private var context: Context {
        ProcessInfo.processInfo.androidContext
    }

    private var notificationManager: NotificationManager {
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    private func androidPermissionStatus() -> LiveActivityPermission {
        if Build.VERSION.SDK_INT >= 33 && PermissionManager.queryPermission(.POST_NOTIFICATIONS) != PermissionAuthorization.authorized {
            return LiveActivityPermission.notDetermined
        }
        if !notificationManager.areNotificationsEnabled() { return LiveActivityPermission.denied }
        // canPostPromotedNotifications() is API 36; promoted ongoing needs 36.1, which this call also covers
        if Build.VERSION.SDK_INT >= 36 && notificationManager.canPostPromotedNotifications() {
            return LiveActivityPermission.authorized
        }
        return LiveActivityPermission.authorizedWithoutPromotion
    }

    private func ensureChannel() {
        if Build.VERSION.SDK_INT < 26 { return }
        let channel = NotificationChannel(Self.channelID, Self.channelName, NotificationManager.IMPORTANCE_DEFAULT)
        channel.setSound(nil, nil)
        channel.enableVibration(false)
        notificationManager.createNotificationChannel(channel)
    }

    private func androidActiveIDs() -> [String] {
        var ids: [String] = []
        for sbn in notificationManager.getActiveNotifications() {
            if let tag = sbn.getTag(), sbn.getNotification().channelId == Self.channelID {
                ids.append(tag)
            }
        }
        return ids
    }

    private func smallIcon(_ symbol: String?) -> Int {
        let res = context.resources
        if let symbol = symbol {
            let name = symbol.replacingOccurrences(of: ".", with: "_")
            let found = res.getIdentifier(name, "drawable", context.packageName)
            if found != 0 { return found }
        }
        let appIcon = context.applicationInfo.icon
        return appIcon != 0 ? appIcon : android.R.drawable.ic_dialog_info
    }

    private func contentIntent(_ content: LiveActivityContent) -> PendingIntent? {
        let intent: Intent?
        if let link = content.deepLink {
            intent = Intent(Intent.ACTION_VIEW, Uri.parse(link.absoluteString))
            intent?.setPackage(context.packageName)
        } else {
            intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        }
        guard let intent = intent else { return nil }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private func buildNotification(content: LiveActivityContent, staleDate: Date?, ongoing: Bool) -> Notification {
        ensureChannel()
        let builder = Build.VERSION.SDK_INT >= 26 ? Notification.Builder(context, Self.channelID) : Notification.Builder(context)
        builder.setSmallIcon(smallIcon(content.symbol))
        builder.setContentTitle(content.title)
        if let subtitle = content.subtitle { builder.setContentText(subtitle) }
        builder.setOngoing(ongoing)
        builder.setOnlyAlertOnce(true)
        builder.setCategory(Notification.CATEGORY_PROGRESS)
        if let intent = contentIntent(content) { builder.setContentIntent(intent) }
        if let staleDate = staleDate {
            let ms = Int64(staleDate.timeIntervalSince1970 * 1000.0) - Int64(Date().timeIntervalSince1970 * 1000.0)
            if ms > 0 && Build.VERSION.SDK_INT >= 26 { builder.setTimeoutAfter(ms) }
        }

        if let timer = content.timer {
            let when = timer.countsDown ? timer.end : timer.start
            builder.setWhen(Int64(when.timeIntervalSince1970 * 1000.0))
            builder.setShowWhen(true)
            builder.setUsesChronometer(true)
            if Build.VERSION.SDK_INT >= 24 { builder.setChronometerCountDown(timer.countsDown) }
        }

        let fraction = content.effectiveProgress()
        if Build.VERSION.SDK_INT >= 36 {
            if let status = content.status { builder.setShortCriticalText(status) }
            // setRequestPromotedOngoing(true) is API 36.1. Its documented effect is this extra
            // (Notification.EXTRA_REQUEST_PROMOTED_ONGOING), which compiles and is ignored on plain API 36.
            builder.getExtras().putBoolean("android.requestPromotedOngoing", true)
            if let fraction = fraction {
                builder.setStyle(progressStyle(content: content, fraction: fraction))
            }
        } else if let fraction = fraction {
            builder.setProgress(100, Int(fraction * 100.0), false)
        }
        return builder.build()
    }

    /// Stages become proportional segments; the tracker sits at `fraction` of the total length.
    private func progressStyle(content: LiveActivityContent, fraction: Double) -> Notification.ProgressStyle {
        let style = Notification.ProgressStyle()
        var total = 0
        if content.stages.isEmpty {
            style.addProgressSegment(Notification.ProgressStyle.Segment(100))
            total = 100
        } else {
            for stage in content.stages {
                let length = max(1, Int(stage.weight * 100.0))
                style.addProgressSegment(Notification.ProgressStyle.Segment(length))
                total += length
            }
        }
        style.setProgress(Int(Double(total) * fraction))
        return style
    }

    private func postAndroidNotification(id: String, content: LiveActivityContent, staleDate: Date?) {
        notificationManager.notify(id, 1, buildNotification(content: content, staleDate: staleDate, ongoing: true))
    }

    private var endedIDs: Set<String> = []

    private func endAndroidNotification(id: String, finalContent: LiveActivityContent?, dismissal: LiveActivityDismissal) {
        endedIDs.insert(id)
        switch dismissal {
        case .immediate:
            notificationManager.cancel(id, 1)
        case .afterSystemDefault:
            // leave the final content, no longer ongoing, so the user can swipe it away
            if let finalContent = finalContent {
                notificationManager.notify(id, 1, buildNotification(content: finalContent, staleDate: nil, ongoing: false))
            } else {
                notificationManager.cancel(id, 1)
            }
        case .after(let date):
            let ms = Int64(date.timeIntervalSince1970 * 1000.0) - Int64(Date().timeIntervalSince1970 * 1000.0)
            if let finalContent = finalContent, ms > 0 {
                notificationManager.notify(id, 1, buildNotification(content: finalContent, staleDate: date, ongoing: false))
            } else {
                notificationManager.cancel(id, 1)
            }
        }
    }

    private func observeAndroid(id: String) -> AsyncStream<LiveActivityState> {
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(LiveActivityState.active)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !self.androidActiveIDs().contains(id) {
                        continuation.yield(self.endedIDs.contains(id) ? LiveActivityState.ended : LiveActivityState.dismissed)
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}
#endif
