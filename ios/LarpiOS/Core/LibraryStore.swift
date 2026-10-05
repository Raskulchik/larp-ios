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
    /// Сколько изменений лайков ждут отправки на компьютер (мы были оффлайн).
    @Published var pendingSyncCount = 0

    /// Одно изменение из оффлайн-очереди: лайк (с треком) или анлайк (по ключу).
    private struct PendingLike: Codable {
        let key: String
        let isLiked: Bool
        let track: Track?
    }
    private var pendingLikes: [PendingLike] = []

    private init() {
        loadPendingLikes()
        reload()
    }

    func reload() {
        reloadLiked()
        reloadPlaylists()
        loadLocalFiles()
    }

    func reloadLiked(autoDownload: Bool = false) {
        Task {
            // Библиотека должна быть видна сразу — даже без сети. Показываем локальный кэш
            // и накладываем на него оффлайн-очередь, затем сверяемся с компьютером.
            self.applyCacheAndPendingToMemory()
            let fresh = await self.syncLiked()
            // Вкладка «Библиотека»: после загрузки списка лайков автоматом качаем
            // их на телефон. Уже скачанные и уже качающиеся пропускаются, файлы,
            // которые демон уже скачал на комп, передаются с компа, а не качаются заново.
            if autoDownload && !fresh.isEmpty {
                DownloadManager.shared.downloadAll(fresh)
            }
            self.refreshYandexLikes()
        }
    }

    // ============ сверка с компьютером ============

    /// Отправляет оффлайн-очередь телефона на демон и подтягивает итоговое состояние.
    /// Очередь выигрывает у состояния сервера по тем трекам, которых она касается:
    /// это явные действия пользователя, сделанные без сети.
    /// - Returns: актуальный список лайков (пустой, если демон недоступен).
    @discardableResult
    func syncLiked() async -> [Track] {
        if !pendingLikes.isEmpty {
            let sent = pendingLikes
            let ops: [DaemonAPI.LikeOpPayload] = sent.map { op -> DaemonAPI.LikeOpPayload in
                guard let track = op.track else {
                    return .unlike(source: trackSource(op.key), trackId: trackId(op.key))
                }
                return op.isLiked ? .like(track) : .unlike(source: track.source, trackId: track.id)
            }
            do {
                let fresh = try await DaemonAPI.syncLiked(ops)
                // Снимаем с очереди только то, что реально отправили: если во время запроса
                // пользователь нажал лайк ещё раз, его новое действие должно уцелеть.
                if pendingLikes.prefix(sent.count).map({ $0.key }) == sent.map({ $0.key }) {
                    pendingLikes.removeFirst(sent.count)
                    savePendingLikes()
                }
                applyServerLiked(fresh)
                return fresh
            } catch {
                // Сети нет — очередь остаётся на телефоне, показываем локальный кэш.
                return liked
            }
        }
        // Очередь пуста — просто подтягиваем состояние с компьютера.
        if let fresh = try? await DaemonAPI.liked() {
            applyServerLiked(fresh)
            return fresh
        }
        return liked
    }

    private func applyServerLiked(_ tracks: [Track]) {
        liked = tracks
        likedKeySet = Set(tracks.map { $0.searchKey })
        saveCachedLiked(tracks)
    }

    // ============ оффлайн-очередь лайков ============

    private func pendingLikesURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingLikes.json")
    }

    private func loadPendingLikes() {
        guard let data = try? Data(contentsOf: pendingLikesURL()),
              let ops = try? JSONDecoder().decode([PendingLike].self, from: data) else { return }
        pendingLikes = ops
        pendingSyncCount = ops.count
    }

    private func savePendingLikes() {
        if let data = try? JSONEncoder().encode(pendingLikes) {
            try? data.write(to: pendingLikesURL())
        }
        pendingSyncCount = pendingLikes.count
    }

    /// Кэш с демона + то, что телефон наделал оффлайн (последнее действие по треку).
    private func applyCacheAndPendingToMemory() {
        var list = loadCachedLiked()
        for op in pendingLikes {
            guard let track = trackForPendingOp(op, in: list) else { continue }
            list = op.isLiked ? upsert(track, in: list) : list.filter { $0.searchKey != op.key }
        }
        liked = list
        likedKeySet = Set(list.map { $0.searchKey })
    }

    /// Для анлайка трек мог быть только в кэше — ищем его там.
    private func trackForPendingOp(_ op: PendingLike, in list: [Track]) -> Track? {
        if let track = op.track { return track }
        let source = trackSource(op.key)
        let id = trackId(op.key)
        return list.first { $0.source == source && $0.id == id }
    }

    private func upsert(_ track: Track, in list: [Track]) -> [Track] {
        var out = list.filter { $0.searchKey != track.searchKey }
        out.insert(track, at: 0)
        return out
    }

    private func trackSource(_ key: String) -> String {
        String(key.prefix(while: { $0 != ":" }))
    }

    private func trackId(_ key: String) -> String {
        guard let idx = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: idx)...])
    }

    /// Добавить изменение в очередь, схлопывая повторы по одному треку (последнее действие важнее).
    private func enqueue(_ track: Track, isLiked: Bool) {
        let op = PendingLike(key: track.searchKey, isLiked: isLiked, track: track)
        pendingLikes.removeAll { $0.key == op.key }
        pendingLikes.append(op)
        savePendingLikes()
    }

    // ============ оффлайн-кэш списка лайков ============

    private func cachedLikedURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LikedCache.json")
    }

    private func loadCachedLiked() -> [Track] {
        guard let data = try? Data(contentsOf: cachedLikedURL()) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private func saveCachedLiked(_ tracks: [Track]) {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: cachedLikedURL())
        }
    }

    func refreshYandexLikes() {
        // Оффлайн-first: сразу показываем кэш «Лайков из Яндекс Музыки».
        yandexLiked = loadCachedYandexLikes()
        Task {
            yandexLikesLoading = true
            defer { yandexLikesLoading = false }
            if let likes = try? await DaemonAPI.yandexLikes() {
                yandexLiked = likes
                saveCachedYandexLikes(likes)
            }
            // Сети нет — остаётся кэш.
        }
    }

    private func cachedYandexLikesURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YandexLikesCache.json")
    }

    private func loadCachedYandexLikes() -> [Track] {
        guard let data = try? Data(contentsOf: cachedYandexLikesURL()) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private func saveCachedYandexLikes(_ tracks: [Track]) {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: cachedYandexLikesURL())
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
        let wasLiked = likedKeySet.contains(track.searchKey)
        let nowLiked = !wasLiked

        // Оптимистично меняем локальное состояние: работает и без сети, и не мигает.
        liked = nowLiked ? upsert(track, in: liked) : liked.filter { $0.searchKey != track.searchKey }
        if nowLiked {
            likedKeySet.insert(track.searchKey)
        } else {
            likedKeySet.remove(track.searchKey)
        }
        saveCachedLiked(liked)
        enqueue(track, isLiked: nowLiked)

        // Новый лайк из «Библиотеки» тоже качаем сразу.
        if nowLiked && autoDownload {
            DownloadManager.shared.download(track) { _ in }
        }

        Task { await syncLiked() }
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

    func loadLocalFiles() {
        if let data = try? Data(contentsOf: Self.localFilesURL) {
            if let arr = try? JSONDecoder().decode([Track].self, from: data) {
                localFiles = arr
                localFileKeys = Set(arr.map(\.searchKey))
            }
        }
        // Реальная длительность уже скачанных mp3 (YT Music её часто не отдаёт в поиске).
        DownloadManager.shared.measureLocalDurations()
    }

    private static var localFilesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFiles.json")
    }
}