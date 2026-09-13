import SwiftUI

struct TrackArtworkView: View {
    let url: String?

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            TrackArtworkView(url: track.artworkUrl)
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
            if let d = track.durationMs, d > 0 {
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