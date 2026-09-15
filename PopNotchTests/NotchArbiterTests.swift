import XCTest
@testable import PopNotch

/// Arbitration is pure logic with no AppKit, which makes it one of the few
/// things in this project verifiable without a screen. Each test drives a
/// hand-cranked clock, so nothing sleeps and nothing flakes.
@MainActor
final class NotchArbiterTests: XCTestCase {

    private var clock: TestClock!
    private var arbiter: NotchArbiter!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        arbiter = NotchArbiter(now: clock.read)
    }

    // MARK: - Standby

    func testStandbyListsEnabledCompactModulesInRegistrationOrder() {
        arbiter.register(StubModule(id: "stats"))
        arbiter.register(StubModule(id: "weather"))
        XCTAssertEqual(arbiter.presentation, .standby(["stats", "weather"]))
    }

    func testDisabledModuleIsExcludedFromStandby() {
        arbiter.register(StubModule(id: "stats"))
        arbiter.register(StubModule(id: "weather", isEnabled: false))
        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
    }

    func testModuleOptingOutOfCompactDisplayIsExcluded() {
        arbiter.register(StubModule(id: "stats"))
        arbiter.register(StubModule(id: "dropzone", wantsCompactDisplay: false))
        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
    }

    func testDuplicateIDIsRejected() {
        arbiter.register(StubModule(id: "stats"))
        arbiter.register(StubModule(id: "stats"))
        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
    }

    // MARK: - Priority

    func testHigherPriorityInterruptsLower() {
        let stats = StubModule(id: "stats", priority: .ambient)
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(stats)
        arbiter.register(media)

        arbiter.requestLiveActivity(stats.activity())
        XCTAssertEqual(arbiter.presentation, .liveActivity("stats"))

        arbiter.requestLiveActivity(media.activity())
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"))
    }

    func testLowerPriorityDoesNotInterruptAndWaitsItsTurn() {
        let stats = StubModule(id: "stats", priority: .ambient)
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(stats)
        arbiter.register(media)

        arbiter.requestLiveActivity(media.activity(duration: 5))
        arbiter.requestLiveActivity(stats.activity(duration: 5))
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"))

        clock.advance(by: 5)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("stats"))
    }

    func testInterruptedActivityIsDroppedNotResumed() {
        let stats = StubModule(id: "stats", priority: .ambient)
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(stats)
        arbiter.register(media)

        arbiter.requestLiveActivity(stats.activity(duration: 5))
        arbiter.requestLiveActivity(media.activity(duration: 5))
        clock.advance(by: 5)
        arbiter.tick()

        // Back to standby: the preempted activity does not resurface.
        XCTAssertEqual(arbiter.presentation, .standby(["stats", "media"]))
    }

    func testEqualPriorityQueuesFIFO() {
        let a = StubModule(id: "a", priority: .standard)
        let b = StubModule(id: "b", priority: .standard)
        let c = StubModule(id: "c", priority: .standard)
        [a, b, c].forEach { arbiter.register($0) }

        arbiter.requestLiveActivity(a.activity(duration: 1))
        arbiter.requestLiveActivity(b.activity(duration: 1))
        arbiter.requestLiveActivity(c.activity(duration: 1))
        XCTAssertEqual(arbiter.presentation, .liveActivity("a"))

        clock.advance(by: 1); arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("b"))

        clock.advance(by: 1); arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("c"))
    }

    func testHigherPriorityJumpsAheadOfQueuedLowerPriority() {
        let holder = StubModule(id: "holder", priority: .urgent)
        let low = StubModule(id: "low", priority: .ambient)
        let high = StubModule(id: "high", priority: .elevated)
        [holder, low, high].forEach { arbiter.register($0) }

        arbiter.requestLiveActivity(holder.activity(duration: 2))
        arbiter.requestLiveActivity(low.activity(duration: 1))
        arbiter.requestLiveActivity(high.activity(duration: 1))

        clock.advance(by: 2); arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("high"))
    }

    // MARK: - Expiry

    func testActivityYieldsToStandbyAfterItsDuration() {
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)

        arbiter.requestLiveActivity(media.activity(duration: 3))
        clock.advance(by: 2.9)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"), "must not yield early")

        clock.advance(by: 0.1)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .standby(["media"]))
    }

    func testTickIsInertWithNoActiveActivity() {
        arbiter.register(StubModule(id: "stats"))
        clock.advance(by: 100)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
    }

    // MARK: - Expiry scheduling

    func testNoExpiryWhenIdle() {
        arbiter.register(StubModule(id: "stats"))
        XCTAssertNil(arbiter.timeUntilExpiry, "an idle notch must schedule no timer")
    }

    func testTimeUntilExpiryCountsDown() {
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)

        arbiter.requestLiveActivity(media.activity(duration: 5))
        XCTAssertEqual(arbiter.timeUntilExpiry ?? -1, 5, accuracy: 0.001)

        clock.advance(by: 3)
        XCTAssertEqual(arbiter.timeUntilExpiry ?? -1, 2, accuracy: 0.001)
    }

    func testTimeUntilExpiryNeverGoesNegative() {
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)
        arbiter.requestLiveActivity(media.activity(duration: 1))

        clock.advance(by: 10)
        XCTAssertEqual(arbiter.timeUntilExpiry ?? -1, 0, accuracy: 0.001)
    }

    func testExpiryClearsAfterYielding() {
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)
        arbiter.requestLiveActivity(media.activity(duration: 1))

        clock.advance(by: 1)
        arbiter.tick()
        XCTAssertNil(arbiter.timeUntilExpiry, "no timer must survive the activity")
    }

    func testQueuedActivityGetsItsFullDurationFromWhenItStarts() {
        let a = StubModule(id: "a", priority: .standard)
        let b = StubModule(id: "b", priority: .standard)
        arbiter.register(a)
        arbiter.register(b)

        arbiter.requestLiveActivity(a.activity(duration: 2))
        arbiter.requestLiveActivity(b.activity(duration: 4))

        clock.advance(by: 2)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("b"))
        XCTAssertEqual(arbiter.timeUntilExpiry ?? -1, 4, accuracy: 0.001,
                       "queued time must not count against its duration")
    }

    // MARK: - Enablement

    func testDisablingActiveModuleYieldsTheNotch() {
        let media = StubModule(id: "media", priority: .elevated)
        let stats = StubModule(id: "stats")
        arbiter.register(media)
        arbiter.register(stats)

        arbiter.requestLiveActivity(media.activity(duration: 10))
        media.isEnabled = false
        arbiter.enablementDidChange()

        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
    }

    func testDisabledModuleCannotClaimTheNotch() {
        let media = StubModule(id: "media", priority: .elevated, isEnabled: false)
        arbiter.register(media)
        arbiter.requestLiveActivity(media.activity())
        XCTAssertEqual(arbiter.presentation, .standby([]))
    }

    func testUnregisteredModuleCannotClaimTheNotch() {
        arbiter.register(StubModule(id: "stats"))
        let ghost = LiveActivityRequest(moduleID: "ghost", priority: .urgent, duration: 5)
        arbiter.requestLiveActivity(ghost)
        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
    }

    // MARK: - Visibility (hard rule 9)

    /// The regression this section exists for. Being arbitrated onto the
    /// notch was treated as being on screen, so every standby module was
    /// told it was visible at registration and never told otherwise.
    func testStandbyModulesAreNotVisibleWhileCollapsed() {
        let media = StubModule(id: "media")
        arbiter.register(media)
        XCTAssertEqual(arbiter.presentation, .standby(["media"]))
        XCTAssertEqual(media.visibilityLog, [], "on the notch is not on screen")

        arbiter.panelDidApply(.collapsed)
        XCTAssertEqual(media.visibilityLog, [], "the collapsed wings do not count as visible")
        XCTAssertTrue(arbiter.visibleIDs.isEmpty)
    }

    func testOpeningThePanelShowsStandbyModulesAndCollapsingHidesThem() {
        let media = StubModule(id: "media")
        arbiter.register(media)

        arbiter.panelDidApply(.expanded)
        XCTAssertTrue(media.isVisible)
        XCTAssertEqual(arbiter.visibleIDs, ["media"])

        arbiter.panelDidApply(.collapsed)
        XCTAssertEqual(media.visibilityLog, [true, false])
    }

    /// Every hover is one cycle; five must leave exactly nothing visible.
    func testRepeatedOpenCloseCyclesStayBalanced() {
        let media = StubModule(id: "media")
        arbiter.register(media)
        for _ in 1...5 {
            arbiter.panelDidApply(.expanded)
            arbiter.panelDidApply(.collapsed)
        }
        XCTAssertEqual(media.visibilityLog, Array(repeating: [true, false], count: 5).flatMap { $0 })
        XCTAssertTrue(arbiter.visibleIDs.isEmpty)
    }

    /// System stats has no expanded row: opening the panel draws nothing of
    /// it, so it must not be told to start sampling.
    func testModuleWithNothingToDrawIsNotVisibleWhenOpen() {
        let media = StubModule(id: "media")
        let stats = StubModule(id: "stats", hasExpandedContent: false)
        arbiter.register(media)
        arbiter.register(stats)

        arbiter.panelDidApply(.expanded)
        XCTAssertTrue(media.isVisible)
        XCTAssertEqual(stats.visibilityLog, [])
    }

    /// Music starting while the panel is open. The coordinator re-applies
    /// the same surface on the presence change, and that must still re-check.
    func testContentAppearingWhileOpenIsNoticedOnTheNextApply() {
        let media = StubModule(id: "media", hasExpandedContent: false)
        arbiter.register(media)
        arbiter.panelDidApply(.expanded)
        XCTAssertEqual(media.visibilityLog, [])

        media.hasExpandedContent = true
        arbiter.panelDidApply(.expanded)
        XCTAssertEqual(media.visibilityLog, [true])

        media.hasExpandedContent = false
        arbiter.panelDidApply(.expanded)
        XCTAssertEqual(media.visibilityLog, [true, false])
    }

    /// The stats page replaces the media card, so the card's clock stops.
    func testNavigatedScreenHidesTheStandbyStack() {
        let media = StubModule(id: "media")
        arbiter.register(media)

        arbiter.panelDidApply(.expanded)
        arbiter.panelDidApply(.navigated)
        XCTAssertFalse(media.isVisible, "a navigated screen replaces the stack")

        arbiter.panelDidApply(.expanded)
        XCTAssertTrue(media.isVisible, "and Back brings it back")
    }

    func testLiveActivityIsNotVisibleUntilThePanelOpensForIt() {
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)

        arbiter.requestLiveActivity(media.activity(duration: 5))
        XCTAssertEqual(media.visibilityLog, [])

        arbiter.panelDidApply(.expanded)
        XCTAssertEqual(media.visibilityLog, [true])
    }

    /// The coordinator draws an activity over whatever screen was open, so
    /// the activity is on screen there too.
    func testLiveActivityIsVisibleOverANavigatedScreen() {
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)
        arbiter.panelDidApply(.navigated)
        XCTAssertEqual(media.visibilityLog, [])

        arbiter.requestLiveActivity(media.activity(duration: 5))
        XCTAssertEqual(media.visibilityLog, [true])
    }

    func testDisablingAVisibleModuleResignsIt() {
        let media = StubModule(id: "media")
        arbiter.register(media)
        arbiter.panelDidApply(.expanded)

        media.isEnabled = false
        arbiter.enablementDidChange()
        XCTAssertEqual(media.visibilityLog, [true, false])
    }

    func testLiveActivitySuspendsTheModulesItCovers() {
        let stats = StubModule(id: "stats")
        let media = StubModule(id: "media", priority: .elevated, wantsCompactDisplay: false)
        arbiter.register(stats)
        arbiter.register(media)
        arbiter.panelDidApply(.expanded)
        XCTAssertTrue(stats.isVisible)

        arbiter.requestLiveActivity(media.activity(duration: 1))
        XCTAssertFalse(stats.isVisible, "covered module must be told to stop polling")
        XCTAssertTrue(media.isVisible)

        clock.advance(by: 1); arbiter.tick()
        XCTAssertTrue(stats.isVisible, "and told to resume when it returns")
        XCTAssertFalse(media.isVisible)
    }

    func testVisibilityIsNotRedundantlyRepeated() {
        let stats = StubModule(id: "stats")
        arbiter.register(stats)
        arbiter.panelDidApply(.expanded)
        arbiter.panelDidApply(.expanded)
        arbiter.register(StubModule(id: "weather"))
        // Re-applying the same surface, and a second module joining the open
        // stack, leave stats visible throughout: it must not be told twice.
        XCTAssertEqual(stats.visibilityLog, [true])
    }

    // MARK: - Change notification

    func testPresentationChangeFiresOnlyOnActualChange() {
        var observed: [NotchPresentation] = []
        arbiter.onPresentationChange = { observed.append($0) }

        let stats = StubModule(id: "stats")
        arbiter.register(stats)
        arbiter.requestLiveActivity(stats.activity(duration: 1))
        arbiter.tick() // too early, no change
        clock.advance(by: 1)
        arbiter.tick()

        XCTAssertEqual(observed, [
            .standby(["stats"]),
            .liveActivity("stats"),
            .standby(["stats"])
        ])
    }
}
