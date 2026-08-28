import Foundation
import os

/// One timestamped lyric line.
struct LyricsLine: Equatable {
    let time: TimeInterval
    let text: String
}

/// Pure LRC parsing and lookup, split out for tests.
enum LyricsParser {

    /// Parses LRC text: lines of `[mm:ss.xx] words`, possibly with several
    /// timestamps sharing one text. Unparseable lines and empty texts are
    /// skipped; the result is sorted by time.
    static func parse(lrc: String) -> [LyricsLine] {
        var result: [LyricsLine] = []
        let tagPattern = /\[(\d+):(\d+(?:\.\d+)?)\]/

        for rawLine in lrc.components(separatedBy: .newlines) {
            let matches = rawLine.matches(of: tagPattern)
            guard let last = matches.last else { continue }

            let text = String(rawLine[last.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minutes = Double(match.output.1),
                      let seconds = Double(match.output.2) else { continue }
                result.append(LyricsLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// The line being sung at `elapsed`, with a small lead so a line appears
    /// as it starts rather than strictly after. Nil before the first line.
    static func currentLine(at elapsed: TimeInterval, in lines: [LyricsLine]) -> LyricsLine? {
        lines.last { $0.time <= elapsed + 0.2 }
    }
}

/// Fetches synced lyrics from LRCLIB — the endpoint hard rule 6 pre-approves
/// for the lyrics feature — and caches per track, including misses, so a
/// track is never queried twice in a run.
@MainActor
final class LyricsService {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Lyrics")

    /// nil value = known miss (no synced lyrics, instrumental, or error).
    private var cache: [String: [LyricsLine]?] = [:]
    private var inflight: Set<String> = []

    private struct LRCLIBResponse: Decodable {
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    func fetch(
        artist: String,
        title: String,
        duration: TimeInterval?,
        key: String,
        completion: @escaping ([LyricsLine]?) -> Void
    ) {
        if let cached = cache[key] {
            completion(cached)
            return
        }
        guard !inflight.contains(key) else { return }

        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        // LRCLIB asks callers to identify themselves.
        request.setValue("PopNotch/0.1", forHTTPHeaderField: "User-Agent")

        inflight.insert(key)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let lines: [LyricsLine]?
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data),
               let lrc = decoded.syncedLyrics,
               decoded.instrumental != true {
                let parsed = LyricsParser.parse(lrc: lrc)
                lines = parsed.isEmpty ? nil : parsed
            } else {
                lines = nil
            }
            Task { @MainActor in
                self.inflight.remove(key)
                self.cache[key] = lines
                Self.logger.notice("Lyrics for \(title, privacy: .public): \(lines.map { "\($0.count) lines" } ?? "none", privacy: .public)")
                completion(lines)
            }
        }.resume()
    }
}
