import SwiftUI

/// The history list in the expanded notch. Click an entry to put it back on
/// the pasteboard.
struct ClipboardExpandedView: View {
    @Bindable var service: ClipboardService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if service.entries.isEmpty {
                Text("Nothing copied yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(service.entries) { entry in
                    ClipboardRow(entry: entry) { service.copyBack(entry) }
                }
            }
        }
        .frame(width: 320, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Text("CLIPBOARD")
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
}

/// One entry: a thumbnail for images, one collapsed line for text.
private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 8) {
                icon
                content
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy back to the clipboard")
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.content {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 14)
        case .image:
            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 14)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.content {
        case .text(let text):
            Text(ClipboardService.preview(of: text))
                .font(.system(size: 10))
                .lineLimit(1)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Text("Image")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
