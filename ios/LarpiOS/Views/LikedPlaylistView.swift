import SwiftUI

/// Плейлист «Лайки из Яндекс Музыки» — реальные лайки аккаунта Яндекс Музыки,
/// демон тянет их из API Яндекса (не из локальной базы) и кэширует.
struct LikedPlaylistView: View {
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var player = PlayerEngine.shared

    var body: some View {
        Group {
            if library.yandexLiked.isEmpty {
                if library.yandexLikesLoading {
                    Spacer()
                    ProgressView("Загружаю лайки…")
                    Spacer()
                } else {
                    ContentUnavailableViewCompat(
                        systemImage: "heart",
                        title: "Пока нет лайков",
                        message: "Лайкай треки в Яндекс Музыке — они подтянутся автоматически"
                    )
                }
            } else {
                List {
                    ForEach(Array(library.yandexLiked.enumerated()), id: \.element.searchKey) { idx, track in
                        Button {
                            player.play(library.yandexLiked, startAt: idx)
                        } label: {
                            TrackRowView(track: track,
                                         isPlaying: player.currentTrack?.searchKey == track.searchKey)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                library.toggleLike(track)
                            } label: {
                                Label("Убрать", systemImage: "heart.slash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Лайки из Яндекс Музыки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DownloadAllButton(tracks: library.yandexLiked)
            }
        }
        .onAppear { library.reloadLiked() }
    }
}