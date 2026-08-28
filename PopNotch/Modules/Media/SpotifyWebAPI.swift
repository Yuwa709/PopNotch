import Foundation
import os

/// What the notch shows from the user's queue.
struct SpotifyUpNext: Equatable {
    let title: String
    let artist: String
}

/// Official artist metadata. Note `followers` is Spotify's follower count —
/// NOT monthly listeners, which the official API does not expose. Labelled
/// honestly in the UI rather than passed off as the other number.
struct SpotifyArtistInfo: Equatable {
    let name: String
    let followers: Int
    let imageURL: String?
    let genres: [String]
}

/// Human-readable large counts: 31.7M, 1.2B, 450K.
enum CountFormatter {
    static func short(_ value: Int) -> String {
        let n = Double(value)
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", n / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", n / 1_000)
        default:
            return String(value)
        }
    }
}

/// The Web API calls PopNotch makes once the account is connected. Thin by
/// design: every function is one endpoint, authed via SpotifyAccount.
@MainActor
final class SpotifyWebAPI {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "SpotifyAPI")

    private let account: SpotifyAccount

    init(account: SpotifyAccount) {
        self.account = account
    }

    /// "spotify:track:4uLU6hMC..." -> "4uLU6hMC...". Nil for non-track URIs
    /// (episodes, local files), which have no like endpoint.
    nonisolated static func trackID(fromURI uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" else { return nil }
        return String(parts[2])
    }

    // MARK: - Decoding (internal for tests)

    struct QueueResponse: Decodable {
        let queue: [QueueTrack]
    }
    struct QueueTrack: Decodable {
        let name: String
        let artists: [QueueArtist]
    }
    struct QueueArtist: Decodable {
        let name: String
    }

    nonisolated static func upNext(fromQueueJSON data: Data) -> SpotifyUpNext? {
        guard let decoded = try? JSONDecoder().decode(QueueResponse.self, from: data),
              let first = decoded.queue.first else { return nil }
        return SpotifyUpNext(
            title: first.name,
            artist: first.artists.map(\.name).joined(separator: ", ")
        )
    }

    // MARK: - Playback context decoding

    struct PlayerStateResponse: Decodable {
        let context: PlaybackContext?
    }
    struct PlaybackContext: Decodable {
        let uri: String?
    }

    /// Where playback was started from — the user's playlist, their Liked
    /// Songs, an artist page, or the album. Nil when Spotify reports no
    /// context, which is the normal answer for autoplay and radio, not an
    /// error; the caller falls back to the track itself.
    nonisolated static func contextURI(fromPlayerJSON data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(PlayerStateResponse.self, from: data),
              let uri = decoded.context?.uri, !uri.isEmpty else { return nil }
        return uri
    }

    // MARK: - Track and artist decoding

    struct TrackResponse: Decodable {
        let popularity: Int?
        let artists: [TrackArtist]
    }
    struct TrackArtist: Decodable {
        let id: String
    }
    struct ArtistResponse: Decodable {
        let name: String
        let followers: Followers?
        let images: [ArtistImage]?
        let genres: [String]?
    }
    struct Followers: Decodable { let total: Int? }
    struct ArtistImage: Decodable { let url: String; let width: Int? }

    nonisolated static func trackDetail(fromJSON data: Data) -> (popularity: Int?, artistID: String)? {
        guard let decoded = try? JSONDecoder().decode(TrackResponse.self, from: data),
              let artistID = decoded.artists.first?.id else { return nil }
        return (decoded.popularity, artistID)
    }

    nonisolated static func artistInfo(fromJSON data: Data) -> SpotifyArtistInfo? {
        guard let decoded = try? JSONDecoder().decode(ArtistResponse.self, from: data) else { return nil }
        // Smallest image that is still crisp for a ~20pt avatar.
        let image = (decoded.images ?? [])
            .sorted { ($0.width ?? 0) < ($1.width ?? 0) }
            .first { ($0.width ?? 0) >= 120 } ?? decoded.images?.last
        return SpotifyArtistInfo(
            name: decoded.name,
            followers: decoded.followers?.total ?? 0,
            imageURL: image?.url,
            genres: decoded.genres ?? []
        )
    }

    // MARK: - Calls

    func fetchTrackDetail(trackID: String) async -> (popularity: Int?, artistID: String)? {
        guard let data = await get("https://api.spotify.com/v1/tracks/\(trackID)") else { return nil }
        return Self.trackDetail(fromJSON: data)
    }

    func fetchArtist(id: String) async -> SpotifyArtistInfo? {
        guard let data = await get("https://api.spotify.com/v1/artists/\(id)") else { return nil }
        return Self.artistInfo(fromJSON: data)
    }

    func fetchImage(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString), url.scheme == "https",
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return data
    }

    /// `/v1/me/player` answers 204 with no body when nothing is playing on
    /// the account; `get` already treats that as a quiet nil.
    func fetchPlaybackContext() async -> String? {
        guard let data = await get("https://api.spotify.com/v1/me/player") else { return nil }
        return Self.contextURI(fromPlayerJSON: data)
    }

    func fetchUpNext() async -> SpotifyUpNext? {
        guard let data = await get("https://api.spotify.com/v1/me/player/queue") else { return nil }
        return Self.upNext(fromQueueJSON: data)
    }

    func isSaved(trackID: String) async -> Bool? {
        guard let data = await get("https://api.spotify.com/v1/me/tracks/contains?ids=\(trackID)"),
              let flags = try? JSONDecoder().decode([Bool].self, from: data)
        else { return nil }
        return flags.first
    }

    /// Returns whether the change was accepted.
    func setSaved(_ saved: Bool, trackID: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)")!)
        request.httpMethod = saved ? "PUT" : "DELETE"
        guard let token = await account.validAccessToken() else { return false }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return false }
        return (200..<300).contains(status)
    }

    private func get(_ urlString: String) async -> Data? {
        guard let token = await account.validAccessToken(),
              let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        guard status == 200 else {
            // 204: nothing playing on this account. 429: rate limited.
            // Either way there is nothing to show; stay quiet.
            if status != 204 {
                Self.logger.notice("GET \(urlString, privacy: .public) -> \(status, privacy: .public)")
            }
            return nil
        }
        return data
    }
}
