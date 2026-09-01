import AppKit
import SwiftUI
import os

/// Connects the arbiter's decisions to the panel on screen.
///
/// This is the only place that knows about both. `NotchArbiter` stays free of
/// AppKit so it can be tested; `NotchPanel` stays free of feature logic so it
/// only draws. Modules touch neither.
///
/// Owns: panel lifecycle, screen placement, hover, and the single expiry
/// timer. Registering a module here is the "one place" the Phase 2 goal
/// requires — adding a feature is one new file plus one `register` call.
@MainActor
final class NotchCoordinator {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Coordinator")

    private let arbiter: NotchArbiter
    private let settings: SettingsStore
    private var panel: NotchPanel?
    private var currentScreen: NSScreen?

    /// One-shot, scheduled only while an activity is running and invalidated
    /// the moment it is not. Hard rule 9: no timer exists at rest.
    private var expiryTimer: Timer?

    private var isHovered = false

    /// `arbiter` is injectable for tests. Defaulted via nil rather than
    /// `= NotchArbiter()`, because a default argument is evaluated in a
    /// nonisolated context and the arbiter is `@MainActor`.
    /// Panel-level, not module-level: keeping the Mac awake is a property of
    /// the app, not of anything the notch happens to be showing, so the
    /// control renders as panel chrome whenever the panel is expanded rather
    /// than living inside a module's view. Nil in tests.
    /// Where the expanded panel is, beyond what the arbiter chose.
    ///
    /// `.standby` is the arbitrated default (media, stats, live activities).
    /// Every other case is a full-panel screen a chrome control navigated
    /// to. Future screens add a case here and a branch in `content(for:)` —
    /// the reset-on-collapse and disabled-module fallbacks come for free.
    enum Destination: Equatable {
        case standby
        case clipboard
        case fileShelf

        /// The module a screen belongs to, so the disabled-module fallbacks
        /// stay one rule rather than one branch per destination.
        var moduleID: ModuleID? {
            switch self {
            case .standby: nil
            case .clipboard: "clipboard"
            case .fileShelf: "file-shelf"
            }
        }
    }

    /// Owned here because the coordinator already owns what the panel shows.
    /// Not persisted: a screen is a place you went, not a preference.
    private(set) var destination: Destination = .standby

    /// Session-only pin. Nil in tests that do not care about it.
    private let pinState: PinState?

    /// Whether the notch is currently held open.
    var isPinned: Bool { pinState?.isPinned ?? false }

    /// Pins or unpins, then re-evaluates.
    ///
    /// Unpinning needs no cursor check of its own: hover bookkeeping keeps
    /// running underneath a pin (nothing suppresses it), so `isHovered` is
    /// already correct here. `applyState` therefore collapses when the cursor
    /// is away and holds when it is inside, which is exactly the required
    /// behaviour, for free.
    func setPinned(_ pinned: Bool) {
        guard let pinState, pinState.isPinned != pinned else { return }
        pinState.isPinned = pinned
        Self.logger.notice("Notch \(pinned ? "pinned open" : "unpinned", privacy: .public)")
        renderContent()
        applyState()
    }

    private let caffeinate: CaffeinateService?
    /// The coordinator owns only the capture LIFECYCLE — the tap must die
    /// with the panel (setPanelVisible in applyState). Rendering moved into
    /// the media header, where the wave indicator used to be. Nil in tests.
    private let audioVisualizer: AudioVisualizerService?

    init(settings: SettingsStore,
         arbiter: NotchArbiter? = nil,
         caffeinate: CaffeinateService? = nil,
         audioVisualizer: AudioVisualizerService? = nil,
         pinState: PinState? = nil) {
        self.settings = settings
        self.pinState = pinState
        self.caffeinate = caffeinate
        self.audioVisualizer = audioVisualizer
        self.arbiter = arbiter ?? NotchArbiter()
        self.arbiter.onPresentationChange = { [weak self] presentation in
            self?.presentationChanged(presentation)
        }
    }

    deinit {
        expiryTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("No target screen; panel not created")
            return
        }

