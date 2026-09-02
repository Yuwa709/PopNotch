import SwiftUI

/// Charge percentage over the last 24 hours, drawn from `SystemStatsHistory`.
///
/// Hand-drawn rather than Swift Charts: the panel measures this view to size
/// itself, and a fixed `Path` in a fixed frame measures predictably where a
/// chart's own layout would not. It also keeps the visual language the rest
/// of the overlay uses.
///
/// A point whose `batteryPercentage` is nil is dropped rather than plotted as
/// zero — the data layer's contract is that a missing reading is a gap, and a
/// gap drawn as zero is a cliff that never happened.
struct ChargeHistoryGraph: View {

    let points: [SystemStatsPoint]

    /// The window the graph claims to show. Points older than this are not
    /// drawn: a file left over from last week is not "the last 24 hours".
    static let window: TimeInterval = 24 * 60 * 60
    static let height: CGFloat = 104

    /// Reference date, injectable so the layout test is not clock-dependent.
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CHARGE, LAST 24H")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                if let span = spanLabel {
                    Text(span)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .monospacedDigit()
                }
            }
            Group {
                if let series = Self.series(from: points, now: now) {
                    plot(series)
                } else {
                    emptyState
                }
            }
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        }
    }

    /// The plottable series, or nil when there is not enough to draw a line.
    ///
    /// Fewer than two points is an empty state, not a graph: one point has no
    /// line and an axis drawn for it is a lie about the range.
    static func series(from points: [SystemStatsPoint], now: Date) -> [(Date, Int)]? {
        let cutoff = now.addingTimeInterval(-window)
        let usable = points
            .filter { $0.timestamp >= cutoff }
            .compactMap { point -> (Date, Int)? in
                point.batteryPercentage.map { (point.timestamp, $0) }
            }
        return usable.count >= 2 ? usable : nil
    }

    private var spanLabel: String? {
        guard let series = Self.series(from: points, now: now),
              let first = series.first?.0, let last = series.last?.0 else { return nil }
        let minutes = Int(last.timeIntervalSince(first) / 60)
        if minutes < 60 { return "\(minutes)m of history" }
        return "\(minutes / 60)h \(minutes % 60)m of history"
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.3))
            Text("Not enough history yet")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("Charge is sampled once a minute while this page is open.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fixed 0–100 y-axis. Auto-ranging would make a 3% dip look like a
    /// collapse, which is the classic way a battery graph misleads.
    private func plot(_ series: [(Date, Int)]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 8
            let width = max(1, size.width - inset * 2)
            let height = max(1, size.height - inset * 2)
            let start = series.first?.0 ?? now
            let span = max(1, series.last!.0.timeIntervalSince(start))

            let positions = series.map { entry in
                CGPoint(
                    x: inset + width * CGFloat(entry.0.timeIntervalSince(start) / span),
                    y: inset + height * (1 - CGFloat(min(100, max(0, entry.1))) / 100))
            }

            ZStack {
                ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                    Path { path in
                        let y = inset + height * fraction
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: inset + width, y: y))
                    }
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                }
                Path { path in
                    path.move(to: CGPoint(x: positions[0].x, y: inset + height))
                    positions.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: positions[positions.count - 1].x, y: inset + height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.green.opacity(0.28), .green.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: positions[0])
                    positions.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(.green.opacity(0.9), style: StrokeStyle(lineWidth: 1.5,
                                                                lineCap: .round,
                                                                lineJoin: .round))
            }
            .overlay(alignment: .topLeading) {
                Text("100%")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.leading, inset + 2)
            }
            .overlay(alignment: .bottomLeading) {
                Text("0%")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.leading, inset + 2)
            }
        }
    }
}

/// CPU, GPU, memory and disk as compact rows beneath the graph.
///
/// A stat that cannot be read is shown as a dash with no bar, matching
/// `SystemStats`'s rule that a missing reading is never rendered as zero.
struct SystemStatsMachineRows: View {
    let stats: SystemStats

    var body: some View {
        VStack(spacing: 6) {
            row("CPU", symbol: "cpu", fraction: stats.cpuFraction)
            row("GPU", symbol: "cpu.fill", fraction: stats.gpuFraction)
            row("Memory", symbol: "memorychip", fraction: stats.memoryFraction)
            diskRow
        }
    }

    private var diskRow: some View {
        let fraction: Double? = {
            guard let free = stats.diskFreeBytes, let total = stats.diskTotalBytes, total > 0
            else { return nil }
            return Double(total - free) / Double(total)
        }()
        let detail = stats.diskFreeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free"
        }
        return row("Disk", symbol: "internaldrive", fraction: fraction, trailing: detail)
    }

    private func row(_ title: String, symbol: String,
                     fraction: Double?, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    if let fraction {
                        Capsule()
                            .fill(.white.opacity(0.55))
                            .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
                    }
                }
            }
            .frame(height: 5)
            Text(trailing ?? fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 74, alignment: .trailing)
        }
        .frame(height: 14)
    }
}
