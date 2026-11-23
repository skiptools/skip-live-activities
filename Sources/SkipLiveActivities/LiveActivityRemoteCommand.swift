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
    init?(data: [String: String]) {
        guard data["type"] == Self.messageType else { return nil }
        guard let id = data["id"], !id.isEmpty else { return nil }
        let action = data["action"] ?? "show"
        if action == "end" {
            self.id = id
            self.isEnd = true
            self.content = nil
            self.staleDate = nil
            return
        }
        guard action == "show", let title = data["title"], !title.isEmpty else { return nil }

        var timer: LiveActivityTimer? = nil
        if let startMillis = Self.millis(data["timerStart"]), let endMillis = Self.millis(data["timerEnd"]) {
            timer = LiveActivityTimer(
                start: Date(timeIntervalSince1970: startMillis / 1000.0),
                end: Date(timeIntervalSince1970: endMillis / 1000.0),
                countsDown: data["countsDown"] != "false")
        }
        var deepLink: URL? = nil
        if let link = Self.text(data["deepLink"]) { deepLink = URL(string: link) }

        self.id = id
        self.isEnd = false
        self.content = LiveActivityContent(
            title: title,
            subtitle: Self.text(data["subtitle"]),
            status: Self.text(data["status"]),
            symbol: Self.text(data["symbol"]),
            progress: Self.double(data["progress"]),
            timer: timer,
            deepLink: deepLink)
        if let stale = Self.millis(data["staleDate"]) {
            self.staleDate = Date(timeIntervalSince1970: stale / 1000.0)
        } else {
            self.staleDate = nil
        }
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