        let panel = NotchPanel(screen: screen)
        panel.hoverEnterDelay = settings.settings.hoverEnterDelay
        panel.onFileDragChange = { [weak self] active in
            self?.fileDragChanged(active)
        }
        panel.onHoverChange = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        self.panel = panel
        reposition(reason: "launch")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    /// Registers a feature. The one place adding a module touches.
    ///
    /// The stored preference is applied here rather than by the caller, so a
    /// module can never be registered in a state that disagrees with what the
    /// user chose.
    func register(_ module: any NotchModule, enabledByDefault: Bool = true) {
        module.isEnabled = settings.isEnabled(module.id, default: enabledByDefault)
        arbiter.register(module)
    }

    /// What Settings lists: one row per registered module.
    var moduleSummaries: [(id: ModuleID, displayName: String, isEnabled: Bool)] {
        arbiter.registeredModules.map { ($0.id, $0.displayName, $0.isEnabled) }
    }

    /// Toggles a module from Settings: persists the choice, updates the live
    /// module, and re-runs arbitration so the notch reflects it immediately.
    func setEnabled(_ enabled: Bool, for id: ModuleID) {
        guard let module = arbiter.module(for: id) else { return }
        module.isEnabled = enabled
        settings.setEnabled(enabled, for: id)
        if !enabled, destination.moduleID == id {
            destination = .standby
        }
        arbiter.enablementDidChange()
        renderContent()
        applyState()
    }

    func requestLiveActivity(_ request: LiveActivityRequest) {
        arbiter.requestLiveActivity(request)
    }

    /// From Settings: persists and applies to the live panel immediately.
    func setHoverDelay(_ delay: TimeInterval) {
        settings.update { $0.hoverEnterDelay = delay }
        panel?.hoverEnterDelay = delay
    }

    // MARK: - Screen placement

    @objc private func screenParametersDidChange(_ notification: Notification) {
        reposition(reason: "screen parameters changed")
    }

    /// Recomputes the target screen and geometry. A display change collapses
    /// the panel: hover is invalid across a reconfiguration anyway.
    private func reposition(reason: String) {
        guard let panel else { return }

        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("Reposition (\(reason, privacy: .public)): no target screen; hiding panel")
            currentScreen = nil
            panel.orderOut(nil)
            return
        }

        currentScreen = screen
        isHovered = false
        let frame = NotchPanel.notchRect(on: screen)
        panel.setFrame(frame, display: true)
        renderContent()

