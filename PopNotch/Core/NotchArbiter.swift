import Foundation
import os

/// What the notch should be showing.
enum NotchPresentation: Equatable {
    /// No live activity: the compact views of enabled always-on modules,
    /// in registration order.
    case standby([ModuleID])
    /// One module has temporarily taken the notch.
    case liveActivity(ModuleID)
}

/// What the panel is physically showing, as the coordinator last applied it.
///
/// Visibility needs this as well as the presentation, because being
/// arbitrated onto the notch is not the same as being on screen. Treating
/// standby membership as "visible" told every always-on module it was on
/// screen at launch and never otherwise, so their timers ran for the life of
/// the process (zero `didResignVisible` calls under lldb, 2026-09-13).
enum PanelSurface: Equatable {
    /// Idle, or showing the compact wings. Nothing collapsed counts as
    /// visible: wing content is push-driven and must never need a timer.
    case collapsed
    /// Open on the arbitrated default — the standby stack, or a live
    /// activity's view.
    case expanded
    /// Open on a screen a chrome control navigated to. It replaces the
    /// standby stack wholesale and owns its own sampling lifecycle.
    case navigated
}

/// Decides what the notch displays.
///
/// Deliberately free of AppKit: this type is pure decision logic so it can be
/// tested without a screen, which is most of what is machine-verifiable in
/// this project. A separate coordinator subscribes to `onPresentationChange`
/// and drives `NotchPanel`.
///
/// ## Rules
/// - Higher priority interrupts lower; the interrupted activity is dropped
/// - Equal or lower priority queues, FIFO within a priority
/// - An activity yields when its duration elapses; the highest-priority
///   queued request takes over, otherwise the notch returns to standby
/// - A module is visible only while its expanded view is on screen (see
///   `PanelSurface`); off screen, it is told so and must stop its timers
///
/// Time is injected so tests are deterministic and never sleep.
@MainActor
final class NotchArbiter {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Arbiter")

    private(set) var presentation: NotchPresentation = .standby([])

    /// Fires whenever `presentation` actually changes.
    var onPresentationChange: ((NotchPresentation) -> Void)?

    /// The modules last told they are on screen. Exposed so "nothing is
    /// visible behind the collapsed wings" is a test rather than a comment.
    private(set) var visibleIDs: Set<ModuleID> = []

    private var modules: [any NotchModule] = []
    private var active: (request: LiveActivityRequest, expiresAt: TimeInterval)?
    private var queue: [LiveActivityRequest] = []
    /// Collapsed until the coordinator says otherwise, so a panel that was
    /// never created shows nobody.
    private var surface: PanelSurface = .collapsed
    private let now: () -> TimeInterval

    /// `systemUptime` rather than wall clock: it does not jump when the user
    /// changes the date or the machine syncs time.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    // MARK: - Registration

    func register(_ module: any NotchModule) {
        guard !modules.contains(where: { $0.id == module.id }) else {
            Self.logger.error("Duplicate module ID \(module.id, privacy: .public); ignoring")
            return
        }
        modules.append(module)
        recompute()
    }

    func module(for id: ModuleID) -> (any NotchModule)? {
        modules.first { $0.id == id }
    }

    /// Registration order, for Settings to list.
    var registeredModules: [any NotchModule] { modules }

    /// Call after changing any module's `isEnabled`, so standby and the
    /// active activity are re-evaluated.
    func enablementDidChange() {
        if let active, module(for: active.request.moduleID)?.isEnabled != true {
            Self.logger.notice("Active module \(active.request.moduleID, privacy: .public) disabled; yielding")
            self.active = nil
            activateNextQueued()
        }
        queue.removeAll { module(for: $0.moduleID)?.isEnabled != true }
        recompute()
    }

    // MARK: - Live activities

