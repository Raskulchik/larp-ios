import SwiftUI
import UIKit

struct TrackArtworkView: View {
    /// nil — просто плейсхолдер (например, в плеере ещё нет трека).
    let track: Track?
    @State private var image: UIImage?
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        let local: Bool
        if let track {
            local = downloads.localFileURL(for: track) != nil
        } else {
            local = false
        }
        // Меняется и при смене трека, и когда трек скачался (обложка появляется в mp3).
        let refreshKey = "\(track?.searchKey ?? "none")-\(local)"

        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: refreshKey) { await load() }
    }

    private func load() async {
        image = nil
        // У скачанных треков обложка вшита в mp3, у остальных — из памяти/сети.
        image = await ArtworkStore.image(for: track)
    }

    private var placeholder: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: "music.note").foregroundColor(.secondary)
        }
    }
}

struct TrackRowView: View {
    let track: Track
    @ObservedObject private var downloads = DownloadManager.shared
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(track: track)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .foregroundColor(isPlaying ? .accentColor : .primary)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.sourceLabel)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if downloads.isDownloading(track) || downloads.info(for: track)?.state == "error" {
                    statusLine(for: track)
                }
            }
            Spacer()
            if let d = downloads.durationMs(for: track), d > 0 {
                Text(secondsText(Double(d) / 1000.0))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusLine(for track: Track) -> some View {
        let info = downloads.info(for: track)
        if info?.state == "error" {
            Text(info?.error ?? "ошибка")
                .font(.caption2)
                .foregroundColor(.red)
                .lineLimit(1)
        } else {
            ProgressView(value: info?.progress ?? 0, total: 100)
                .progressViewStyle(.linear)
                .frame(maxWidth: 160)
        }
    }
}