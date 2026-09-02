import SwiftUI

/// The stats door: everything the data layer already reads, on one screen.
///
/// Reads only what `BatteryService`, `SystemStatsService` and
/// `SystemStatsHistory` already publish — this view adds no IOKit of its own,
/// which is why it can be a pure function of three observable objects.
///
/// Fixed width, intrinsic height, no scrolling: the panel sizes itself to the
/// content (`NotchCoordinator.measureExpandedContent`), so a scroll view would
/// measure as its own ideal height and defeat that. The width is chosen to
/// leave headroom under the 690pt panel ceiling — see `contentWidth`.
struct SystemStatsPageView: View {

    let stats: SystemStatsService
    let battery: BatteryService
    let history: SystemStatsHistory

    /// 560pt. With the overlay's 32pt side border either side the panel comes
    /// to 624pt, inside the 690 ceiling with 66pt to spare — unlike the
    /// resting shelf, which sits exactly on it.
    static let contentWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SystemStatsPageHeader(snapshot: battery.snapshot)
            cards
            conditionLine
            ChargeHistoryGraph(points: history.points)
            SystemStatsMachineRows(stats: stats.stats)
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var cards: some View {
        HStack(spacing: 10) {
            let snapshot = battery.snapshot
            StatCard(title: "Capacity",
                     value: snapshot?.displayHealthPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                     detail: snapshot?.cycleCount.map { "\($0) cycles" } ?? "Cycles unknown")
            StatCard(title: "Temperature",
                     value: snapshot?.temperatureCelsius
                        .map { String(format: "%.1f°", $0) } ?? "—",
                     detail: "Battery pack")
            StatCard(title: "Power",
                     value: snapshot?.watts.map { String(format: "%.1f W", $0) } ?? "—",
                     detail: powerDirection(snapshot))
            StatCard(title: "Adapter",
                     value: adapterValue(snapshot),
                     detail: adapterDetail(snapshot))
        }
    }

    /// macOS's verdict, kept visually apart from the Capacity percentage so
    /// the two are never read as one number. Absent rather than guessed when
    /// the system declines to say.
    private var conditionLine: some View {
        HStack(spacing: 6) {
            Text("CONDITION")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            Text(battery.snapshot?.conditionDescription ?? "Not reported")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("reported by macOS")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
            Spacer(minLength: 0)
        }
    }

    /// Which way the watts are flowing. The sign of `amperageMilliamps` is
    /// the source of truth; the label never guesses from the wattage alone.
    private func powerDirection(_ snapshot: BatterySnapshot?) -> String {
        guard let amperage = snapshot?.amperageMilliamps else { return "Draw unknown" }
        if amperage > 0 { return "Into battery" }
        if amperage < 0 { return "From battery" }
        return "Idle"
    }

    private func adapterValue(_ snapshot: BatterySnapshot?) -> String {
        guard snapshot?.adapterIsPresent == true else { return "Not connected" }
        return snapshot?.adapterWatts.map { "\($0) W" } ?? "Connected"
    }

    /// The adapter's own `Description` string, shown verbatim — it is a
    /// category ("pd charger"), not a product name, and is never parsed.
    private func adapterDetail(_ snapshot: BatterySnapshot?) -> String {
        guard snapshot?.adapterIsPresent == true else { return "On battery" }
        return snapshot?.adapterName ?? "Adapter attached"
    }
}

/// Charge, charging state, and whichever of the two time estimates applies.
struct SystemStatsPageHeader: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(snapshot?.percentage.map { "\($0)%" } ?? "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text(state)
                    .font(.system(size: 12, weight: .semibold))
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if snapshot?.isLowPowerMode == true {
                Text("LOW POWER")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.yellow.opacity(0.18)))
                    .foregroundStyle(.yellow)
            }
        }
    }

    private var state: String {
        guard let snapshot else { return "Battery unavailable" }
        if snapshot.isFullyCharged == true { return "Fully charged" }
        if snapshot.isCharging == true { return "Charging" }
        if snapshot.isExternalConnected == true { return "Plugged in, not charging" }
        return "On battery"
    }

    /// Time to full while charging, time to empty while discharging. Never
    /// both, and never a zero standing in for a missing estimate — the data
    /// layer already nils out the sentinel and the on-AC zero.
    private var time: String {
        guard let snapshot else { return "—" }
        if let full = snapshot.timeToFullMinutes { return "\(formatted(full)) until full" }
        if let empty = snapshot.timeToEmptyMinutes { return "\(formatted(empty)) remaining" }
        return snapshot.isFullyCharged == true ? "" : "Estimating…"
    }

    private func formatted(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// One compact card. Fixed metrics so the four line up on the same baseline.
struct StatCard: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
    }
}
