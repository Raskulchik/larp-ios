import SwiftUI

struct PlaylistPicker: View {
    let highlightedTrack: Track
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if library.playlists.isEmpty {
                    Text("Создай плейлист в разделе «Плейлисты»")
                        .foregroundColor(.secondary)
                }
                ForEach(library.playlists) { playlist in
                    Button {
                        library.addToPlaylist(playlist, track: highlightedTrack)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "music.note.list")
                            Text(playlist.name)
                            Spacer()
                            Text("\(playlist.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("В плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .onAppear { library.reloadPlaylists() }
    }
}