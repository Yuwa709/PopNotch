import Foundation
import os

/// Resolves time-synced lyrics for the current track.
///
/// Order, cheapest first:
/// 1. **The player's own lyrics.** Music.app exposes a read-write `lyrics`
///    property per track. Free, offline, and often what the user embedded
///    themselves. Usually plain text though, so it only counts when it
///    actually parses as timed LRC.
/// 2. **LRCLIB `/api/get`.** Exact-ish lookup by artist, title and duration.
/// 3. **LRCLIB `/api/search`**, when the above 404s. This is what covers
///    titles that differ by a `feat.` or `- Remastered 2011` suffix: search
///    is fuzzy on the name, and the right record is then picked by duration.
///
/// No API key and no account — LRCLIB requires neither, which is why hard
/// rule 6 pre-approves it. Nothing identifying the user is ever sent; the
/// query carries song metadata only.
///
/// Endpoint behaviour below was measured against the live API on
/// 2026-08-28, not taken from documentation:
/// - `/api/get` already applies its own duration tolerance server-side — a
///   request 6s off still matched, 16s off returned 404 — so the client does
///   not need to widen it for this path.
/// - A miss is `404` with a `TrackNotFound` body, not an empty `200`.
/// - `/api/search` returns a bare JSON array, each element carrying
///   `duration`, `syncedLyrics`, `plainLyrics` and `instrumental`.
@MainActor
final class LyricsService {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Lyrics")

    /// How far a search result's duration may sit from the track's before it
    /// is rejected. Two seconds: enough to absorb the difference between a
    /// player's reported length and a contributor's, tight enough that a
    /// different edit of the same song does not match.
    static let durationTolerance: TimeInterval = 2

    /// In-memory layer over the disk cache, so a track already resolved this
    /// run costs nothing at all. nil value = known miss.
    private var memory: [String: [LyricsLine]?] = [:]
    private var inflight: Set<String> = []
    private let disk = LyricsDiskCache()

    /// Cache identity: artist, title and duration. Duration is part of the
    /// key because it is what distinguishes a radio edit from an album cut
    /// when the title cannot.
    nonisolated static func cacheKey(artist: String, title: String, duration: TimeInterval?) -> String {
        let seconds = duration.map { String(Int($0.rounded())) } ?? "?"
        return "\(artist.lowercased())|\(title.lowercased())|\(seconds)"
    }

    /// - Parameter embeddedLRC: the player's own lyrics text, when it has
    ///   any. Tried before the network and used only if it parses as timed.
    func fetch(
        artist: String,
        title: String,
        duration: TimeInterval?,
        embeddedLRC: String? = nil,
        completion: @escaping ([LyricsLine]?) -> Void
    ) {
        let key = Self.cacheKey(artist: artist, title: title, duration: duration)

        if let cached = memory[key] {
            Self.logger.notice("Cache hit (memory) for \(key, privacy: .public)")
            completion(cached)
            return
        }
        if let cached = disk.read(key: key) {
            Self.logger.notice("Cache hit (disk) for \(key, privacy: .public)")
            memory[key] = cached.lines
            completion(cached.lines)
            return
        }
        guard !inflight.contains(key) else { return }

        // 1. The player's own lyrics, before any network call.
        if let embeddedLRC, !embeddedLRC.isEmpty {
            let parsed = LyricsParser.parse(lrc: embeddedLRC)
            if !parsed.isEmpty {
                Self.logger.notice("Using player-embedded lyrics for \(title, privacy: .public): \(parsed.count) lines")
                store(parsed, key: key)
                completion(parsed)
                return
            }
            Self.logger.notice("Player lyrics for \(title, privacy: .public) are plain text, not timed; falling through to LRCLIB")
        }

        inflight.insert(key)
        Task { [weak self] in
            let lines = await Self.lookUp(artist: artist, title: title, duration: duration)
            guard let self else { return }
            self.inflight.remove(key)
            self.store(lines, key: key)
            Self.logger.notice("LRCLIB for \(title, privacy: .public): \(lines.map { "\($0.count) lines" } ?? "no match", privacy: .public)")
            completion(lines)
        }
    }

    /// Misses are cached too. Re-querying a track known to have no synced
    /// lyrics costs a round trip every track change for no possible gain.
    private func store(_ lines: [LyricsLine]?, key: String) {
        memory[key] = lines
        disk.write(lines, key: key)
    }

    // MARK: - Network

    private static func lookUp(
        artist: String, title: String, duration: TimeInterval?
    ) async -> [LyricsLine]? {
        if let exact = await get(artist: artist, title: title, duration: duration) {
            return exact
        }
        return await search(artist: artist, title: title, duration: duration)
    }

