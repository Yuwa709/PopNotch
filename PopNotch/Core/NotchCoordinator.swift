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
    init(settings: SettingsStore, arbiter: NotchArbiter? = nil) {
        self.settings = settings
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
        arbiter.enablementDidChange()
        renderContent()
        applyState()
    }

    func requestLiveActivity(_ request: LiveActivityRequest) {
        arbiter.requestLiveActivity(request)
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
    private func desiredState() -> NotchPanel.State {
        if isHovered || isShowingLiveActivity { return .expanded }
        if standbyWings() != nil { return .compact }
        return .idle
    }

    /// Measured size of the current expanded content, set by renderContent.
    private var expandedContentSize: CGSize = .zero

    private func applyState() {
        guard let panel, let screen = currentScreen else { return }
        panel.setState(desiredState(), on: screen, expandedContentSize: expandedContentSize)
    }

    /// Measures what the expanded panel is about to display by laying the
    /// same padded content out in a throwaway hosting view. Synchronous and
    /// cheap at this size; runs only on content changes, never per frame.
    private func measureExpandedContent(_ content: AnyView?, neck: CGFloat) -> CGSize {
        guard let content else { return .zero }
        let probe = NSHostingView(rootView:
            content
                .padding(.top, neck + 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        )
        return probe.fittingSize
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
        let neck = NotchPanel.notchRect(on: screen).height
        switch desiredState() {
        case .expanded:
            let view = content(for: arbiter.presentation)
            expandedContentSize = measureExpandedContent(view, neck: neck)
            panel.setContent(view, neckHeight: neck)
        case .compact:
            let wings = standbyWings()
            panel.setContent(nil, leadingWing: wings?.leading, trailingWing: wings?.trailing, neckHeight: neck)
        case .idle:
            panel.setContent(nil, neckHeight: neck)
        }
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
            if isHovered {
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
            Task { @MainActor in
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
