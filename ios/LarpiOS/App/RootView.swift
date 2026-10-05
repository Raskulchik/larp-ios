import SwiftUI

struct RootView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { phase in
            // Вернулись в приложение — доливаем накопленное оффлайн и сверяемся с компом.
            guard phase == .active else { return }
            Task { await LibraryStore.shared.syncLiked() }
        }
    }
}