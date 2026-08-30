import XCTest
@testable import PopNotch

/// Panel navigation: the coordinator's destination state and its resets.
/// Runs against a scratch UserDefaults suite so no real preference moves.
@MainActor
final class NotchNavigationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.techie.PopNotch.navtests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeCoordinator(clipboardEnabled: Bool = true)
        -> (NotchCoordinator, ClipboardModule) {
        let arbiter = NotchArbiter()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: arbiter)
        let clipboard = ClipboardModule(service: ClipboardService())
        coordinator.register(clipboard, enabledByDefault: clipboardEnabled)
        return (coordinator, clipboard)
    }

    func testStartsOnStandby() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertEqual(coordinator.destination, .standby,
                       "the panel always opens on the arbitrated default")
    }

    func testNavigateReachesTheClipboardScreen() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        XCTAssertEqual(coordinator.destination, .clipboard)
    }

    func testNavigateBackReturnsToStandby() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.navigate(to: .standby)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDisablingTheModuleUnderTheScreenSendsYouHome() {
        // Settings can pull the feature out from under the open screen; the
        // panel must not be left showing a screen whose feature is off.
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.setEnabled(false, for: "clipboard")
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDisablingSomeOtherModuleDoesNotNavigate() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.setEnabled(false, for: "system-stats")
        XCTAssertEqual(coordinator.destination, .clipboard,
                       "an unrelated toggle must not yank the user off their screen")
    }
}
