import Testing
import OSLog
import Foundation
@testable import SkipLiveActivities

let logger: Logger = Logger(subsystem: "SkipLiveActivities", category: "Tests")

@Suite struct SkipLiveActivitiesTests {

    @Test func testContentDefaults() throws {
        let content = LiveActivityContent(title: "Workout")
        #expect(content.title == "Workout")
        #expect(content.subtitle == nil)
        #expect(content.status == nil)
        #expect(content.symbol == nil)
        #expect(content.progress == nil)
        #expect(content.timer == nil)
        #expect(content.stages.isEmpty)
        #expect(content.deepLink == nil)
    }

    #if !SKIP // Codable is iOS/macOS only, see LiveActivityTypes.swift
    @Test func testContentCodableRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let content = LiveActivityContent(
            title: "Spinning",
            subtitle: "Room 2",
            status: "12:00",
            symbol: "figure.indoor.cycle",
            progress: 0.25,
            timer: LiveActivityTimer(start: start, end: start.addingTimeInterval(3600), countsDown: true),
            stages: [LiveActivityStage(title: "Warm-up", weight: 0.2), LiveActivityStage(title: "Main set", weight: 0.8)],
            deepLink: URL(string: "club://workout/42"))
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(LiveActivityContent.self, from: data)
        #expect(decoded.title == "Spinning")
        #expect(decoded.subtitle == "Room 2")
        #expect(decoded.status == "12:00")
        #expect(decoded.symbol == "figure.indoor.cycle")
        #expect(decoded.progress == 0.25)
        #expect(decoded.timer?.countsDown == true)
        #expect(decoded.stages.count == 2)
        #expect(decoded.stages[1].title == "Main set")
        #expect(decoded.deepLink?.absoluteString == "club://workout/42")
    }
    #endif

    @Test func testTimerProgress() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let timer = LiveActivityTimer(start: start, end: start.addingTimeInterval(100))
        #expect(timer.countsDown == true)
        #expect(timer.progress(at: start.addingTimeInterval(-10)) == 0.0)
        #expect(timer.progress(at: start.addingTimeInterval(25)) == 0.25)
        #expect(timer.progress(at: start.addingTimeInterval(500)) == 1.0)
        let empty = LiveActivityTimer(start: start, end: start)
        #expect(empty.progress(at: start) == 1.0)
    }

    @Test func testEffectiveProgressPrefersTimer() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let timer = LiveActivityTimer(start: start, end: start.addingTimeInterval(100))
        let both = LiveActivityContent(title: "A", progress: 0.9, timer: timer)
        #expect(both.effectiveProgress(at: start.addingTimeInterval(50)) == 0.5)
        let manual = LiveActivityContent(title: "B", progress: 1.5)
        #expect(manual.effectiveProgress() == 1.0)
        let none = LiveActivityContent(title: "C")
        #expect(none.effectiveProgress() == nil)
    }

    @Test func testActiveIDsStartsEmpty() throws {
        #expect(LiveActivityManager.shared.activeIDs().isEmpty)
    }

    @Test func testUpdateUnknownActivityThrows() async throws {
        var threw = false
        do {
            try await LiveActivityManager.shared.update(id: "does-not-exist", content: LiveActivityContent(title: "X"))
        } catch {
            // not found, not permitted or unsupported, depending on the platform
            threw = true
        }
        #expect(threw)
    }

    @Test func testEndUnknownActivityIsNoOp() async throws {
        await LiveActivityManager.shared.end(id: "does-not-exist", finalContent: nil, dismissal: LiveActivityDismissal.immediate)
        #expect(LiveActivityManager.shared.activeIDs().isEmpty)
    }

    // MARK: - Remote messages

    @Test func testRemoteShowMessageParses() throws {
        let command = LiveActivityRemoteCommand(data: [
            "type": "live_activity",
            "action": "show",
            "id": "workout-1",
            "title": "Spinning",
            "subtitle": "Studio 2",
            "timerStart": "1000000",
            "timerEnd": "4600000",
            "countsDown": "false",
            "deepLink": "club://workout/1"
        ])
        #expect(command != nil)
        #expect(command?.id == "workout-1")
        #expect(command?.isEnd == false)
        #expect(command?.content?.title == "Spinning")
        #expect(command?.content?.subtitle == "Studio 2")
        #expect(command?.content?.timer?.countsDown == false)
        #expect(command?.content?.timer?.start == Date(timeIntervalSince1970: 1000.0))
        #expect(command?.content?.timer?.end == Date(timeIntervalSince1970: 4600.0))
        #expect(command?.content?.deepLink?.absoluteString == "club://workout/1")
        #expect(command?.staleDate == nil)
    }

    @Test func testRemoteEmptyValuesBecomeNil() throws {
        let command = LiveActivityRemoteCommand(data: [
            "type": "live_activity", "action": "show", "id": "a", "title": "T",
            "subtitle": "", "deepLink": "", "status": ""
        ])
        #expect(command?.content?.subtitle == nil)
        #expect(command?.content?.status == nil)
        #expect(command?.content?.deepLink == nil)
        #expect(command?.content?.timer == nil)
    }

    @Test func testRemoteEndMessageParses() throws {
        let command = LiveActivityRemoteCommand(data: ["type": "live_activity", "action": "end", "id": "workout-1"])
        #expect(command?.isEnd == true)
        #expect(command?.id == "workout-1")
        #expect(command?.content == nil)
    }

    @Test func testRemoteIgnoresOtherMessages() throws {
        #expect(LiveActivityRemoteCommand(data: [:]) == nil)
        #expect(LiveActivityRemoteCommand(data: ["type": "workout", "id": "1", "title": "T"]) == nil)
        #expect(LiveActivityRemoteCommand(data: ["type": "live_activity", "action": "show", "title": "T"]) == nil)
        #expect(LiveActivityRemoteCommand(data: ["type": "live_activity", "action": "show", "id": "1"]) == nil)
        #expect(LiveActivityRemoteCommand(data: ["type": "live_activity", "action": "bogus", "id": "1", "title": "T"]) == nil)
    }

    @Test func testHandleRemoteMessageConsumesOnlyOwnMessages() async throws {
        let other = await LiveActivityManager.shared.handleRemoteMessage(["type": "workout"])
        #expect(other == false)
        // ending an activity that is not running is a no-op but the message is still ours
        let ours = await LiveActivityManager.shared.handleRemoteMessage(["type": "live_activity", "action": "end", "id": "does-not-exist"])
        #expect(ours == true)
    }
}
