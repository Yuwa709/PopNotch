import AppKit
import QuickLookThumbnailing
import Observation
import os

/// One file parked on the shelf.
///
/// The bookmark is the identity, not a path: it survives the file being
/// moved or renamed underneath us. `name` is cached alongside so a row can
/// render without resolving anything.
nonisolated struct FileShelfEntry: Identifiable, Equatable {
    let id: UUID
    let bookmark: Data
    let name: String

    init(id: UUID = UUID(), bookmark: Data, name: String) {
        self.id = id
        self.bookmark = bookmark
        self.name = name
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bookmark == rhs.bookmark }
}

/// Files parked in the notch: references only, in memory only.
///
/// **Nothing is copied, moved, or deleted.** The shelf holds bookmarks to
/// files that stay exactly where the user put them; removing an entry
/// forgets a reference and never touches the file. Nothing is written to
/// disk either, so the shelf empties on quit — persisting a list of the
/// user's file references is a separate decision nobody has made.
///
/// **Security-scoped access is held for as long as the entry is.** Verified
/// 2026-08-30 that `.withSecurityScope` bookmarks resolve and
/// `startAccessingSecurityScopedResource()` returns true even though this
/// app is not sandboxed, where the scope is technically unnecessary. It is
/// kept because a drag-out or a share reads the file *after* the call that
/// started it has returned, so scope has to outlive the gesture — and
/// because it is what makes this correct if the sandbox is ever enabled.
@MainActor
@Observable
final class FileShelfService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FileShelf")

    private(set) var entries: [FileShelfEntry] = []

    /// Resolved URLs whose security scope is currently held open, keyed by
    /// entry. Balanced in `release(_:)`, which every removal path goes
    /// through so a scope cannot leak.
    @ObservationIgnored private var accessed: [UUID: URL] = [:]
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]

    deinit {
        // Nonisolated: stop each scope directly. Leaving them open outlives
        // any use the process had for them.
        for url in accessed.values { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - Adding

    @discardableResult
    func add(_ url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            Self.logger.error("Could not bookmark \(url.lastPathComponent, privacy: .public)")
            return false
        }
        let entry = FileShelfEntry(bookmark: bookmark, name: url.lastPathComponent)
        guard !entries.contains(entry) else {
            Self.logger.notice("Already shelved: \(entry.name, privacy: .public)")
            return false
        }
        // Open the scope now and hold it: a drag-out reads the file after the
        // gesture that started it has returned.
        if let resolved = Self.resolve(bookmark), resolved.startAccessingSecurityScopedResource() {
            accessed[entry.id] = resolved
        }
        entries.insert(entry, at: 0)
        Self.logger.notice("Shelved \(entry.name, privacy: .public) (\(self.entries.count, privacy: .public) held)")
        Task { await loadThumbnail(for: entry) }
        return true
    }

    // MARK: - Removing

    func remove(_ entry: FileShelfEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries.remove(at: index)
        release(entry.id)
        thumbnails[entry.id] = nil
        // Worth being explicit in the log: this is a reference being dropped,
        // not a file being touched.
        Self.logger.notice("Unshelved \(entry.name, privacy: .public); file untouched on disk")
    }

    func clear() {
        let count = entries.count
        for entry in entries { release(entry.id) }
        entries.removeAll()
        thumbnails.removeAll()
        Self.logger.notice("Shelf cleared (\(count, privacy: .public) references dropped; no files touched)")
    }

    private func release(_ id: UUID) {
        accessed[id]?.stopAccessingSecurityScopedResource()
        accessed[id] = nil
    }

    // MARK: - Using

    /// The file's location, with its security scope already open.
    func url(for entry: FileShelfEntry) -> URL? {
        accessed[entry.id] ?? Self.resolve(entry.bookmark)
    }

    /// Pure, and static so it is testable without a live service.
    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    func thumbnail(for entry: FileShelfEntry) -> NSImage? { thumbnails[entry.id] }

    private func loadThumbnail(for entry: FileShelfEntry) async {
        guard let url = url(for: entry) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 48, height: 48), scale: 2,
            representationTypes: .all)
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }
        thumbnails[entry.id] = NSImage(cgImage: representation.cgImage,
                                       size: NSSize(width: 48, height: 48))
    }

    // MARK: - Sharing

    /// Held for the life of a share. `NSSharingService.delegate` is weak and
    /// the share outlives the call that starts it, so neither can be a local.
    @ObservationIgnored private var activeShare: NSSharingService?
    @ObservationIgnored private let shareDelegate = ShareDelegate()

    /// Sends one file via AirDrop.
    ///
    /// **The previous implementation silently did nothing, and the comment
    /// that justified it was false.** It built an `NSSharingServicePicker` and
    /// called `show(relativeTo:of:preferredEdge:)` against a zero-size view
    /// inside the notch panel. A picker is a menu, and a menu will not display
    /// for an app with no key window — `NotchPanel.canBecomeKey` is false by
    /// design (hard rule 3). Probed outside the app on 2026-08-30 under
    /// identical conditions (accessory policy, `.nonactivatingPanel`,
    /// `canBecomeKey == false`), the picker's delegate fired and built an
    /// eleven-service menu, and then **no menu window ever reached the
    /// screen**. There is no error and no return value, so nothing could be
    /// logged: the failure was invisible by construction.
    ///
    /// The old comment claimed macOS exposes no direct AirDrop API. It does:
    /// `NSSharingServiceNameSendViaAirDrop` is public, `API_AVAILABLE(macos(10.8))`,
    /// and present in `MacOSX26.5.sdk/…/NSSharingService.h`. It is not a
    /// private interface and needs no reverse engineering.
    ///
    /// It presents ShareKit's own out-of-process window, which requires no key
    /// window of ours. Measured after the call: the panel kept
    /// `canBecomeKey == false`, `isKeyWindow == false`, `isVisible == true`,
    /// and an unchanged level, styleMask and collectionBehavior, so hard rule 3
    /// is untouched and no `NSApplication.activate` is involved. The system's
    /// share window does take focus while it is up — that is the gesture doing
    /// what the user asked, not the notch stealing focus on hover (hard rule 4).
    func share(_ entry: FileShelfEntry) {
        guard let url = url(for: entry) else {
            Self.logger.error("Could not resolve \(entry.name, privacy: .public) to share")
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            Self.logger.error("AirDrop sharing service unavailable")
            return
        }
        guard service.canPerform(withItems: [url]) else {
            Self.logger.error("AirDrop cannot send \(entry.name, privacy: .public)")
            return
        }
        service.delegate = shareDelegate
        activeShare = service
        Self.logger.notice("AirDrop: sending \(entry.name, privacy: .public)")
        service.perform(withItems: [url])
    }

    /// Logged from the view when a drag out of the shelf begins.
    func noteDragOut(_ entry: FileShelfEntry) {
        Self.logger.notice("Dragging \(entry.name, privacy: .public) out of the shelf")
    }
}

/// Reports how a share ended. Exists because the picker's failure mode was
/// silence: an outcome nobody logs is an outcome nobody can debug.
@MainActor
private final class ShareDelegate: NSObject, NSSharingServiceDelegate {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FileShelf")

    func sharingService(_ service: NSSharingService, willShareItems items: [Any]) {
        Self.logger.notice("AirDrop: share UI opening")
    }

    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
        Self.logger.notice("AirDrop: share completed")
    }

    func sharingService(_ service: NSSharingService,
                        didFailToShareItems items: [Any],
                        error: Error) {
        let code = (error as NSError).code
        // Cancelling the panel reports as an error; it is a normal outcome and
        // should not read like a fault in the log.
        if code == NSUserCancelledError {
            Self.logger.notice("AirDrop: cancelled by the user")
        } else {
            Self.logger.error("AirDrop failed: \(error.localizedDescription, privacy: .public) (\(code, privacy: .public))")
        }
    }
}
