import SwiftUI

/// Мини-плеер снизу (над таб-баром). Тап — открыть полноэкранный плеер.
struct PlayerBarView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @State private var showingPlayer = false

    var body: some View {
        if player.currentTrack != nil {
            HStack(spacing: 12) {
                Button {
                    showingPlayer = true
                } label: {
                    frame
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .frame(maxWidth: geo.size.width * min(max(fraction, 0), 1), alignment: .leading)
                }
                .frame(height: 2)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .sheet(isPresented: $showingPlayer) {
                PlayerView()
            }
        }
    }

    private var frame: some View {
        HStack(spacing: 10) {
            TrackArtworkView(url: player.currentTrack?.artworkUrl)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentTrack?.title ?? "")
                    .font(.subheadline).bold().lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }
}