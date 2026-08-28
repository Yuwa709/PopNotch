import SwiftUI

/// A module's permanent identifier.
///
/// These strings are persisted in `AppSettings`, which makes them permanent
/// API: renaming one silently resets that user's preference for the module,
/// because the stored key no longer matches anything. Add new IDs freely;
/// never change an existing one.
typealias ModuleID = String

/// How strongly a module wants the notch.
///
/// Higher interrupts lower; equal priority queues in request order. Raw
/// values are spaced by ten so tiers can be inserted later without
/// renumbering the ones already persisted.
enum ModulePriority: Int, Codable, Comparable, Sendable {
    /// Always-on compact information: system stats, weather.
    case ambient = 0
    /// Routine notifications that can wait their turn.
    case standard = 10
    /// Media changes — the reason most people look at the notch.
    case elevated = 20
    /// Direct results of a user action, such as a file drop.
    case urgent = 30

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A module's transient claim on the notch.
struct LiveActivityRequest: Equatable, Sendable {
    let moduleID: ModuleID
    let priority: ModulePriority
    /// How long the module holds the notch before yielding to the default
    /// state. The arbiter owns the timing; the module only asks.
    let duration: TimeInterval
}

/// One feature that can display in the notch.
///
/// Modules never reference each other and never touch `NotchPanel`. The
/// arbiter owns the panel and decides what displays; a module only describes
/// itself and reacts to going on and off screen.
///
/// Views are returned type-erased as `AnyView` deliberately. An associated
/// type would make the protocol non-existential, and the arbiter must hold a
/// heterogeneous `[any NotchModule]`. The erasure cost is one allocation per
/// state change, not per frame.
@MainActor
protocol NotchModule: AnyObject {

    /// Permanent. See `ModuleID`.
    var id: ModuleID { get }

    /// Shown in Settings. Safe to change; not persisted.
    var displayName: String { get }

    var priority: ModulePriority { get }

    /// Mirrors the user's choice in Settings. The arbiter skips disabled
    /// modules entirely — they receive no visibility callbacks and must not
    /// run timers.
    var isEnabled: Bool { get set }

    /// Whether this module contributes to the default collapsed state.
    var wantsCompactDisplay: Bool { get }

    /// Non-nil when the module currently wants to take over the notch.
    /// The arbiter polls this; the module does not push.
    var pendingLiveActivity: LiveActivityRequest? { get }

    /// While true, the coordinator keeps the notch expanded regardless of
    /// hover — for a takeover view the user is actively reading, like full
    /// lyrics. Default false.
    var wantsPinnedExpansion: Bool { get }

    func makeCompactView() -> AnyView
    func makeExpandedView() -> AnyView

    /// Content for the collapsed panel's wings, drawn in the menu bar band
    /// flanking the housing. Returning non-nil is what makes the collapsed
    /// notch widen from invisible to the compact state — return nil whenever
    /// there is nothing worth occupying menu bar space for.
    func makeCompactLeadingView() -> AnyView?
    func makeCompactTrailingView() -> AnyView?

    /// The module is now on screen. Start sampling here, not in `init`.
    func didBecomeVisible()

    /// The module is now off screen.
    ///
    /// **Hard rule 9: invalidate every timer here.** This app runs for days;
    /// a module that keeps polling while invisible is the main way it would
    /// burn battery.
    func didResignVisible()
}

extension NotchModule {
    var wantsCompactDisplay: Bool { true }
    var pendingLiveActivity: LiveActivityRequest? { nil }
    var wantsPinnedExpansion: Bool { false }
    func didBecomeVisible() {}
    func didResignVisible() {}
    func makeCompactLeadingView() -> AnyView? { nil }
    func makeCompactTrailingView() -> AnyView? { nil }
}
