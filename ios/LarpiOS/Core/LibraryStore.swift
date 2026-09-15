import Foundation

/// Хранилища (лайки/плейлисты) поверх общей с music-player-tui базы через демон.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var liked: [Track] = []
    /// Лайки аккаунта Яндекс Музыки («Мне нравится») — берём из API Яндекса через демон,
    /// а не из локальной базы.
    @Published var yandexLiked: [Track] = []
    @Published var yandexLikesLoading = false
    @Published var playlists: [PlaylistInfo] = []
    @Published var likedKeySet: Set<String> = []

    private init() {
        reload()
    }

    func reload() {
        reloadLiked()
        reloadPlaylists()
        loadLocalFiles()
    }

    func reloadLiked(autoDownload: Bool = false) {
        Task {
            if let all = try? await DaemonAPI.liked() {
                self.liked = all
                self.likedKeySet = Set(all.map { $0.searchKey })
                // Вкладка «Библиотека»: после загрузки списка лайков автоматом качаем
                // их на телефон. Уже скачанные и уже качающиеся пропускаются, файлы,
                // которые демон уже скачал на комп, передаются с компа, а не качаются заново.
                if autoDownload {
                    DownloadManager.shared.downloadAll(all)
                }
            }
            refreshYandexLikes()
        }
    }

    func refreshYandexLikes() {
        Task {
            yandexLikesLoading = true
            defer { yandexLikesLoading = false }
            if let likes = try? await DaemonAPI.yandexLikes() {
                self.yandexLiked = likes
            }
        }
    }

    func reloadPlaylists() {
        Task {
            if let pls = try? await DaemonAPI.playlists() {
                self.playlists = pls
            }
        }
    }

    // ============ лайки ============

    func toggleLike(_ track: Track, autoDownload: Bool = false) {
        Task {
            if likedKeySet.contains(track.searchKey) {
                try? await DaemonAPI.unlike(source: track.source, trackId: track.id)
            } else {
                try? await DaemonAPI.like(track)
                // Новый лайк из «Библиотеки» тоже качаем сразу.
                if autoDownload {
                    DownloadManager.shared.download(track) { _ in }
                }
            }
            reloadLiked(autoDownload: autoDownload)
        }
    }

    // ============ плейлисты ============

    func createPlaylist(name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        Task {
            try? await DaemonAPI.createPlaylist(name: clean)
            reloadPlaylists()
        }
    }

    func deletePlaylist(_ playlist: PlaylistInfo) {
        Task {
            try? await DaemonAPI.deletePlaylist(id: playlist.id)
            reloadPlaylists()
        }
    }

    func addToPlaylist(_ playlist: PlaylistInfo, track: Track) {
        Task {
            try? await DaemonAPI.addToPlaylist(id: playlist.id, track: track)
            reloadPlaylists()
        }
    }

    func removeFromPlaylist(_ playlist: PlaylistInfo, track: Track) {
        Task {
            try? await DaemonAPI.removeFromPlaylist(id: playlist.id, source: track.source, trackId: track.id)
            reloadPlaylists()
        }
    }

    func tracks(_ playlist: PlaylistInfo) async -> [Track] {
        (try? await DaemonAPI.playlistTracks(id: playlist.id)) ?? []
    }

    // ============ файлы с телефона ============

    @Published private(set) var localFiles: [Track] = []
    @Published private(set) var localFileKeys: Set<String> = []

    /// Импорт трека файлом с телефона: копируем в Documents/Downloads/<md5>.mp3
    /// и добавляем в библиотеку. Всё локально — демон/сеть не нужны.
    func addLocalFile(from src: URL, fileName: String) {
        let fm = FileManager.default
        let downloads = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: src), !data.isEmpty else { return }

        let title = (fileName as NSString).deletingPathExtension

        let track = Track(
            id: data.md5Hex,
            title: title,
            artist: "Локальный файл",
            source: "local",
            previewUrl: nil,
            artworkUrl: nil,
            durationMs: nil
        )
        let key = DownloadManager.taskKey(for: track) // md5(searchKey)
        let dest = downloads.appendingPathComponent("\(key).mp3")

        // Не копируем повторно
        guard !fm.fileExists(atPath: dest.path) else {
            if !localFileKeys.contains(track.searchKey) {
                localFiles.append(track)
                localFileKeys.insert(track.searchKey)
                persistLocalFiles()
            }
            return
        }

        do {
            try data.write(to: dest)
        } catch {
            return
        }

        if !localFileKeys.contains(track.searchKey) {
            localFiles.append(track)
            localFileKeys.insert(track.searchKey)
            persistLocalFiles()
        }
    }

    func removeLocalFile(_ track: Track) {
        if let url = DownloadManager.shared.localFileURL(for: track) {
            try? FileManager.default.removeItem(at: url)
        }
        localFiles.removeAll { $0.searchKey == track.searchKey }
        localFileKeys.remove(track.searchKey)
        persistLocalFiles()
    }

    private func persistLocalFiles() {
        let fm = FileManager.default
        guard let data = try? JSONEncoder().encode(localFiles) else { return }
        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFiles.json")
        try? data.write(to: url)
    }

    private func loadLocalFiles() {
        let fm = FileManager.default
        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFiles.json")
        guard let data = try? Data(contentsOf: url) else { return }
        if let arr = try? JSONDecoder().decode([Track].self, from: data) {
            localFiles = arr
            localFileKeys = Set(arr.map(\.searchKey))
        }
    }
}