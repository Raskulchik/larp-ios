import SwiftUI

struct SearchView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var source: SourceKind = .ytmusic
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorText: String?
    @State private var playlistTarget: Track?
    @State private var showingPlaylistPicker = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Источник", selection: $source) {
                    ForEach(SourceKind.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if source == .yandex && settings.yandexToken.isEmpty {
                    Text("Для Yandex нужен токен в Настройках")
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .padding(.top, 6)
                }

                HStack {
                    TextField("Трек, исполнитель…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    Button(action: runSearch) {
                        if isSearching {
                            ProgressView()
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundColor(.red)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.searchKey) { idx, track in
                        Button {
                            player.play(results, startAt: idx)
                        } label: {
                            TrackRowView(track: track,
                                         isPlaying: player.currentTrack?.searchKey == track.searchKey)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button {
                                downloads.download(track) { _ in }
                            } label: {
                                Label("Качать", systemImage: "arrow.down.circle")
                            }
                            .tint(.blue)

                            Button {
                                playlistTarget = track
                                showingPlaylistPicker = true
                            } label: {
                                Label("В плейлист", systemImage: "text.badge.plus")
                            }
                            .tint(.indigo)
                        }
                        .swipeActions(edge: .leading) {
                            let liked = library.likedKeySet.contains(track.searchKey)
                            Button {
                                library.toggleLike(track)
                            } label: {
                                Label(liked ? "Убрать лайк" : "Лайк",
                                      systemImage: liked ? "heart.slash" : "heart")
                            }
                            .tint(liked ? .gray : .red)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Поиск")
            .sheet(isPresented: $showingPlaylistPicker) {
                if let target = playlistTarget {
                    PlaylistPicker(highlightedTrack: target)
                }
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        errorText = nil
        isSearching = true
        let src = source
        let token = src == .yandex ? settings.yandexToken : ""

        BridgeQueue.shared.run {
            try RustBridge.shared.search(src, query: q, yandexToken: token)
        } then: { result in
            isSearching = false
            switch result {
            case .success(let tracks):
                results = tracks
                if tracks.isEmpty { errorText = "Ничего не найдено" }
            case .failure(let e):
                errorText = e.localizedDescription
            }
        }
    }
}