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
        guard let base = settings.daemonBaseURL else {
            errorText = "Сервер не настроен (указать IP в Настройках)"
            return
        }
        errorText = nil
        isSearching = true
        let src = source

        guard var comps = URLComponents(url: base.appendingPathComponent("api/search"),
                                        resolvingAgainstBaseURL: false) else {
            isSearching = false
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "source", value: src.rawValue),
            URLQueryItem(name: "query", value: q)
        ]
        guard let url = comps.url else {
            isSearching = false
            return
        }

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    let msg = Self.searchError(from: data) ?? "демон ответил \(http.statusCode)"
                    throw NSError(domain: "search", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: msg])
                }
                struct SearchResponse: Decodable { let results: [Track] }
                let searchResults = try JSONDecoder().decode(SearchResponse.self, from: data).results
                isSearching = false
                results = searchResults
                if results.isEmpty { errorText = "Ничего не найдено" }
            } catch {
                isSearching = false
                errorText = error.localizedDescription
            }
        }
    }

    private static func searchError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["error"] as? String
    }
}