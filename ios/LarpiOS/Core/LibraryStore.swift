import Foundation

/// Хранилища (лайки/плейлисты) поверх larp-core. Все тяжёлые вызовы — через BridgeQueue.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var liked: [Track] = []
    @Published var playlists: [PlaylistInfo] = []
    @Published var likedKeySet: Set<String> = []

    private init() {
        bootstrap()
    }

    /// Открыть БД в Documents при первом запуске.
    func bootstrap() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        BridgeQueue.shared.run {
            try RustBridge.shared.dbOpen(directory: dir)
        } then: { _ in
            self.reload()
        }
    }

    func reload() {
        reloadLiked()
        reloadPlaylists()
    }

    func reloadLiked() {
        BridgeQueue.shared.run {
            try RustBridge.shared.getLiked()
        } then: { result in
            if case .success(let tracks) = result {
                self.liked = tracks
                self.likedKeySet = Set(tracks.map { $0.searchKey })
            }
        }
    }

    func reloadPlaylists() {
        BridgeQueue.shared.run {
            try RustBridge.shared.playlistList()
        } then: { result in
            if case .success(let pls) = result {
                self.playlists = pls
            }
        }
    }

    // ============ лайки ============

    func toggleLike(_ track: Track) {
        if likedKeySet.contains(track.searchKey) {
            BridgeQueue.shared.run {
                try RustBridge.shared.unlike(source: track.source, trackId: track.id)
            } then: { _ in
                self.reloadLiked()
            }
        } else {
            BridgeQueue.shared.run {
                try RustBridge.shared.like(track)
            } then: { _ in
                self.reloadLiked()
            }
        }
    }

    // ============ плейлисты ============

    func createPlaylist(name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        BridgeQueue.shared.run {
            try RustBridge.shared.createPlaylist(name: clean)
        } then: { _ in
            self.reloadPlaylists()
        }
    }

    func deletePlaylist(_ playlist: PlaylistInfo) {
        BridgeQueue.shared.run {
            try RustBridge.shared.playlistDelete(id: playlist.id)
        } then: { _ in
            self.reloadPlaylists()
        }
    }

    func addToPlaylist(_ playlist: PlaylistInfo, track: Track) {
        BridgeQueue.shared.run {
            try RustBridge.shared.playlistAdd(id: playlist.id, track: track)
        } then: { _ in
            self.reloadPlaylists()
        }
    }

    func removeFromPlaylist(_ playlist: PlaylistInfo, track: Track) {
        BridgeQueue.shared.run {
            try RustBridge.shared.playlistRemove(id: playlist.id, source: track.source, trackId: track.id)
        } then: { _ in
            self.reloadPlaylists()
        }
    }

    func tracks(_ playlist: PlaylistInfo) async -> [Track] {
        await withCheckedContinuation { cont in
            BridgeQueue.shared.run {
                try RustBridge.shared.playlistTracks(id: playlist.id)
            } then: { result in
                cont.resume(returning: (try? result.get()) ?? [])
            }
        }
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

        let data = (try? Data(contentsOf: src)) ?? Data()
        let key = data.md5Hex
        let dest = downloads.appendingPathComponent("\(key).mp3")
        do {
            try data.write(to: dest)
        } catch {
            return
        }

        let base = fileName.split(separator: ".").first.map(String.init) ?? fileName
        let title = base
        let track = Track(
            id: key,
            title: title,
            artist: "Локальный файл",
            source: "local",
            previewUrl: nil,
            artworkUrl: nil,
            durationMs: nil
        )
        if !localFileKeys.contains(key) {
            localFiles.append(track)
            localFileKeys.insert(key)
            persistLocalFiles()
        }
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
