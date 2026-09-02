import Foundation
import AppKit
// Compiles the SHIPPED BatteryService/BatterySnapshot sources — this prints
// the real snapshot the app produces, not a re-implementation.
MainActor.assumeIsolated {
    let service = BatteryService()
    service.start()
    guard let s = service.snapshot else { print("no snapshot"); return }
    service.stop()

    func row(_ l: String, _ v: String) { print("  " + l.padding(toLength: 28, withPad: " ", startingAt: 0) + v) }
    func opt<T>(_ l: String, _ v: T?, _ u: String = "") { row(l, v.map { "\($0)\(u)" } ?? "nil") }
    func f(_ v: Double?, _ u: String) -> String { v.map { String(format: "%.2f", $0) + u } ?? "nil" }

    print("=== BatterySnapshot — \(s.timestamp) ===")
    print("[charge]")
    opt("percentage", s.percentage, "%")
    opt("rawCurrentCapacityMilliampHours", s.rawCurrentCapacityMilliampHours, " mAh")
    opt("rawMaxCapacityMilliampHours", s.rawMaxCapacityMilliampHours, " mAh")
    opt("designCapacityMilliampHours", s.designCapacityMilliampHours, " mAh")
    opt("nominalCapacityMilliampHours", s.nominalCapacityMilliampHours, " mAh")
    row("healthPercent (stored)", f(s.healthPercent, "%"))
    row("displayHealthPercent", f(s.displayHealthPercent, "%"))
    opt("cycleCount", s.cycleCount)
    print("[power]")
    row("temperatureCelsius", f(s.temperatureCelsius, " °C"))
    opt("voltageMillivolts", s.voltageMillivolts, " mV")
    opt("amperageMilliamps", s.amperageMilliamps, " mA")
    row("watts (derived)", f(s.watts, " W"))
    print("[state]")
    opt("isCharging", s.isCharging)
    opt("isFullyCharged", s.isFullyCharged)
    opt("isExternalConnected", s.isExternalConnected)
    row("isLowPowerMode", "\(s.isLowPowerMode)")
    print("[time]")
    opt("timeToEmptyMinutes", s.timeToEmptyMinutes, " min")
    opt("timeToFullMinutes", s.timeToFullMinutes, " min")
    print("[adapter]")
    opt("adapterIsPresent", s.adapterIsPresent)

    if let json = try? JSONEncoder().encode(s), let text = String(data: json, encoding: .utf8) {
        print("\n[Codable round-trip] \(text.count) bytes")
    }
    print("\nHistory store: \(SystemStatsHistory.defaultStoreURL()?.path ?? "unavailable")")
}