    private struct GetResponse: Decodable {
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    private struct SearchResult: Decodable {
        let syncedLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    private static func get(
        artist: String, title: String, duration: TimeInterval?
    ) async -> [LyricsLine]? {
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let data = await request(path: "/api/get", items: items),
              let decoded = try? JSONDecoder().decode(GetResponse.self, from: data)
        else { return nil }

        guard decoded.instrumental != true else {
            logger.notice("\(title, privacy: .public) is marked instrumental")
            return nil
        }
        return timed(decoded.syncedLyrics, context: "get")
    }

    /// Fallback for titles that differ by a suffix the exact lookup cannot
    /// forgive — `(feat. …)`, `- Remastered`, and similar. Search is loose on
    /// the name, so duration does the disambiguating.
    private static func search(
        artist: String, title: String, duration: TimeInterval?
    ) async -> [LyricsLine]? {
        let items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        guard let data = await request(path: "/api/search", items: items),
              let results = try? JSONDecoder().decode([SearchResult].self, from: data)
        else { return nil }

        guard let duration else {
            logger.notice("Search for \(title, privacy: .public) skipped: no duration to match on")
            return nil
        }
        // Closest duration inside the tolerance, among results that actually
        // carry synced lyrics. A plain-text-only record is not a match.
        let best = results
            .filter { $0.instrumental != true && $0.syncedLyrics?.isEmpty == false }
            .compactMap { result -> (SearchResult, TimeInterval)? in
                guard let d = result.duration else { return nil }
                let delta = abs(d - duration)
                return delta <= durationTolerance ? (result, delta) : nil
            }
            .min { $0.1 < $1.1 }

        guard let best else {
            logger.notice("Search for \(title, privacy: .public): \(results.count) results, none within \(Int(durationTolerance))s")
            return nil
        }
        logger.notice("Search matched \(title, privacy: .public) at \(best.1, format: .fixed(precision: 1), privacy: .public)s off")
        return timed(best.0.syncedLyrics, context: "search")
    }

    /// Synced lyrics only. A record with nothing but `plainLyrics` is a miss,
    /// not a partial success — the notch has no way to show untimed text.
    private static func timed(_ lrc: String?, context: String) -> [LyricsLine]? {
        guard let lrc, !lrc.isEmpty else { return nil }
        let parsed = LyricsParser.parse(lrc: lrc)
        if parsed.isEmpty {
            logger.notice("LRCLIB \(context, privacy: .public) returned untimed text only")
            return nil
        }
        return parsed
    }

    private static func request(path: String, items: [URLQueryItem]) async -> Data? {
        var components = URLComponents(string: "https://lrclib.net\(path)")
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        // LRCLIB asks callers to identify themselves. No key, no account.
        request.setValue("PopNotch/0.1 (https://github.com/techie/PopNotch)",
                         forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            logger.notice("LRCLIB \(path, privacy: .public) failed: network error")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 404 is the ordinary "no such track" answer, not a fault.
            if status != 404 {
                logger.notice("LRCLIB \(path, privacy: .public) -> \(status, privacy: .public)")
            }
            return nil
        }
        return data
    }
}

/// Lyrics survive relaunch on disk, so a track resolved once is never queried
/// again — including tracks that resolved to nothing.
///
/// One small JSON file per track under Application Support. A single index
/// file would have to be rewritten on every miss; per-track files make a
/// write O(1) and a corrupt entry cost exactly one track.
struct LyricsDiskCache {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Lyrics")

    struct Entry: Codable {
        let key: String
        /// nil = resolved to no synced lyrics. Cached so it is never retried.
        let lines: [LyricsLine]?
    }

    private var directory: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("PopNotch/Lyrics", isDirectory: true)
    }

    /// FNV-1a. Swift's own `hashValue` is seeded per process, so it would
    /// produce a different filename on every launch and the cache would never
    /// hit — the exact bug this avoids.
    static func filename(for key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx.json", hash)
    }

    func read(key: String) -> Entry? {
        guard let url = directory?.appendingPathComponent(Self.filename(for: key)),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        // Guard against an FNV collision handing back another track's lyrics.
        guard entry.key == key else {
            Self.logger.notice("Cache filename collision for \(key, privacy: .public); ignoring")
            return nil
        }
        return entry
    }

    func write(_ lines: [LyricsLine]?, key: String) {
        guard let directory else { return }
        let entry = Entry(key: key, lines: lines)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry)
                .write(to: directory.appendingPathComponent(Self.filename(for: key)))
        } catch {
            // A cache that cannot write is slow, not broken.
            Self.logger.notice("Cache write failed for \(key, privacy: .public)")
        }
    }
}
