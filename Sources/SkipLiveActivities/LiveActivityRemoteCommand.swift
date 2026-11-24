#if !SKIP_BRIDGE
import Foundation

/// A Live Activity command carried in a push data message. See `LiveActivityManager.handleRemoteMessage(_:)`.
struct LiveActivityRemoteCommand {
    /// The `type` value that marks a data message as a Live Activity message.
    static let messageType = "live_activity"

    let id: String
    let isEnd: Bool
    /// Present for `show`.
    let content: LiveActivityContent?
    let staleDate: Date?

    /// Parses `data`. Returns `nil` when the message is not a Live Activity message or is malformed.
    ///
    /// A static function, not a failable initializer: Skip transpiles a failing `init?` to a thrown
    /// `NullReturnException` in Kotlin instead of a `null`.
    static func parse(_ data: [String: String]) -> LiveActivityRemoteCommand? {
        guard data["type"] == messageType else { return nil }
        guard let id = data["id"], !id.isEmpty else { return nil }
        let action = data["action"] ?? "show"
        if action == "end" {
            return LiveActivityRemoteCommand(id: id, isEnd: true, content: nil, staleDate: nil)
        }
        guard action == "show", let title = data["title"], !title.isEmpty else { return nil }

        var timer: LiveActivityTimer? = nil
        if let startMillis = millis(data["timerStart"]), let endMillis = millis(data["timerEnd"]) {
            timer = LiveActivityTimer(
                start: Date(timeIntervalSince1970: startMillis / 1000.0),
                end: Date(timeIntervalSince1970: endMillis / 1000.0),
                countsDown: data["countsDown"] != "false")
        }
        var deepLink: URL? = nil
        if let link = text(data["deepLink"]) { deepLink = URL(string: link) }
        var staleDate: Date? = nil
        if let stale = millis(data["staleDate"]) {
            staleDate = Date(timeIntervalSince1970: stale / 1000.0)
        }

        let content = LiveActivityContent(
            title: title,
            subtitle: text(data["subtitle"]),
            status: text(data["status"]),
            symbol: text(data["symbol"]),
            progress: double(data["progress"]),
            timer: timer,
            deepLink: deepLink)
        return LiveActivityRemoteCommand(id: id, isEnd: false, content: content, staleDate: staleDate)
    }

    /// FCM data values are always strings, so an absent value is sent as an empty one.
    private static func text(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    private static func double(_ value: String?) -> Double? {
        guard let value = text(value) else { return nil }
        return Double(value)
    }

    private static func millis(_ value: String?) -> Double? {
        double(value)
    }
}
#endif
