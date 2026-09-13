import SwiftUI

struct RootView: View {
    @ObservedObject private var player = PlayerEngine.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                LibraryView()
                    .tabItem { Label("Библиотека", systemImage: "heart.fill") }

                PlaylistsView()
                    .tabItem { Label("Плейлисты", systemImage: "music.note.list") }

                SearchView()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }

                SettingsView()
                    .tabItem { Label("Настройки", systemImage: "gear") }
            }

            if player.currentTrack != nil {
                PlayerBarView()
                    .padding(.bottom, 46)
            }
        }
    }
}