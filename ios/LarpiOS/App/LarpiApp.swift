import SwiftUI
import UIKit

@MainActor
final class LarpiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }
}

@main
struct LarpiApp: App {
    @UIApplicationDelegateAdaptor(LarpiAppDelegate.self) private var appDelegate

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
