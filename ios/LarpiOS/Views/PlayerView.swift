import SwiftUI

/// Полноэкранный плеер (sheet).
struct PlayerView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss

    private var isSeeking = false

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            Spacer(minLength: 8)

            artwork

            VStack(spacing: 6) {
                Text(player.currentTrack?.title ?? "")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text(player.currentTrack?.artist ?? "")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { newValue in
                            player.seek(to: newValue)
                        }
                    ),
                    in: 0...max(player.duration, 1)
                )
                HStack {
                    Text(secondsText(player.currentTime))
                    Spacer()
                    Text(secondsText(player.duration))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)

            controls

            Spacer(minLength: 24)
        }
        .background(Color(.systemBackground))
    }

    private var artwork: some View {
        Group {
            if let img = player.artwork {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground))
                    Image(systemName: "music.note")
                        .font(.system(size: 56))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 280, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 12)
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }
}