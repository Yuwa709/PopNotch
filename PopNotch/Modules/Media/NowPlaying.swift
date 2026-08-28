import Foundation

/// A snapshot of what is playing, decoded from MediaRemote's raw dictionary.
///
/// Every field is optional except `isPlaying`: a player may report a title
/// with no artwork, or artwork mid-load with no duration. Views show what is
/// present and omit the rest rather than rendering placeholders.
struct NowPlaying: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    /// Raw image bytes as delivered (usually JPEG). Decoded to an image in the
    /// view layer, not here, so the model stays cheap to compare and copy.
    var artworkData: Data?
    var artworkIdentifier: String?
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var isPlaying: Bool = false
    /// Bundle id of the app that owns the session, e.g. com.spotify.client.
    var sourceBundleID: String?

    /// True when there is genuinely something to show. An all-nil snapshot
    /// with nothing playing should hide the module, not display an empty box.
    var hasContent: Bool {
        title != nil || artist != nil || artworkData != nil
    }
}
