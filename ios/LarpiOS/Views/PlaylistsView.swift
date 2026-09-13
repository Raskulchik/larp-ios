import SwiftUI

struct PlaylistsView: View {
    @ObservedObject private var library = LibraryStore.shared
    @State private var showingCreate = false
    @State private var newName = ""

    var body: some View {
        NavigationView {
            Group {
                if library.playlists.isEmpty {
                    ContentUnavailableViewCompat(
                        systemImage: "music.note.list",
                        title: "Нет плейлистов",
                        message: "Нажми «+» сверху, чтобы создать"
                    )
                } else {
                    List {
                        ForEach(library.playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(.accentColor)
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
                    .listStyle(.plain)
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
            .onAppear { library.reloadPlaylists() }
        }
    }

    private func pluralSuffix(_ n: Int) -> String {
        let r = n % 10, q = n % 100
        if r == 1 && q != 11 { return "" }
        if (2...4).contains(r) && !(12...14).contains(q) { return "а" }
        return "ов"
    }
}