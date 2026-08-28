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
/// - Modules not currently on screen are told so, and must stop their timers
///
/// Time is injected so tests are deterministic and never sleep.
@MainActor
final class NotchArbiter {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Arbiter")

    private(set) var presentation: NotchPresentation = .standby([])

    /// Fires whenever `presentation` actually changes.
    var onPresentationChange: ((NotchPresentation) -> Void)?

    private var modules: [any NotchModule] = []
    private var active: (request: LiveActivityRequest, expiresAt: TimeInterval)?
    private var queue: [LiveActivityRequest] = []
    private var visibleIDs: Set<ModuleID> = []
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
        updateVisibility(for: next)
        Self.logger.notice("Presentation -> \(String(describing: next), privacy: .public)")
        onPresentationChange?(next)
    }

    /// Tells modules when they go on and off screen. Hard rule 9 depends on
    /// this: a module that is off screen must not be polling.
    private func updateVisibility(for presentation: NotchPresentation) {
        let nowVisible: Set<ModuleID>
        switch presentation {
        case .standby(let ids): nowVisible = Set(ids)
        case .liveActivity(let id): nowVisible = [id]
        }

        for id in visibleIDs.subtracting(nowVisible) {
            module(for: id)?.didResignVisible()
        }
        for id in nowVisible.subtracting(visibleIDs) {
            module(for: id)?.didBecomeVisible()
        }
        visibleIDs = nowVisible
    }
}
