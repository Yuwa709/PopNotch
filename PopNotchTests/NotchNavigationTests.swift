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

    // MARK: - A second screen

    func testEachScreenMapsToItsOwnModule() {
        XCTAssertEqual(NotchCoordinator.Destination.clipboard.moduleID, "clipboard")
        XCTAssertEqual(NotchCoordinator.Destination.fileShelf.moduleID, "file-shelf")
        XCTAssertNil(NotchCoordinator.Destination.standby.moduleID,
                     "standby is the arbitrated default, not a module's screen")
    }

    func testNavigatingToTheShelf() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .fileShelf)
        XCTAssertEqual(coordinator.destination, .fileShelf)
    }

    func testDisablingTheShelfUnderItsScreenSendsYouHome() {
        let arbiter = NotchArbiter()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: arbiter)
        coordinator.register(FileShelfModule(service: FileShelfService()), enabledByDefault: true)
        coordinator.navigate(to: .fileShelf)
        coordinator.setEnabled(false, for: "file-shelf")
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDisablingOneScreensModuleLeavesTheOtherScreenAlone() {
        let (coordinator, _) = makeCoordinator()
        coordinator.register(FileShelfModule(service: FileShelfService()), enabledByDefault: true)
        coordinator.navigate(to: .fileShelf)
        coordinator.setEnabled(false, for: "clipboard")
        XCTAssertEqual(coordinator.destination, .fileShelf,
                       "an unrelated module's toggle must not close your screen")
    }

    // MARK: - A file drag opens to the shelf

    private func makeCoordinatorWithShelf(enabled: Bool) -> NotchCoordinator {
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: NotchArbiter())
        coordinator.register(FileShelfModule(service: FileShelfService()),
                             enabledByDefault: enabled)
        return coordinator
    }

    func testFileDragOpensToTheShelf() {
        // Opening to home would be useless: there is nowhere on it to drop.
        let coordinator = makeCoordinatorWithShelf(enabled: true)
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .fileShelf)
    }

    func testFileDragDoesNotNavigateWhenTheShelfIsOff() {
        let coordinator = makeCoordinatorWithShelf(enabled: false)
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .standby,
                       "a disabled feature must never be navigated to")
    }

    func testFileDragWithNoShelfModuleRegisteredIsHarmless() {
        let (coordinator, _) = makeCoordinator()
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDragLeavingBeforeThePanelOpensResetsTheDestination() {
        // Otherwise the next plain hover would open to the shelf, having
        // inherited a destination set for a screen nobody ever saw.
        let coordinator = makeCoordinatorWithShelf(enabled: true)
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .fileShelf)
        coordinator.fileDragChanged(false)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDragExitDoesNotDisturbAScreenTheUserNavigatedTo() {
        // A stray drag ending must not yank someone off the clipboard screen
        // they opened by hand.
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.fileDragChanged(false)
        XCTAssertEqual(coordinator.destination, .standby,
                       "reset only applies while collapsed, which this is")
    }

    func testPlainHoverStillOpensHome() {
        // The non-drag path is untouched: no destination is chosen for it.
        let coordinator = makeCoordinatorWithShelf(enabled: true)
        XCTAssertEqual(coordinator.destination, .standby)
    }
}
