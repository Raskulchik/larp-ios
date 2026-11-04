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
    @Published private(set) var pendingPlaylistSyncCount = 0
    /// Сколько изменений лайков ждут отправки на компьютер (мы были оффлайн).
    @Published var pendingSyncCount = 0

    /// Одно изменение из оффлайн-очереди: лайк (с треком) или анлайк (по ключу).
    private struct PendingLike: Codable {
        let key: String
        let isLiked: Bool
        let track: Track?
    }
    private var pendingLikes: [PendingLike] = []

    private struct PendingPlaylistOperation: Codable {
        enum Kind: String, Codable { case create, delete, add, remove }
        let kind: Kind
        let playlistName: String
        var track: Track? = nil
        var source: String? = nil
        var trackId: String? = nil
    }
    private var pendingPlaylistOperations: [PendingPlaylistOperation] = []
    private var playlistSyncInProgress = false
    private var playlistTrackCache: [String: [Track]] = [:]

    private init() {
        loadPendingLikes()
        loadPlaylistCache()
        loadPendingPlaylistOperations()
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
        if let cached = loadCachedPlaylists() {
            playlists = cached
        }
        Task {
            await syncPlaylists()
        }
    }

    private struct PlaylistCache: Codable {
        var playlists: [PlaylistInfo]
        var tracks: [String: [Track]]
    }

    private func playlistCacheURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaylistsCache.json")
    }

    private func loadCachedPlaylists() -> [PlaylistInfo]? {
        guard let data = try? Data(contentsOf: playlistCacheURL()),
              let cache = try? JSONDecoder().decode(PlaylistCache.self, from: data) else { return nil }
        playlistTrackCache = cache.tracks
        return cache.playlists
    }

    private func loadPlaylistCache() {
        _ = loadCachedPlaylists()
    }

    private func savePlaylistCache() {
        let cache = PlaylistCache(playlists: playlists, tracks: playlistTrackCache)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: playlistCacheURL(), options: .atomic)
    }

    private func pendingPlaylistOperationsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingPlaylistOperations.json")
    }

    private func loadPendingPlaylistOperations() {
        guard let data = try? Data(contentsOf: pendingPlaylistOperationsURL()),
              let operations = try? JSONDecoder().decode([PendingPlaylistOperation].self, from: data) else { return }
        pendingPlaylistOperations = operations
        pendingPlaylistSyncCount = operations.count
    }

    private func savePendingPlaylistOperations() {
        guard let data = try? JSONEncoder().encode(pendingPlaylistOperations) else { return }
        try? data.write(to: pendingPlaylistOperationsURL(), options: .atomic)
        pendingPlaylistSyncCount = pendingPlaylistOperations.count
    }

    /// Apply queued phone changes to the same database used by larp-music-player,
    /// then refresh the local cache. Operations use playlist names so they also
    /// work for playlists created on the phone while it was offline.
    func syncPlaylists() async {
        guard !playlistSyncInProgress else { return }
        playlistSyncInProgress = true
        defer { playlistSyncInProgress = false }

        do {
            while true {
                var remote = try await DaemonAPI.playlists()
                while let operation = pendingPlaylistOperations.first {
                    let existing = remote.first { $0.name == operation.playlistName }
                    switch operation.kind {
                    case .create:
                        if existing == nil {
                            do {
                                let id = try await DaemonAPI.createPlaylist(name: operation.playlistName)
                                remote.append(PlaylistInfo(id: id, name: operation.playlistName, count: 0))
                            } catch {
                                // Another client may have created this same name
                                // after the list was fetched. Reconcile by name.
                                remote = try await DaemonAPI.playlists()
                                if !remote.contains(where: { $0.name == operation.playlistName }) {
                                    throw error
                                }
                            }
                        }
                    case .delete:
                        if let existing {
                            try await DaemonAPI.deletePlaylist(id: existing.id)
                            remote.removeAll { $0.name == operation.playlistName }
                        }
                    case .add:
                        if let existing, let track = operation.track {
                            try await DaemonAPI.addToPlaylist(id: existing.id, track: track)
                        }
                    case .remove:
                        if let existing, let source = operation.source, let trackId = operation.trackId {
                            try await DaemonAPI.removeFromPlaylist(id: existing.id, source: source, trackId: trackId)
                        }
                    }
                    pendingPlaylistOperations.removeFirst()
                    savePendingPlaylistOperations()
                }
                let fresh = try await DaemonAPI.playlists()
                guard pendingPlaylistOperations.isEmpty else { continue }
                playlists = fresh
                savePlaylistCache()
                break
            }
        } catch {
            // Keep showing cached data and retain the failed operation for retry.
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
        guard !playlists.contains(where: { $0.name == clean }) else { return }
        let localId = -Int64(Date().timeIntervalSince1970 * 1_000_000)
        playlists.insert(PlaylistInfo(id: localId, name: clean, count: 0), at: 0)
        pendingPlaylistOperations.append(PendingPlaylistOperation(kind: .create, playlistName: clean))
        savePendingPlaylistOperations()
        savePlaylistCache()
        Task { await syncPlaylists() }
    }

    func deletePlaylist(_ playlist: PlaylistInfo) {
        playlists.removeAll { $0.name == playlist.name }
        playlistTrackCache.removeValue(forKey: playlist.name)
        pendingPlaylistOperations.append(PendingPlaylistOperation(kind: .delete, playlistName: playlist.name))
        savePendingPlaylistOperations()
        savePlaylistCache()
        Task { await syncPlaylists() }
    }

    func addToPlaylist(_ playlist: PlaylistInfo, track: Track) {
        var tracks = playlistTrackCache[playlist.name] ?? []
        guard !tracks.contains(where: { $0.searchKey == track.searchKey }) else { return }
        tracks.append(track)
        playlistTrackCache[playlist.name] = tracks
        playlists = playlists.map {
            $0.name == playlist.name ? PlaylistInfo(id: $0.id, name: $0.name, count: tracks.count) : $0
        }
        pendingPlaylistOperations.append(PendingPlaylistOperation(kind: .add, playlistName: playlist.name, track: track))
        savePendingPlaylistOperations()
        savePlaylistCache()
        Task { await syncPlaylists() }
    }

    func removeFromPlaylist(_ playlist: PlaylistInfo, track: Track) {
        playlistTrackCache[playlist.name]?.removeAll { $0.searchKey == track.searchKey }
        let count = playlistTrackCache[playlist.name]?.count ?? max(0, playlist.count - 1)
        playlists = playlists.map {
            $0.name == playlist.name ? PlaylistInfo(id: $0.id, name: $0.name, count: count) : $0
        }
        pendingPlaylistOperations.append(PendingPlaylistOperation(
            kind: .remove,
            playlistName: playlist.name,
            source: track.source,
            trackId: track.id
        ))
        savePendingPlaylistOperations()
        savePlaylistCache()
        Task { await syncPlaylists() }
    }

    func cachedTracks(_ playlist: PlaylistInfo) -> [Track] {
        playlistTrackCache[playlist.name] ?? []
    }

    func tracks(_ playlist: PlaylistInfo) async -> [Track] {
        guard playlist.id > 0,
              !pendingPlaylistOperations.contains(where: { $0.playlistName == playlist.name }) else {
            return cachedTracks(playlist)
        }
        if let tracks = try? await DaemonAPI.playlistTracks(id: playlist.id) {
            playlistTrackCache[playlist.name] = tracks
            savePlaylistCache()
            return tracks
        }
        return cachedTracks(playlist)
    }

    // ============ файлы с телефона ============

    @Published private(set) var localFiles: [Track] = []
    @Published private(set) var localFileKeys: Set<String> = []

    /// Import through a security-scoped, coordinated read (Files/iCloud), off
    /// the main actor so large audio files do not freeze the library screen.
    func addLocalFile(from src: URL, fileName: String) async throws {
        let track = try await Task.detached(priority: .userInitiated) {
            try copyLocalAudioFile(from: src, fileName: fileName)
        }.value
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
        // Реальная длительность импортированных/скачанных аудиофайлов.
        DownloadManager.shared.measureLocalDurations()
    }

    private static var localFilesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFiles.json")
    }
}

