import Foundation
import IOKit
import IOKit.ps
import AppKit
import Observation
import os

/// Reads the battery and publishes one `BatterySnapshot`.
///
/// Sampling is subscriber-counted and display-sleep aware, matching
/// `SystemStatsService` — hard rule 9: nothing polls while nobody is looking.
///
/// The parsing is a pure static function taking dictionaries, so every
/// degradation path is testable without a battery: missing keys, an empty
/// `AdapterDetails`, a machine with no battery at all.
@MainActor
@Observable
final class BatteryService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Battery")

    /// Five seconds, the floor this task set. Battery state changes on the
    /// order of minutes; anything faster spends power to measure power.
    @ObservationIgnored
    static let interval: TimeInterval = 5

    private(set) var snapshot: BatterySnapshot?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var displayAsleep = false

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displayDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Lifecycle

    /// Counted, so several observers can share one service without one
    /// leaving stopping sampling for the rest.
    func start() {
        subscribers += 1
        updateTimer()
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
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
            sample()
            let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Self.logger.notice("Battery sampling started (\(self.subscribers, privacy: .public) subscribers)")
        } else {
            timer?.invalidate()
            timer = nil
            Self.logger.notice("Battery sampling stopped")
        }
    }

    // MARK: - Sampling

    func sample() {
        snapshot = Self.snapshot(registry: Self.readRegistry(),
                                 powerSource: Self.readPowerSource(),
                                 adapter: Self.readAdapter(),
                                 isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                 now: Date())
    }

    // MARK: - Parsing

    /// The gauge's "not applicable" sentinel. `AvgTimeToFull` reads 65535
    /// whenever the pack is not charging; it is not a 45-day estimate.
    nonisolated static let notApplicableSentinel = 65535

    /// Every registry read goes through `NSNumber`, never `as? Bool`.
    ///
    /// These values are stored as Int32, and NSNumber bridges to `Bool` for
    /// **exactly 0 and 1 only** — measured 2026-09-01: `NSNumber(2) as? Bool`
    /// and `NSNumber(3488) as? Bool` are both nil, while 0 and 1 bridge
    /// fine. Nothing constrains a registry flag to 0/1 (`PMUConfigured`
    /// reads 3488, `NotChargingReason` 128), so a flag that ever reports 2
    /// would read as a *missing key* rather than as true, and the field
    /// would silently go nil instead of obviously wrong.
    ///
    /// Reading the number and testing `intValue != 0` has no such cliff, and
    /// keeps a genuine 0 distinguishable from an absent key — which is the
    /// whole contract of this struct's optionals.
    nonisolated private static func number(_ dictionary: [String: Any], _ key: String) -> NSNumber? {
        dictionary[key] as? NSNumber
    }

    nonisolated private static func integer(_ dictionary: [String: Any], _ key: String) -> Int? {
        number(dictionary, key)?.intValue
    }

    nonisolated private static func flag(_ dictionary: [String: Any], _ key: String) -> Bool? {
        number(dictionary, key).map { $0.intValue != 0 }
    }

    /// A duration in minutes, or nil for the sentinel and for negatives.
    nonisolated private static func minutes(_ dictionary: [String: Any], _ key: String) -> Int? {
        guard let value = integer(dictionary, key),
              value != notApplicableSentinel, value >= 0 else { return nil }
        return value
    }

    /// Builds a snapshot from already-read dictionaries.
    ///
    /// Pure and `nonisolated` so the tests exercise the real parsing rather
    /// than a re-implementation of it. Any dictionary may be empty; the
    /// result is then a snapshot of nils, which is a valid reading of a
    /// machine whose battery cannot be read, not a failure.
    nonisolated static func snapshot(registry: [String: Any],
                                     powerSource: [String: Any],
                                     adapter: [String: Any]?,
                                     isLowPowerMode: Bool,
                                     now: Date) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.timestamp = now
        snapshot.isLowPowerMode = isLowPowerMode

        snapshot.percentage = integer(registry, "CurrentCapacity")
        snapshot.rawCurrentCapacityMilliampHours = integer(registry, "AppleRawCurrentCapacity")
        snapshot.rawMaxCapacityMilliampHours = integer(registry, "AppleRawMaxCapacity")
        snapshot.designCapacityMilliampHours = integer(registry, "DesignCapacity")
        snapshot.nominalCapacityMilliampHours = integer(registry, "NominalChargeCapacity")
        snapshot.cycleCount = integer(registry, "CycleCount")

        if let rawMax = snapshot.rawMaxCapacityMilliampHours,
           let design = snapshot.designCapacityMilliampHours, design > 0 {
            snapshot.healthPercent = Double(rawMax) / Double(design) * 100
        }

        if let centiCelsius = integer(registry, "Temperature") {
            snapshot.temperatureCelsius = Double(centiCelsius) / 100
        }
        snapshot.voltageMillivolts = integer(registry, "Voltage")
        snapshot.amperageMilliamps = integer(registry, "Amperage")

        snapshot.isCharging = flag(registry, "IsCharging")
        snapshot.isFullyCharged = flag(registry, "FullyCharged")
        snapshot.isExternalConnected = flag(registry, "ExternalConnected")

        // IOPS only. See BatterySnapshot.timeToEmptyMinutes for why the
        // registry's TimeRemaining is not read here or anywhere else.
        //
        // On AC, IOPS reports `Time to Empty = 0` rather than omitting it —
        // measured 2026-09-02 while charging at 73%. Zero is not a reading:
        // storing it would put "0 minutes remaining" on the screen of a
        // machine that is plugged in and filling up. Time to empty only
        // means anything while running off the battery.
        if snapshot.isExternalConnected == true {
            snapshot.timeToEmptyMinutes = nil
        } else {
            snapshot.timeToEmptyMinutes = minutes(powerSource, "Time to Empty")
        }
        snapshot.timeToFullMinutes = minutes(registry, "AvgTimeToFull")

        // An absent or empty adapter dictionary is the ordinary on-battery
        // state: no error, no fallback, and deliberately no logging at any
        // level — a laptop on battery would write that line every sample for
        // as long as it ran.
        let adapterKeys = adapter ?? [:]
        if !adapterKeys.isEmpty {
            snapshot.adapterIsPresent = true
            // Only keys observed on real hardware are read. See the TODO on
            // BatterySnapshot for the ones seen but not yet modelled.
            snapshot.adapterWatts = integer(adapterKeys, "Watts")
            snapshot.adapterName = adapterKeys["Description"] as? String
        } else if let external = snapshot.isExternalConnected {
            snapshot.adapterIsPresent = external
        }

        return snapshot
    }

    // MARK: - IOKit

    private static func readRegistry() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        // Zero is what a machine with no battery returns. Not an error.
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private static func readPowerSource() -> [String: Any] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [:] }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType {
                return description
            }
        }
        return [:]
    }

    /// Nil on battery. That is the normal case and is not logged.
    private static func readAdapter() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }
}
