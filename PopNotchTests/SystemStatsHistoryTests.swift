import XCTest
@testable import PopNotch

/// The ring buffer and its file.
@MainActor
final class SystemStatsHistoryTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("popnotch-history-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    private func history() -> SystemStatsHistory {
        SystemStatsHistory(stats: nil, battery: nil, storeURL: storeURL)
    }

    private func point(_ index: Int) -> SystemStatsPoint {
        SystemStatsPoint(timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                         cpuFraction: Double(index) / 10_000,
                         memoryFraction: 0.5,
                         gpuFraction: nil,
                         batteryPercentage: index % 101,
                         batteryWatts: 8.4,
                         batteryTemperatureCelsius: 30.35,
                         isCharging: false)
    }

    // MARK: - Ring

    func testKeepsPointsInOrderBeforeItFills() {
        let subject = history()
        for i in 0..<10 { subject.append(point(i)) }
        XCTAssertEqual(subject.points.count, 10)
        XCTAssertEqual(subject.points.map(\.timestamp),
                       (0..<10).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                       "oldest first")
    }

    func testWrapsAtCapacityKeepingTheNewest() {
        let subject = history()
        let capacity = SystemStatsHistory.capacity
        for i in 0..<(capacity + 25) { subject.append(point(i)) }

        XCTAssertEqual(subject.points.count, capacity, "size is fixed once full")
        XCTAssertEqual(subject.points.first?.timestamp,
                       Date(timeIntervalSince1970: TimeInterval(25)),
                       "the 25 oldest were overwritten")
        XCTAssertEqual(subject.points.last?.timestamp,
                       Date(timeIntervalSince1970: TimeInterval(capacity + 24)),
                       "newest is last")
        // Still strictly ordered across the wrap seam, which is the failure
        // a naive rebuild produces.
        let stamps = subject.points.map(\.timestamp)
        XCTAssertEqual(stamps, stamps.sorted(), "order must survive wrapping")
    }

    func testExactlyFullDoesNotReorder() {
        let subject = history()
        for i in 0..<SystemStatsHistory.capacity { subject.append(point(i)) }
        XCTAssertEqual(subject.points.first?.timestamp, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(subject.points.count, SystemStatsHistory.capacity)
    }

    func testClearEmptiesRingAndFile() {
        let subject = history()
        for i in 0..<5 { subject.append(point(i)) }
        subject.save()
        subject.clear()
        XCTAssertTrue(subject.points.isEmpty)

        let reloaded = history()
        XCTAssertTrue(reloaded.points.isEmpty, "cleared on disk too")
    }

    // MARK: - Persistence

    func testPersistenceRoundTrips() {
        let subject = history()
        for i in 0..<50 { subject.append(point(i)) }
        subject.save()

        let reloaded = history()
        XCTAssertEqual(reloaded.points.count, 50)
        XCTAssertEqual(reloaded.points, subject.points, "every field survives the round trip")
    }

    func testRoundTripPreservesOptionalGaps() {
        let subject = history()
        subject.append(SystemStatsPoint(timestamp: Date(timeIntervalSince1970: 1),
                                        cpuFraction: nil,
                                        memoryFraction: 0.25,
                                        gpuFraction: nil,
                                        batteryPercentage: nil,
                                        batteryWatts: nil,
                                        batteryTemperatureCelsius: nil,
                                        isCharging: nil))
        subject.save()

        let reloaded = history()
        XCTAssertEqual(reloaded.points.count, 1)
        XCTAssertNil(reloaded.points[0].cpuFraction, "a gap must stay a gap, not become 0")
        XCTAssertNil(reloaded.points[0].batteryPercentage)
        XCTAssertEqual(reloaded.points[0].memoryFraction, 0.25)
    }

    func testWrappedRingRoundTripsInOrder() {
        let subject = history()
        for i in 0..<(SystemStatsHistory.capacity + 10) { subject.append(point(i)) }
        subject.save()

        let reloaded = history()
        XCTAssertEqual(reloaded.points.count, SystemStatsHistory.capacity)
        XCTAssertEqual(reloaded.points.first?.timestamp,
                       Date(timeIntervalSince1970: 10))
        XCTAssertEqual(reloaded.points, subject.points)
    }

    func testMissingFileIsAFirstRunNotAnError() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(history().points.isEmpty)
    }

    func testCorruptFileStartsEmptyRatherThanThrowing() throws {
        try Data("{ not json".utf8).write(to: storeURL)
        XCTAssertTrue(history().points.isEmpty)
    }

    /// A file from a build with a bigger ring keeps its newest points.
    func testOversizedFileIsTruncatedToCapacity() throws {
        struct Stored: Codable { var schemaVersion = 1; var points: [SystemStatsPoint] }
        let oversized = (0..<(SystemStatsHistory.capacity + 500)).map(point)
        try JSONEncoder().encode(Stored(points: oversized)).write(to: storeURL)

        let reloaded = history()
        XCTAssertEqual(reloaded.points.count, SystemStatsHistory.capacity)
        XCTAssertEqual(reloaded.points.last?.timestamp,
                       Date(timeIntervalSince1970: TimeInterval(SystemStatsHistory.capacity + 499)))
    }

    // MARK: - Sampling lifecycle

    func testSamplingIsSubscriberCounted() {
        let subject = history()
        subject.start()
        subject.start()
        subject.stop()
        subject.sample(now: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(subject.points.count, 1, "still observed by one subscriber")
        subject.stop()
        // Unbalanced stops must not underflow into a negative count that
        // would keep the timer alive forever.
        subject.stop()
        XCTAssertEqual(subject.points.count, 1)
    }

    func testSampleToleratesAbsentServices() {
        let subject = history()
        subject.sample(now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(subject.points.count, 1)
        XCTAssertNil(subject.points[0].cpuFraction, "no service attached: a gap, not a zero")
    }
}
