import SwiftUI

struct PlaylistsView: View {
    @ObservedObject private var library = LibraryStore.shared
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var searchText = ""

    private var filteredPlaylists: [PlaylistInfo] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return library.playlists }
        return library.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationView {
            List {
                NavigationLink {
                    LikedPlaylistView()
                } label: {
                    HStack {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .frame(width: 32)
                        VStack(alignment: .leading) {
                            Text("Лайки из Яндекс Музыки").font(.headline)
                            Text("\(library.yandexLiked.count) трек\(pluralSuffix(library.yandexLiked.count)) из аккаунта Яндекс Музыки")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("Мои плейлисты") {
                    if library.playlists.isEmpty {
                        Text("Нет плейлистов — создай через «+» сверху")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredPlaylists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(.accentColor)
                                        .frame(width: 32)
                                    VStack(alignment: .leading) {
                                        Text(playlist.name).font(.headline)
                                        Text("\(playlist.count) трек\(pluralSuffix(playlist.count))")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    library.deletePlaylist(playlist)
                                } label: { Label("Удалить", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Поиск по плейлистам")
            .refreshable { await library.syncPlaylists() }
            .safeAreaInset(edge: .bottom) {
                if library.pendingPlaylistSyncCount > 0 {
                    Button {
                        Task { await library.syncPlaylists() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Изменения плейлистов ждут синхронизации: \(library.pendingPlaylistSyncCount)")
                            Spacer()
                            Text("Повторить").fontWeight(.semibold)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .adaptiveGlass(cornerRadius: 12)
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Плейлисты")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newName = ""
                        showingCreate = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .alert("Новый плейлист", isPresented: $showingCreate) {
                TextField("Название", text: $newName)
                Button("Создать") { library.createPlaylist(name: newName) }
                Button("Отмена", role: .cancel) {}
            }
            .onAppear {
                library.reloadPlaylists()
                library.reloadLiked()
            }
        }
    }

    private func pluralSuffix(_ n: Int) -> String {
        let r = n % 10, q = n % 100
        if r == 1 && q != 11 { return "" }
        if (2...4).contains(r) && !(12...14).contains(q) { return "а" }
        return "ов"
    }
}
