import SwiftUI

struct PlaylistDetailView: View {
    let playlist: PlaylistInfo

    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var player = PlayerEngine.shared
    @State private var tracks: [Track] = []
    @State private var searchText = ""

    private var filteredTracks: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return tracks }
        return tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(q) ||
            track.artist.localizedCaseInsensitiveContains(q)
        }
    }

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
                    ForEach(Array(filteredTracks.enumerated()), id: \.element.searchKey) { idx, track in
                        Button {
                            player.play(filteredTracks, startAt: idx)
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
                .searchable(text: $searchText, prompt: "Поиск в плейлисте")
                .refreshable { tracks = await library.tracks(playlist) }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DownloadAllButton(tracks: filteredTracks.isEmpty && searchText.isEmpty ? tracks : filteredTracks)
            }
        }
        .task {
            tracks = library.cachedTracks(playlist)
            tracks = await library.tracks(playlist)
        }
    }
}