    func requestLiveActivity(_ request: LiveActivityRequest) {
        guard module(for: request.moduleID)?.isEnabled == true else {
            Self.logger.notice("Ignoring activity from unknown or disabled module \(request.moduleID, privacy: .public)")
            return
        }

        if let current = active {
            if request.priority > current.request.priority {
                Self.logger.notice("\(request.moduleID, privacy: .public) preempts \(current.request.moduleID, privacy: .public)")
                // Dropped, not re-queued: these are transient notices, and a
                // stale one resurfacing after the interruption reads as a bug.
                start(request)
            } else {
                queue.append(request)
                Self.logger.notice("\(request.moduleID, privacy: .public) queued behind \(current.request.moduleID, privacy: .public)")
            }
        } else {
            start(request)
        }
        recompute()
    }

    /// Seconds until the active activity yields, or nil when nothing is
    /// active. Lets the coordinator schedule a single one-shot timer at the
    /// exact moment instead of polling — hard rule 9 by construction.
    var timeUntilExpiry: TimeInterval? {
        guard let active else { return nil }
        return max(0, active.expiresAt - now())
    }

    /// Expires the active activity if its duration has elapsed. Driven by the
    /// coordinator; the arbiter owns no timer of its own so it cannot leak one.
    func tick() {
        guard let current = active, now() >= current.expiresAt else { return }
        Self.logger.notice("\(current.request.moduleID, privacy: .public) yielded")
        active = nil
        activateNextQueued()
        recompute()
    }

    private func start(_ request: LiveActivityRequest) {
        active = (request, now() + request.duration)
    }

    /// Highest priority wins; FIFO among equals, since `firstIndex` finds the
    /// earliest occurrence of the maximum.
    private func activateNextQueued() {
        guard let best = queue.map(\.priority).max(),
              let index = queue.firstIndex(where: { $0.priority == best })
        else { return }
        start(queue.remove(at: index))
    }

    // MARK: - Presentation

    private func recompute() {
        let next: NotchPresentation
        if let active {
            next = .liveActivity(active.request.moduleID)
        } else {
            next = .standby(modules.filter { $0.isEnabled && $0.wantsCompactDisplay }.map(\.id))
        }

        guard next != presentation else { return }
        presentation = next
        updateVisibility()
        Self.logger.notice("Presentation -> \(String(describing: next), privacy: .public)")
        onPresentationChange?(next)
    }

    // MARK: - Visibility

    /// Called by the coordinator after every state it applies to the panel.
    ///
    /// Re-checks even when the surface has not changed: a module's expanded
    /// content can appear while the panel stays open (music starting under
    /// the cursor), and the coordinator re-applies state on exactly those
    /// changes.
    func panelDidApply(_ surface: PanelSurface) {
        self.surface = surface
        updateVisibility()
    }

    /// Tells modules when their expanded view goes on and off screen. Hard
    /// rule 9 depends on this: a module that is off screen must not be
    /// polling.
    ///
    /// - Collapsed: nobody, wings included.
    /// - A live activity: its module, whether or not a screen was navigated
    ///   to — the coordinator draws the activity over either.
    /// - Standby, open on the stack: the modules with something to draw, by
    ///   the same `hasExpandedContent` filter the coordinator stacks with,
    ///   so the two cannot disagree. System stats has no expanded row and is
    ///   never visible here.
    /// - Standby, open on a navigated screen: nobody.
    private func updateVisibility() {
        let nowVisible: Set<ModuleID>
        switch (presentation, surface) {
        case (_, .collapsed), (.standby, .navigated):
            nowVisible = []
        case (.liveActivity(let id), _):
            nowVisible = [id]
        case (.standby(let ids), .expanded):
            nowVisible = Set(ids.filter { module(for: $0)?.hasExpandedContent == true })
        }
        guard nowVisible != visibleIDs else { return }

        let resigned = visibleIDs.subtracting(nowVisible)
        let became = nowVisible.subtracting(visibleIDs)
        // Recorded before the callbacks, so a module reacting to one sees
        // the settled state.
        visibleIDs = nowVisible
        Self.logger.notice("Visible -> \(String(describing: nowVisible.sorted()), privacy: .public)")
        for id in resigned {
            module(for: id)?.didResignVisible()
        }
        for id in became {
            module(for: id)?.didBecomeVisible()
        }
    }
}