private enum LocalAudioImportError: LocalizedError {
    case accessDenied
    case emptyFile
    case readFailed(Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Нет доступа к выбранному файлу"
        case .emptyFile: return "Выбранный аудиофайл пуст"
        case .readFailed(let error): return "Не удалось скопировать аудиофайл: \(error.localizedDescription)"
        }
    }
}

private func copyLocalAudioFile(from source: URL, fileName: String) throws -> Track {
    let accessing = source.startAccessingSecurityScopedResource()
    defer { if accessing { source.stopAccessingSecurityScopedResource() } }

    let fileManager = FileManager.default
    let downloads = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Downloads", isDirectory: true)
    try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)

    let rawExtension = (fileName as NSString).pathExtension.lowercased()
    let fileExtension = rawExtension.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil
        ? rawExtension : "mp3"
    let title = (fileName as NSString).deletingPathExtension
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var readError: Error?
    var importedTrack: Track?

    coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
        do {
            let values = try readableURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw LocalAudioImportError.emptyFile }
            let data = try Data(contentsOf: readableURL, options: .mappedIfSafe)
            guard !data.isEmpty else { throw LocalAudioImportError.emptyFile }

            let track = Track(
                id: data.md5Hex,
                title: title,
                artist: "Локальный файл",
                source: "local",
                previewUrl: nil,
                artworkUrl: nil,
                durationMs: nil,
                localFileExtension: fileExtension
            )
            let destination = downloads.appendingPathComponent("\(track.searchKey.md5Hex).\(fileExtension)")
            if !fileManager.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            importedTrack = track
        } catch {
            readError = error
        }
    }

    if let coordinationError { throw LocalAudioImportError.readFailed(coordinationError) }
    if let readError { throw LocalAudioImportError.readFailed(readError) }
    guard let importedTrack else { throw LocalAudioImportError.accessDenied }
    return importedTrack
}
