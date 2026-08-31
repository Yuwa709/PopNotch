import SwiftUI
import UniformTypeIdentifiers

/// The shelf screen: a wide AirDrop target across the top, and below it the
/// shelf itself filling the rest of the panel, with entries laid out in a
/// grid large enough to tell files apart.
struct FileShelfExpandedView: View {
    @Bindable var service: FileShelfService

    @State private var shelfTargeted = false
    @State private var airdropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            airdrop
            shelf
        }
        .frame(width: 440, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Text("SHELF")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if !service.entries.isEmpty {
                Button("Clear") { service.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: - AirDrop

    private var airdrop: some View {
        HStack(spacing: 8) {
            Image(systemName: "shareplay")
                .font(.system(size: 16, weight: .medium))
            Text("Drop here to AirDrop")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(airdropTargeted ? 0.95 : 0.55))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.white.opacity(airdropTargeted ? 0.6 : 0.22))
        )
        .onDrop(of: [.fileURL], isTargeted: $airdropTargeted) { providers in
            // A file dropped here is shared straight away, whether it came
            // from the shelf or from outside; shelving it first would be a
            // side effect the gesture did not ask for.
            load(providers) { url in
                let entry = FileShelfEntry(bookmark: (try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data(),
                                           name: url.lastPathComponent)
                service.share(entry)
            }
            return true
        }
    }

    // MARK: - Shelf

    private var shelf: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.white.opacity(shelfTargeted ? 0.6 : 0.22))
            if service.entries.isEmpty {
                Text("Drop files here")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)],
                              spacing: 12) {
                        ForEach(service.entries) { entry in
                            ShelfItem(service: service, entry: entry)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(height: 226)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $shelfTargeted) { providers in
            load(providers) { service.add($0) }
            return true
        }
    }

    /// Pulls file URLs off the drag providers and hands each to `action`.
    private func load(_ providers: [NSItemProvider], action: @escaping (URL) -> Void) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in action(url) }
            }
        }
    }
}

/// One parked file: thumbnail, name, and a remove affordance. Draggable out
/// to Finder or any app that accepts files.
private struct ShelfItem: View {
    @Bindable var service: FileShelfService
    let entry: FileShelfEntry

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                if hovering {
                    Button { service.remove(entry) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Remove from shelf — the file itself is untouched")
                }
            }
            Text(entry.name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84)
        }
        .onHover { hovering = $0 }
        // Standard drag provider: the file already exists, so a promise
        // would be indirection with nothing to promise.
        .onDrag {
            service.noteDragOut(entry)
            guard let url = service.url(for: entry),
                  let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
            return provider
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = service.thumbnail(for: entry) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.5)))
        }
    }
}
