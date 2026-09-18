import Foundation

/// The fixed set of apps that are never tapped (v1 plan, decision 9): tools
/// that already interpose on other apps' audio, where adding our own tap on
/// top risks glitching everything they manage. Shown on the mixer page
/// greyed with the reason, so the row's absence of a working slider is
/// explained rather than looking broken.
///
/// **Every bundle ID here is verified against a real install, never
/// guessed** (decision 9). The set has no editor and no settings fields.
/// PopNotch itself and untraceable system daemons are not listed here
/// because `AudioOwnerResolver` already hides them entirely — this set only
/// covers apps that appear as rows.
///
/// DAW entries (Logic Pro, GarageBand, Ableton…) are anticipated by the
/// plan but absent: no DAW is installed on the development machine, so no
/// bundle ID can be verified yet. Add each one only after reading it from a
/// real install's Info.plist.
enum NeverTapSet {

    /// Owner key (the app's bundle ID) to the short reason the row shows.
    ///
    /// Verified 2026-09-18 by reading each app's `Info.plist` in
    /// `/Applications` on the development machine.
    private static let reasons: [String: String] = [
        "com.finetuneapp.FineTune": "audio mixer",
        "com.cshariq.sapphire": "audio mixer",
    ]

    /// The display reason for an owner key, or nil when the app is tappable.
    nonisolated static func reason(for key: String) -> String? {
        reasons[key]
    }
}
