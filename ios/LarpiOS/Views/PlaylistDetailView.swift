import SwiftUI

struct PlaylistDetailView: View {
    let playlist: PlaylistInfo

    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var player = PlayerEngine.shared
    @State private var tracks: [Track] = []

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableViewCompat(
                    systemImage: "music.note",
                    title: "Пустой плейлист",
                    message: "В поиске у трека выбери «В плейлист»"
                )
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.searchKey) { idx, track in
                        Button {
                            player.play(tracks, startAt: idx)
                        } label: {
                            TrackRowView(track: track,
                                         isPlaying: player.currentTrack?.searchKey == track.searchKey)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                library.removeFromPlaylist(playlist, track: track)
                                tracks.removeAll { $0.searchKey == track.searchKey }
                            } label: { Label("Убрать", systemImage: "minus.circle") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DownloadAllButton(tracks: tracks)
            }
        }
        .task { tracks = await library.tracks(playlist) }
    }
}