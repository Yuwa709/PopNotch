import Foundation
import AppKit
import Observation
import os

/// One minute's worth of machine state, as the future stats page will plot it.
///
/// Deliberately narrow: the fields a graph can draw over time, not everything
/// the services expose. Every one is optional — a stat that could not be read
/// leaves a gap in the line rather than a zero, which would draw as a cliff.
struct SystemStatsPoint: Codable, Equatable {
    var timestamp: Date = .distantPast
    var cpuFraction: Double?
    var memoryFraction: Double?
    var gpuFraction: Double?
    var batteryPercentage: Int?
    var batteryWatts: Double?
    var batteryTemperatureCelsius: Double?
    var isCharging: Bool?
}

/// A fixed-size ring of samples, persisted as JSON.
///
/// ## Why a ring rather than an array
/// This app runs for days. An append-only array of 60s samples is an
/// unbounded leak with a graph attached to it — a week is ten thousand
/// points. The ring writes over its oldest entry instead, so memory and file
/// size are both constant from the first minute onward.
///
/// ## Why not UserDefaults
/// `AppSettings` is what the user configured; this is what the machine did.
/// Mixing them would mean every sample rewrites the settings blob, a
/// migration risk for data that is regenerable and worthless if lost.
/// This lives in its own file under Application Support and can be deleted
/// at any time with no consequence beyond an empty graph.
@MainActor
@Observable
final class SystemStatsHistory {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "StatsHistory")

    /// 24 hours at one sample a minute. The graph's honest maximum span:
    /// beyond a day, per-minute resolution is noise a notch cannot draw.
    @ObservationIgnored
    static let capacity = 1440

    @ObservationIgnored
    static let interval: TimeInterval = 60

    /// Samples oldest-first. Rebuilt from the ring on every mutation, which
    /// is 1440 elements once a minute — far cheaper than the observation
    /// traffic it saves a view.
    private(set) var points: [SystemStatsPoint] = []

    @ObservationIgnored private var ring: [SystemStatsPoint?]
    @ObservationIgnored private var writeIndex = 0
    @ObservationIgnored private var count = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var displayAsleep = false


    /// Whether a timer is currently scheduled.
    ///
    /// Exposed so "nothing polls while nobody is looking" is something a test
    /// can assert rather than something a comment claims.
    var isSampling: Bool { timer != nil }

    @ObservationIgnored private let stats: SystemStatsService?
    @ObservationIgnored private let battery: BatteryService?
    @ObservationIgnored private let storeURL: URL?

    /// `storeURL` is injectable so tests round-trip through a temporary file
    /// rather than the user's real history.
    init(stats: SystemStatsService? = nil,
         battery: BatteryService? = nil,
         storeURL: URL? = SystemStatsHistory.defaultStoreURL()) {
        self.stats = stats
        self.battery = battery
        self.storeURL = storeURL
        self.ring = Array(repeating: nil, count: Self.capacity)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displayDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)

        load()
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Storage location

    /// `~/Library/Application Support/PopNotch/stats-history.json`.
    ///
    /// Nil if the directory cannot be resolved or created — a sandbox denial
    /// or a full disk. The history then runs in memory, which is the correct
    /// degradation: this data is regenerable and never worth failing over.
    nonisolated static func defaultStoreURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let directory = base.appendingPathComponent("PopNotch", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create \(directory.path, privacy: .public); history stays in memory")
            return nil
        }
        return directory.appendingPathComponent("stats-history.json")
    }

    // MARK: - Lifecycle

    func start() {
        subscribers += 1
        stats?.start()
        battery?.start()
        updateTimer()
    }

    func stop() {
        guard subscribers > 0 else { return }
        subscribers -= 1
        stats?.stop()
        battery?.stop()
        updateTimer()
    }

    @objc private func displayDidSleep() {
        displayAsleep = true
        updateTimer()
    }

    @objc private func displayDidWake() {
        displayAsleep = false
        updateTimer()
    }

    private func updateTimer() {
        let shouldRun = subscribers > 0 && !displayAsleep
        guard shouldRun != (timer != nil) else { return }

        if shouldRun {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Self.logger.notice("History sampling started (\(self.subscribers, privacy: .public) subscribers)")
        } else {
            timer?.invalidate()
            timer = nil
            // The ring is worth keeping across a suspension; losing an hour
            // of history to a screen lock would defeat the point of it.
            save()
            Self.logger.notice("History sampling stopped")
        }
    }

    // MARK: - Sampling

    /// Takes one sample from whatever the services last published. It does
    /// not ask them to read: they are on their own cadence, and forcing a
    /// read here would double the sampling cost for no extra resolution.
    func sample(now: Date = Date()) {
        let current = stats?.stats
        let power = battery?.snapshot
        append(SystemStatsPoint(
            timestamp: now,
            cpuFraction: current?.cpuFraction,
            memoryFraction: current?.memoryFraction,
            gpuFraction: current?.gpuFraction,
            batteryPercentage: power?.percentage,
            batteryWatts: power?.watts,
            batteryTemperatureCelsius: power?.temperatureCelsius,
            isCharging: power?.isCharging))
    }

    /// Adds one point, overwriting the oldest once full.
    func append(_ point: SystemStatsPoint) {
        ring[writeIndex] = point
        writeIndex = (writeIndex + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
        rebuild()
    }

    /// Oldest-first order out of the ring.
    ///
    /// Before the ring fills, the entries sit at 0..<count and `writeIndex`
    /// is the count. Once full, the oldest entry is whatever `writeIndex`
    /// is about to overwrite, so the read starts there and wraps.
    private func rebuild() {
        let start = count < Self.capacity ? 0 : writeIndex
        points = (0..<count).compactMap { ring[(start + $0) % Self.capacity] }
    }

    /// Empties the ring and the file behind it.
    func clear() {
        ring = Array(repeating: nil, count: Self.capacity)
        writeIndex = 0
        count = 0
        points = []
        save()
    }

    // MARK: - Persistence

    /// The file's shape. Versioned for the same reason `AppSettings` is: a
    /// stored format with no version is one that can never change.
    private struct Stored: Codable {
        var schemaVersion: Int = 1
        var points: [SystemStatsPoint]
    }

    func save() {
        guard let storeURL else { return }
        do {
            let data = try JSONEncoder().encode(Stored(points: points))
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Regenerable data: a failed write costs a graph, not user work.
            Self.logger.error("History save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restores the ring from disk. A missing file is a first run, not an
    /// error, and is not logged. Corrupt JSON starts empty rather than
    /// throwing: an unreadable graph must not stop the app from launching.
    func load() {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            // A file written by a build with a larger capacity keeps only
            // its newest `capacity` points.
            for point in stored.points.suffix(Self.capacity) { append(point) }
            Self.logger.notice("History loaded: \(self.points.count, privacy: .public) points")
        } catch {
            Self.logger.error("History unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }
}
