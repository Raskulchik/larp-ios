import SwiftUI

/// Полноэкранный плеер (sheet).
struct PlayerView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

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

            queueSection

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

    private var queueSection: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showQueue.toggle() }
                } label: {
                    Label("Очередь (\(player.queue.count))", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)

                Spacer()

                if player.queue.count > 1 {
                    Button {
                        player.shuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundColor(player.isShuffleOn ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        cycleRepeat()
                    } label: {
                        Image(systemName: repeatIcon)
                            .foregroundColor(player.repeatMode != .off ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            if showQueue {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.searchKey) { idx, track in
                        Button {
                            player.playAt(idx)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(idx == player.currentIndex ? .accentColor : .secondary)
                                    .frame(width: 26, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .font(.subheadline)
                                        .foregroundColor(idx == player.currentIndex ? .accentColor : .primary)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let d = track.durationMs, d > 0 {
                                    Text(secondsText(Double(d) / 1000))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                player.removeAt(idx)
                            } label: {
                                Label("Убрать", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 240)
            }
        }
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .one: return "repeat.1"
        case .all, .off: return "repeat"
        }
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }
}