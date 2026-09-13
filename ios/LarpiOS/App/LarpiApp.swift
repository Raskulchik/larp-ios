import SwiftUI

@main
struct LarpiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    _ = LibraryStore.shared // инициализация БД в Documents
                    _ = PlayerEngine.shared  // настройка AVPlayer/Control Center
                }
        }
    }
}