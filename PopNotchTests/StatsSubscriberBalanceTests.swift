import XCTest
@testable import PopNotch

/// Subscriber accounting for the stats page's three services.
///
/// The services are *counted*, not boolean, so several owners can share one
/// service without one's disappearance stopping sampling for the others. That
/// only holds if every `start()` is matched by exactly one `stop()`, so this
/// pins the balance: five open/close cycles must leave every count exactly
/// where it started, on each of the paths that reach the page.
@MainActor
final class StatsSubscriberBalanceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.techie.PopNotch.statsbalance"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// `storeURL: nil` so a test never writes the user's real history file.
    private func makeServices() -> (SystemStatsService, BatteryService, SystemStatsHistory) {
        let stats = SystemStatsService()
        let battery = BatteryService()
        return (stats, battery, SystemStatsHistory(stats: stats, battery: battery, storeURL: nil))
    }

    private func makeCoordinator(registerModule: Bool)
    -> (NotchCoordinator, SystemStatsService, BatteryService, SystemStatsHistory) {
        let (stats, battery, history) = makeServices()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults),
            arbiter: NotchArbiter(),
            statsPage: NotchCoordinator.StatsPageServices(
                stats: stats, battery: battery, history: history))
        if registerModule {
            coordinator.register(SystemStatsModule(service: stats))
            coordinator.start()
        }
        return (coordinator, stats, battery, history)
    }

    /// Navigating to the page and back, five times.
    func testNavigateCyclesLeaveEveryCountWhereItStarted() {
        let (coordinator, stats, battery, history) = makeCoordinator(registerModule: false)
        let base = [stats.subscribers, battery.subscribers, history.subscribers]

        for cycle in 1...5 {
            coordinator.navigate(to: .systemStats)
            XCTAssertEqual([stats.subscribers, battery.subscribers, history.subscribers],
                           [base[0] + 1, base[1] + 2, base[2] + 1],
                           "the open page holds one stats, two battery, one history (cycle \(cycle))")
            coordinator.navigate(to: .standby)
            XCTAssertEqual([stats.subscribers, battery.subscribers, history.subscribers], base,
                           "counts must return to baseline after cycle \(cycle)")
        }
    }

    /// The path the app actually takes: expand, open the page, back, collapse.
    func testPinNavigateCollapseCyclesLeaveEveryCountWhereItStarted() {
        let (coordinator, stats, battery, history) = makeCoordinator(registerModule: false)
        let base = [stats.subscribers, battery.subscribers, history.subscribers]

        for cycle in 1...5 {
            coordinator.setPinned(true)
            coordinator.navigate(to: .systemStats)
            coordinator.navigate(to: .standby)
            coordinator.setPinned(false)
            XCTAssertEqual([stats.subscribers, battery.subscribers, history.subscribers], base,
                           "counts must return to baseline after cycle \(cycle)")
        }
    }

    /// With the module registered, the arbiter's visibility callbacks drive
    /// `SystemStatsService` as well. Its baseline is one, not zero: the
    /// compact view is on screen in standby and needs live values. That one
    /// is the always-on subscriber, and cycling the page must not add to it.
    func testRegisteredModuleReturnsToItsAlwaysOnBaseline() {
        let (coordinator, stats, battery, history) = makeCoordinator(registerModule: true)
        let base = [stats.subscribers, battery.subscribers, history.subscribers]
        XCTAssertEqual(base, [1, 0, 0], "the compact view holds exactly one stats subscriber")

        for cycle in 1...5 {
            coordinator.setPinned(true)
            coordinator.navigate(to: .systemStats)
            coordinator.navigate(to: .standby)
            coordinator.setPinned(false)
            XCTAssertEqual([stats.subscribers, battery.subscribers, history.subscribers], base,
                           "counts must return to baseline after cycle \(cycle)")
        }
    }

    /// An unmatched `stop()` must not push a count negative, which would make
    /// the next `start()` fail to restart sampling.
    func testExtraStopsCannotDriveCountsNegative() {
        let (stats, battery, history) = makeServices()

        // Two surplus stops on each, from a standing count of zero.
        stats.stop();   stats.stop()
        battery.stop(); battery.stop()
        history.stop(); history.stop()
        XCTAssertEqual([stats.subscribers, battery.subscribers, history.subscribers], [0, 0, 0],
                       "a stop below zero must clamp, not go negative")

        // A start afterwards must still register. `history.start()` also
        // starts the two services it holds, so those land on two, not one —
        // that propagation is the design, not drift.
        stats.start()
        battery.start()
        history.start()
        XCTAssertEqual([stats.subscribers, battery.subscribers, history.subscribers], [2, 2, 1],
                       "start must still count after surplus stops")
    }
}