        // orderFrontRegardless, not orderFront: this background agent is never
        // the active app, and must never become it (hard rule 4).
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        Self.logger.notice("Reposition (\(reason, privacy: .public)): panel at \(NSStringFromRect(frame), privacy: .public) on \(screen.localizedName, privacy: .public)")
        applyState()
    }

    // MARK: - Presentation

    private func hoverChanged(_ hovering: Bool) {
        isHovered = hovering
        // Content depends on expansion, not just presentation: an expanded
        // notch shows each module's richer view.
        renderContent()
        applyState()
    }

    private func presentationChanged(_ presentation: NotchPresentation) {
        renderContent()
        applyState()
        scheduleExpiry()
    }

    /// Re-evaluates size and content. Public for modules whose collapsed
    /// presence changes — e.g. music starting or stopping flips the panel
    /// between invisible and the compact wings.
    func refreshPresentation() {
        renderContent()
        applyState()
    }

    /// Expanded while hovered or during a live activity; compact wings when
    /// a standby module has something worth flanking the housing with;
    /// otherwise invisible.
    /// The one place expansion is decided, and therefore the one place the
    /// pin is honoured.
    ///
    /// Every collapse in the app — hover exit, `endDrag`, the drag-out
    /// re-arm, an arbiter presentation change, a module toggle, navigation,
    /// a screen reconfiguration, a shelf mode swap — routes through
    /// `applyState`, which is the sole caller of `panel.setState`. Guarding
    /// here covers all of them; guarding at each trigger would mean nine
    /// checks and one of them eventually missed.
    private func desiredState() -> NotchPanel.State {
        if Self.shouldExpand(isPinned: isPinned,
                             isHovered: isHovered,
                             hasLiveActivity: isShowingLiveActivity) { return .expanded }
        if standbyWings() != nil { return .compact }
        return .idle
    }

    /// Factored out and `nonisolated` — the way `isInsideForExit` is — so the
    /// pin's precedence over every other input is a test rather than a
    /// reading of the branch above.
    nonisolated static func shouldExpand(isPinned: Bool,
                                         isHovered: Bool,
                                         hasLiveActivity: Bool) -> Bool {
        isPinned || isHovered || hasLiveActivity
    }

    /// Measured size of the current expanded content, set by renderContent.
    private var expandedContentSize: CGSize = .zero

    /// Measured widths of the two chrome groups, set alongside
    /// `expandedContentSize`; the chrome-only frame is sized from them.
    private var chromeGroups = NotchPanel.ChromeGroupWidths()

    /// Whether the expanded panel is chrome alone, as last rendered.
    private var isChromeOnly = false

    /// The state most recently applied to the panel, so renderContent can
    /// tell an entrance (play the reveal) from an in-place update (do not).
    private var lastAppliedState: NotchPanel.State = .idle

    /// A file drag opens the notch straight to the shelf, because opening to
    /// the home screen would be useless: there is nowhere on it to drop.
    ///
    /// The destination is set rather than navigated to. At this moment the
    /// panel is still collapsed — the debounced expansion has only been
    /// scheduled — so `navigate` would render compact content that the
    /// expansion immediately replaces. Setting it means the panel opens
    /// already showing the shelf.
    /// Fed the raw drag-over state so the shelf can swap between its resting
    /// screen and the drop chooser. Set by AppDelegate; the coordinator does
    /// not know the service, only that someone wants the signal.
    var onFileDragActive: ((Bool) -> Void)?

    func fileDragChanged(_ active: Bool) {
        // Before any render below, so a re-measure already sees the mode the
        // view is about to display.
        onFileDragActive?(active)
        guard active else {
            // A drag that leaves before the panel ever opened set a
            // destination for a screen nobody saw. Clear it, or the next
            // plain hover would open to the shelf. Once expanded, the normal
            // collapse reset in `applyState` owns this instead.
            if lastAppliedState != .expanded, destination != .standby {
                destination = .standby
                Self.logger.notice("Drag left before opening; destination reset")
            }
            // The chooser just swapped back to the resting shelf, which is a
            // different size; re-measure or the panel keeps the old frame.
            remeasureShelfIfShowing()
            return
        }
        guard let moduleID = Destination.fileShelf.moduleID,
              arbiter.module(for: moduleID)?.isEnabled == true else {
            // Shelf switched off: a file drag is just a hover, and the panel
            // opens home as usual.
            return
        }
        if destination != .fileShelf {
            destination = .fileShelf
            Self.logger.notice("File drag; opening to the shelf")
            // Panel already expanded on another screen when the drag arrived:
            // swap to the shelf now. This is the chooser *appearing* — the
            // one resize a live drag wants, and the cursor is still at the
            // panel edge when it happens. Every later flip while the session
            // is live re-renders by observation alone; resizing the panel
            // mid-drag would move drop targets under the cursor.
            remeasureShelfIfShowing()
        }
    }

    /// Re-renders the shelf screen in place. The chooser and the resting
    /// shelf are different widths, and the panel only resizes when someone
    /// re-measures; destination changes do that, an in-place mode swap does
    /// not.
    private func remeasureShelfIfShowing() {
        guard lastAppliedState == .expanded, destination == .fileShelf else { return }
        renderContent()
        applyState()
    }

    /// Chrome controls call this; it re-renders and re-measures, since
    /// destinations differ in size.
    func navigate(to destination: Destination) {
        guard destination != self.destination else { return }
        self.destination = destination
        renderContent()
        applyState()
    }

    private func applyState() {
        guard let panel, let screen = currentScreen else { return }
        let state = desiredState()
        if lastAppliedState == .expanded && state != .expanded {
            arbiter.registeredModules.forEach { $0.notchDidCollapse() }
            // A screen is not a place to still be on the next hover — the
            // panel reopens on the arbitrated default, matching how the
            // full-lyrics takeover resets.
            destination = .standby
        }
        panel.setState(state, on: screen,
                       expandedContentSize: expandedContentSize,
                       chromeOnly: isChromeOnly,
                       chromeGroups: chromeGroups)
        lastAppliedState = state
        // Capture must not run for a panel nobody can see (hard rule 9's
        // spirit): the service tears the tap down whenever this goes false.
        audioVisualizer?.setPanelVisible(state == .expanded)
    }

    /// Measures what the expanded panel is about to display by laying the
    /// same padded content out in a throwaway hosting view. Synchronous and
    /// cheap at this size; runs only on content changes, never per frame.
    private func measureExpandedContent(_ content: AnyView?, neck: CGFloat) -> CGSize {
        guard let content else { return .zero }
        // Padding mirrors NotchOverlayView's exactly, or the measured panel
        // will not fit the rendered content.
        let probe = NSHostingView(rootView:
            content
                .padding(.top, neck + 20)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        )
        return probe.fittingSize
    }

    /// Measures a chrome group the way `measureExpandedContent` measures
    /// content: one throwaway layout pass. Measured, never assumed — the
    /// leading group changes with which doors are enabled.
    private static func measureAccessoryWidth(_ view: AnyView?) -> CGFloat {
        guard let view else { return 0 }
        return NSHostingView(rootView: view).fittingSize.width
    }

    /// Chrome alone: nothing navigated to, and no module on the notch has
    /// anything to show in its expanded view. The modules asked are the
    /// ones the arbiter is presenting — the doors' modules are never in
    /// standby (`wantsCompactDisplay` is false) and are reached only by
    /// navigating, which the first clause already covers.
    private func chromeOnly() -> Bool {
        guard destination == .standby else { return false }
        return !presentedModules().contains { $0.hasExpandedContent }
    }

    /// The enabled modules whose expanded views `content(for:)` stacks.
    private func presentedModules() -> [any NotchModule] {
        let ids: [ModuleID]
        switch arbiter.presentation {
        case .standby(let standby): ids = standby
        case .liveActivity(let id): ids = [id]
        }
        return ids.compactMap { arbiter.module(for: $0) }.filter { $0.isEnabled }
    }

    private var isShowingLiveActivity: Bool {
        if case .liveActivity = arbiter.presentation { return true }
        return false
    }

    /// The first standby module offering wing content provides both wings.
    private func standbyWings() -> (leading: AnyView?, trailing: AnyView?)? {
        guard case .standby(let ids) = arbiter.presentation else { return nil }
        for id in ids {
            guard let module = arbiter.module(for: id) else { continue }
            let leading = module.makeCompactLeadingView()
            let trailing = module.makeCompactTrailingView()
            if leading != nil || trailing != nil {
                return (leading, trailing)
            }
        }
        return nil
    }

    private func renderContent() {
        guard let panel, let screen = currentScreen else { return }
        let housing = NotchPanel.notchRect(on: screen)
        let neck = housing.height
        switch desiredState() {
        case .expanded:
            let chromeOnly = chromeOnly()
            // Chrome-only still hands the overlay a content view, empty or
            // not: nil is what tells it to draw the compact silhouette and
            // drop the band, and the band is the whole point of the state.
            // The overlay suppresses the content region itself, padding and
            // all, on the flag — an "empty" view still carries neck+40 of
            // fixed padding, which is taller than the whole chrome-only bar.
            let view = content(for: arbiter.presentation) ?? AnyView(EmptyView())
            expandedContentSize = measureExpandedContent(view, neck: neck)
            let leading = leadingAccessory()
            let trailing = trailingAccessory()
            chromeGroups = NotchPanel.ChromeGroupWidths(
                leading: Self.measureAccessoryWidth(leading),
                trailing: Self.measureAccessoryWidth(trailing))
            if chromeOnly != isChromeOnly {
                Self.logger.notice("Expanded panel \(chromeOnly ? "chrome-only, nothing to show" : "showing content", privacy: .public); chrome groups \(self.chromeGroups.leading, privacy: .public) + \(self.chromeGroups.trailing, privacy: .public)")
            }
            isChromeOnly = chromeOnly
            // Where the housing lands inside the frame the panel is about
            // to occupy, so the band can flank it by position. Computed
            // from the same pure function `setState` uses with the same
            // inputs, so the two cannot disagree.
            let rect = NotchPanel.expandedRect(housing: housing,
                                               contentSize: expandedContentSize,
                                               chromeOnly: chromeOnly,
                                               chromeGroups: chromeGroups)
            let housingLocal = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
            // The floor in `expandedRect` is derived so the housing clamp
            // never fires. If it does, the floor and the band layout have
            // drifted apart and a button is sitting somewhere other than
            // its corner — visible, but easy to mistake for a design choice
            // (which is how the last two band bugs survived).
            let band = NotchOverlayView.bandLayout(panelWidth: rect.width,
                                                   housingLocal: housingLocal,
                                                   groups: chromeGroups)
            if band.isClamped {
                Self.logger.error("Chrome band clamped off the panel corner: panel \(rect.width, privacy: .public)pt, groups \(self.chromeGroups.leading, privacy: .public)+\(self.chromeGroups.trailing, privacy: .public), insets \(band.leadingInset, privacy: .public)/\(band.trailingInset, privacy: .public), floor \(NotchPanel.bandMinWidth(housingWidth: housing.width, groups: self.chromeGroups), privacy: .public)")
            }
            // The emerge entrance plays only when the panel is opening —
            // content swaps mid-display (lyrics arriving, hover re-renders)
            // must not re-bloom. Hard rule 8: skipped under Reduce Motion.
            let entering = lastAppliedState != .expanded
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.setContent(view, neckHeight: neck,
                             housingLocalRange: housingLocal,
                             panelWidth: rect.width,
                             chromeGroups: chromeGroups,
                             chromeOnly: chromeOnly,
                             reveal: entering,
                             topLeadingAccessory: leading,
                             topTrailingAccessory: trailing)
        case .compact:
            isChromeOnly = false
            let wings = standbyWings()
            panel.setContent(nil, leadingWing: wings?.leading, trailingWing: wings?.trailing,
                             neckHeight: neck)
        case .idle:
            isChromeOnly = false
            panel.setContent(nil, neckHeight: neck)
        }
    }

    /// Top-left chrome: the way back out of a navigated screen, or the way
    /// into Settings while in standby.
    private func leadingAccessory() -> AnyView? {
        guard destination == .standby else {
            return AnyView(PanelChromeButton(symbol: "chevron.backward", help: "Back") {
                [weak self] in self?.navigate(to: .standby)
            })
        }
        // Settings first, then a door per enabled screen. Doors are
        // navigation and so is Back, which replaces this whole group on a
        // navigated screen — they belong on the same side, not opposite the
        // control that undoes them.
        let doors = availableDoors()
        return AnyView(HStack(spacing: 2) {
            PanelChromeButton(symbol: "gearshape", help: "Settings") {
                [weak self] in self?.openSettings()
            }
            ForEach(doors, id: \.1) { destination, symbol, help in
                PanelChromeButton(symbol: symbol, help: help) {
                    [weak self] in self?.navigate(to: destination)
                }
            }
        })
    }

    /// Screens reachable right now: a door only exists while the feature
    /// behind it is on.
    private func availableDoors() -> [(Destination, String, String)] {
        [(.clipboard, "doc.on.clipboard", "Clipboard history"),
         (.fileShelf, "tray.full", "File shelf")]
            .filter { arbiter.module(for: $0.0.moduleID ?? "")?.isEnabled == true }
    }

    /// Opens the settings window from the panel's gear.
    ///
    /// **`@Environment(\.openSettings)` does not work here.** SwiftUI fills
    /// that value in for views inside the `App`'s scene graph, next to the
    /// `Settings` scene that services it. This panel is not in that graph:
    /// `AppDelegate` builds `NotchPanel` itself and hosts its SwiftUI in an
    /// `NSHostingView`, so the environment value is never populated and
    /// calling it does nothing at all. The selector is the only route from
    /// here. `SettingsMenuItem` in PopNotchApp.swift *can* use the
    /// environment, because it genuinely is in the scene graph.
    private func openSettings() {
        // Hard rule 4 carve-out, the same narrow one SettingsMenuItem
        // documents: activation is a direct response to the user clicking
        // this button, and without it the window opens behind the frontmost
        // app. No hover path activates anything, ever.
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .popNotchOpenSettings, object: nil)
        // Verify by looking for the window, not by trusting a return value.
        // The previous implementation logged `sendAction`'s Bool, which
        // measured **true while creating no window at all** — it reported
        // eleven successes for a button the user was watching do nothing.
        // A signal that cannot fail is not a signal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if Self.settingsWindow() != nil {
                Self.logger.notice("Settings opened from panel chrome")
            } else {
                Self.logger.error("Settings did not open; no settings window exists")
            }
        }
    }

    /// SwiftUI names its `Settings` scene window with a stable identifier.
    nonisolated static func settingsWindow() -> NSWindow? {
        MainActor.assumeIsolated {
            NSApp.windows.first {
                ($0.identifier?.rawValue ?? "").contains("Settings")
                    || $0.title.localizedCaseInsensitiveContains("settings")
            }
        }
    }

    /// Top-right chrome: the panel-level toggles, hard into the corner.
    ///
    /// Shown for the whole expanded state, independent of which modules are
    /// on screen or whether anything is playing. Navigation lives on the
    /// leading side; these two change how the panel itself behaves.
    private func trailingAccessory() -> AnyView? {
        // Bound outside the ViewBuilder so the view captures the service, not
        // this coordinator: the panel retains the view, and the coordinator
        // retains the panel.
        let keepAwake = caffeinate
        let pinned = isPinned
        let canPin = pinState != nil
        guard keepAwake != nil || canPin else { return nil }
        return AnyView(HStack(spacing: 2) {
            if let keepAwake {
                CaffeinateControl(service: keepAwake)
            }
            if canPin {
                PinControl(isPinned: pinned) { [weak self] in
                    self?.setPinned(!pinned)
                }
            }
        })
    }

    /// Builds the SwiftUI content for the current state.
    ///
    /// In standby the modules sit side by side, showing their compact views
    /// while collapsed and their expanded views once the notch opens — the
    /// collapsed panel is exactly notch-sized, so anything drawn there is
    /// hidden behind the camera housing anyway. A live activity gets the
    /// notch to itself.
    private func content(for presentation: NotchPresentation) -> AnyView? {
        switch presentation {
        case .standby(let ids):
            let modules = ids.compactMap { arbiter.module(for: $0) }
            guard !modules.isEmpty else { return nil }
            // Expanded content whenever the panel is expanded for ANY reason
            // — hover, live activity, or a pinned takeover. Keying this off
            // the cursor alone swapped in compact content (and shrank the
            // panel around it) the moment the cursor left a pinned lyrics
            // view: user-observed bug.
            if desiredState() == .expanded {
                // A navigated screen replaces the arbitrated stack wholesale.
                // Falls through if its module got disabled underneath it, so
                // the panel can never show a screen whose feature is off.
                if let moduleID = destination.moduleID,
                   let module = arbiter.module(for: moduleID), module.isEnabled {
                    return module.makeExpandedView()
                }
                // Stacked, not side by side: several expanded modules in a row
                // overflow the panel and truncate (observed with media plus
                // five stats). The notch grows downward, so height is the
                // dimension there is room in.
                let views = modules.map { $0.makeExpandedView() }
                return AnyView(
                    VStack(spacing: 8) {
                        ForEach(Array(views.enumerated()), id: \.offset) { $0.element }
                    }
                )
            }
            let views = modules.map { $0.makeCompactView() }
            return AnyView(
                HStack(spacing: 12) {
                    ForEach(Array(views.enumerated()), id: \.offset) { $0.element }
                }
            )
        case .liveActivity(let id):
            return arbiter.module(for: id)?.makeExpandedView()
        }
    }

    // MARK: - Expiry

    /// Schedules exactly one timer, at the moment the activity yields. No
    /// polling, and nothing scheduled at all when the notch is idle.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil

        guard let remaining = arbiter.timeUntilExpiry else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.arbiter.tick()
                // tick() may promote a queued activity; if so its own expiry
                // is scheduled by the resulting presentation change. If the
                // presentation did not change, nothing is pending.
                if self.arbiter.timeUntilExpiry == nil {
                    self.expiryTimer = nil
                }
            }
        }
    }
}
