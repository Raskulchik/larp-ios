import AVFoundation
import Foundation
import UIKit

enum AudioFile {
    static func durationMs(of url: URL) async -> Int64? {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return Int64((seconds * 1_000).rounded())
    }
}

private enum DownloadedFileInstaller {
    static func save(_ data: Data, key: String, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(key).mp3")
        let staging = directory.appendingPathComponent(".\(key)-\(UUID().uuidString).download")
        defer { try? fileManager.removeItem(at: staging) }

        try data.write(to: staging, options: .atomic)
        let attributes = try fileManager.attributesOfItem(atPath: staging.path)
        let writtenSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard writtenSize == Int64(data.count) else {
            throw NSError(
                domain: "Larpi.Download",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Данные записались не полностью"]
            )
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    static func freeSpaceDescription(at directory: URL) -> String {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let bytes = try? directory.resourceValues(forKeys: keys).volumeAvailableCapacityForImportantUsage
        guard let bytes else { return "свободное место неизвестно" }
        return "свободно \(bytes / 1_048_576) МБ"
    }
}

/// Owns the complete remote audio lifecycle: cache validation, background transfer,
/// atomic file installation, restoration after relaunch, and per-track UI state.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    static let backgroundSessionIdentifier = "local.larpi.background-downloads"
    private static let bulkStateKey = "larp.backgroundBulkDownload"
    private static let durationsKey = "larp.localDurationsMs"

    struct DownloadTaskInfo {
        var state: String
        var progress: Double
        var fileName: String?
        var error: String?
        var isActive: Bool
    }

    struct BulkDownload: Codable {
        var total: Int
        var done: Int
        var failed: Int
    }

    private struct Waiter {
        let onComplete: ((URL?) -> Void)?
        let countsTowardBulk: Bool
    }

    private struct RequestBuildFailure: Error {
        let message: String
    }

    @Published private(set) var tasks: [String: DownloadTaskInfo] = [:]
    @Published private(set) var bulk: BulkDownload?
    @Published private(set) var bulkActive = false
    @Published private(set) var durations: [String: Int64] = [:]

    private let downloadsDirectory: URL
    private let session: URLSession
    private let fallbackSession: URLSession
    private let delegate: BackgroundDownloadDelegate
    private var waiters: [String: [Waiter]] = [:]
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var bulkKeys = Set<String>()
    private var fallbackTasks: [String: URLSessionDataTask] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsDirectory = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        if let data = UserDefaults.standard.data(forKey: Self.durationsKey),
           let saved = try? JSONDecoder().decode([String: Int64].self, from: data) {
            durations = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.bulkStateKey),
           let saved = try? JSONDecoder().decode(BulkDownload.self, from: data) {
            bulk = saved
            bulkActive = saved.done + saved.failed < saved.total
        }

        let transferDelegate = BackgroundDownloadDelegate()
        delegate = transferDelegate
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForRequest = 6 * 60 * 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: configuration, delegate: transferDelegate, delegateQueue: nil)

        let fallbackConfiguration = URLSessionConfiguration.ephemeral
        fallbackConfiguration.httpMaximumConnectionsPerHost = 1
        fallbackConfiguration.timeoutIntervalForRequest = 6 * 60 * 60
        fallbackConfiguration.timeoutIntervalForResource = 6 * 60 * 60
        fallbackSession = URLSession(configuration: fallbackConfiguration)

        transferDelegate.onProgress = { [weak self] metadata, progress in
            Task { @MainActor [weak self] in self?.transferProgress(metadata, progress: progress) }
        }
        transferDelegate.onFinished = { [weak self] metadata, url in
            Task { @MainActor [weak self] in self?.transferFinished(metadata, at: url) }
        }
        transferDelegate.onFailure = { [weak self] metadata, message in
            Task { @MainActor [weak self] in self?.transferFailed(metadata, message: message) }
        }
        transferDelegate.onFileSystemFailure = { [weak self] metadata, message in
            Task { @MainActor [weak self] in self?.retryWithoutTemporaryFile(metadata, reason: message) }
        }
        transferDelegate.onEventsFinished = { [weak self] in
            Task { @MainActor [weak self] in self?.finishBackgroundEvents() }
        }

        session.getAllTasks { sessionTasks in
            var restored: [RestoredBackgroundTransfer] = []
            for task in sessionTasks {
                guard let metadata = BackgroundTransferMetadata.decode(task.taskDescription) else {
                    task.cancel()
                    continue
                }
                if task.state == .suspended { task.resume() }
                let expected = task.countOfBytesExpectedToReceive
                let progress = expected > 0
                    ? min(100, Double(task.countOfBytesReceived) / Double(expected) * 100)
                    : 0
                restored.append(RestoredBackgroundTransfer(
                    metadata: metadata,
                    progress: progress,
                    isRunning: task.state == .running || task.state == .suspended
                ))
            }
            Task { @MainActor [weak self] in self?.restoreTransfers(restored) }
        }
    }

    private func key(_ track: Track) -> String { track.searchKey.md5Hex }
    static func taskKey(for track: Track) -> String { track.searchKey.md5Hex }
    private func fileURL(for track: Track) -> URL {
        let ext = track.source == "local" ? (track.localFileExtension ?? "mp3") : "mp3"
        return downloadsDirectory.appendingPathComponent("\(key(track)).\(ext)")
    }

    func info(for track: Track) -> DownloadTaskInfo? { tasks[key(track)] }
    func isDownloading(_ track: Track) -> Bool { tasks[key(track)]?.isActive == true }
    func durationMs(for track: Track) -> Int64? { durations[key(track)] ?? track.durationMs }

    /// Synchronous existence check for artwork and UI. Playback and downloads use
    /// validatedLocalFileURL instead of trusting that a file merely exists.
    func localFileURL(for track: Track) -> URL? {
        let url = fileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if track.source != "local" {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= 1_024 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return url
    }

    func validatedLocalFileURL(for track: Track) async -> URL? {
        guard let url = localFileURL(for: track) else { return nil }
        guard track.source != "local" else { return url }
        guard let duration = await AudioFile.durationMs(of: url) else {
            invalidateCachedFile(for: track)
            durations.removeValue(forKey: key(track))
            return nil
        }
        setDuration(duration, forKey: key(track))
        return url
    }

    func invalidateCachedFile(for track: Track) {
        guard track.source != "local" else { return }
        try? FileManager.default.removeItem(at: fileURL(for: track))
    }

    func reportPlaybackError(for track: Track, message: String) {
        tasks[key(track)] = DownloadTaskInfo(
            state: "error", progress: 0, fileName: nil, error: message, isActive: false
        )
    }

    func remoteStreamURL(for track: Track) -> URL? {
        guard let base = AppSettings.shared.daemonBaseURL else { return nil }
        return base.appendingPathComponent("files").appendingPathComponent("\(key(track)).mp3")
    }

    func measureDurationIfMissing(url: URL, track: Track) async -> Int64? {
        let trackKey = key(track)
        if let duration = durations[trackKey] { return duration }
        guard let duration = await AudioFile.durationMs(of: url) else { return track.durationMs }
        setDuration(duration, forKey: trackKey)
        return duration
    }

    func measureLocalDurations() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path)) ?? []
        let supported: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf"]
        for name in files {
            let url = downloadsDirectory.appendingPathComponent(name)
            let trackKey = url.deletingPathExtension().lastPathComponent
            guard supported.contains(url.pathExtension.lowercased()), durations[trackKey] == nil else { continue }
            Task { [weak self] in
                guard let self, let duration = await AudioFile.durationMs(of: url) else { return }
                self.setDuration(duration, forKey: trackKey)
            }
        }
    }

    private func setDuration(_ duration: Int64, forKey trackKey: String) {
        durations[trackKey] = duration
        if let data = try? JSONEncoder().encode(durations) {
            UserDefaults.standard.set(data, forKey: Self.durationsKey)
        }
    }

    func download(_ track: Track, onComplete: ((URL?) -> Void)? = nil) {
        requestDownload(track, force: false, isBulk: false, onComplete: onComplete)
    }

    func redownload(_ track: Track, onComplete: ((URL?) -> Void)? = nil) {
        requestDownload(track, force: true, isBulk: false, onComplete: onComplete)
    }

    private func requestDownload(
        _ track: Track,
        force: Bool,
        isBulk: Bool,
        onComplete: ((URL?) -> Void)?
    ) {
        let trackKey = key(track)
        waiters[trackKey, default: []].append(Waiter(onComplete: onComplete, countsTowardBulk: isBulk))
        guard tasks[trackKey]?.isActive != true else { return }

        tasks[trackKey] = DownloadTaskInfo(
            state: force ? "restarting" : "checking", progress: 0,
            fileName: nil, error: nil, isActive: true
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !force, let cachedURL = await self.validatedLocalFileURL(for: track) {
                self.finish(trackKey: trackKey, metadata: nil, url: cachedURL, error: nil)
                return
            }
            if isBulk && !self.bulkActive {
                self.finish(trackKey: trackKey, metadata: nil, url: nil, error: "Отменено")
                return
            }
            self.invalidateCachedFile(for: track)
            self.enqueue(track, isBulk: isBulk)
        }
    }

    private func enqueue(_ track: Track, isBulk: Bool) {
        let trackKey = key(track)
        let request: URLRequest
        switch makeRequest(for: track) {
        case .success(let built): request = built
        case .failure(let failure):
            finish(trackKey: trackKey, metadata: nil, url: nil, error: failure.message)
            return
        }
        let metadata = BackgroundTransferMetadata(key: trackKey, track: track, isBulk: isBulk)
        guard let description = metadata.taskDescription else {
            finish(trackKey: trackKey, metadata: nil, url: nil, error: "Не удалось создать задачу загрузки")
            return
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        tasks[trackKey] = DownloadTaskInfo(
            state: "downloading", progress: 0, fileName: nil, error: nil, isActive: true
        )
        task.resume()
    }

    private func makeRequest(for track: Track) -> Result<URLRequest, RequestBuildFailure> {
        guard let base = AppSettings.shared.daemonBaseURL else {
            return .failure(RequestBuildFailure(message: "Сервер не настроен"))
        }
        guard var components = URLComponents(
            url: base.appendingPathComponent("api/download-file"),
            resolvingAgainstBaseURL: false
        ) else {
            return .failure(RequestBuildFailure(message: "Некорректный адрес сервера"))
        }
        components.queryItems = [
            URLQueryItem(name: "source", value: track.source),
            URLQueryItem(name: "track_id", value: track.id),
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "artist", value: track.artist)
        ]
        guard let url = components.url else {
            return .failure(RequestBuildFailure(message: "Не удалось собрать адрес загрузки"))
        }
        var request = AppSettings.shared.request(url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6 * 60 * 60
        return .success(request)
    }

    /// URLSession background downloads first write to a system-managed temp file.
    /// When iOS reports an I/O failure creating that file, retry as a data task and
    /// install the response directly into the app's own Downloads directory.
    private func retryWithoutTemporaryFile(_ metadata: BackgroundTransferMetadata, reason: String) {
        let trackKey = metadata.key
        guard fallbackTasks[trackKey] == nil else { return }
        let request: URLRequest
        switch makeRequest(for: metadata.track) {
        case .success(let built): request = built
        case .failure(let failure):
            finish(trackKey: trackKey, metadata: metadata, url: nil, error: failure.message)
            return
        }

        tasks[trackKey] = DownloadTaskInfo(
            state: "saving", progress: 0, fileName: nil, error: nil, isActive: true
        )
        let backgroundID = UIApplication.shared.beginBackgroundTask(
            withName: "Larpi audio fallback \(trackKey)"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fallbackTasks[trackKey]?.cancel()
                self.finish(
                    trackKey: trackKey, metadata: metadata, url: nil,
                    error: "iOS прервала сохранение аудио в фоне. Исходная ошибка: \(reason)"
                )
                self.endBackgroundTask(for: trackKey)
            }
        }
        backgroundTaskIDs[trackKey] = backgroundID
        let downloadDirectory = downloadsDirectory

        let task = fallbackSession.dataTask(with: request) { [weak self] data, response, error in
            var savedURL: URL?
            var failure: String?
            if let error {
                let nsError = error as NSError
                failure = "Повтор после \(reason) не удался: \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]; \(DownloadedFileInstaller.freeSpaceDescription(at: downloadDirectory))"
            } else if let response = response as? HTTPURLResponse, response.statusCode != 200 && response.statusCode != 206 {
                failure = "Демон ответил HTTP \(response.statusCode) при повторной загрузке"
            } else if !(response is HTTPURLResponse) {
                failure = "Повторный ответ демона не содержит HTTP статуса"
            } else if let data, data.count >= 1_024 {
                do {
                    savedURL = try DownloadedFileInstaller.save(data, key: trackKey, in: downloadDirectory)
                } catch {
                    let nsError = error as NSError
                    failure = "Не удалось записать аудио в Larpi: \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]; \(DownloadedFileInstaller.freeSpaceDescription(at: downloadDirectory))"
                }
            } else {
                failure = "Повторный ответ демона пустой или слишком маленький"
            }

            let completedURL = savedURL
            let completedFailure = failure
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fallbackTasks.removeValue(forKey: trackKey)
                self.endBackgroundTask(for: trackKey)
                if let completedURL {
                    self.transferFinished(metadata, at: completedURL)
                } else {
                    self.finish(trackKey: trackKey, metadata: metadata, url: nil, error: completedFailure)
                }
            }
        }
        fallbackTasks[trackKey] = task
        task.resume()
    }

    private func endBackgroundTask(for trackKey: String) {
        guard let identifier = backgroundTaskIDs.removeValue(forKey: trackKey),
              identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func transferProgress(_ metadata: BackgroundTransferMetadata, progress: Double) {
        let trackKey = metadata.key
        if tasks[trackKey] == nil {
            tasks[trackKey] = DownloadTaskInfo(
                state: "downloading", progress: progress, fileName: nil, error: nil, isActive: true
            )
        } else {
            tasks[trackKey]?.state = "downloading"
            tasks[trackKey]?.progress = progress
            tasks[trackKey]?.isActive = true
        }
    }

    private func transferFinished(_ metadata: BackgroundTransferMetadata, at url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let duration = await AudioFile.durationMs(of: url) else {
                self.invalidateCachedFile(for: metadata.track)
                self.finish(
                    trackKey: metadata.key, metadata: metadata, url: nil,
                    error: "Демон передал файл, но iPhone не распознал аудио"
                )
                return
            }
            self.setDuration(duration, forKey: metadata.key)
            self.finish(trackKey: metadata.key, metadata: metadata, url: url, error: nil)
        }
    }

    private func transferFailed(_ metadata: BackgroundTransferMetadata, message: String) {
        finish(trackKey: metadata.key, metadata: metadata, url: nil, error: message)
    }

    private func finish(
        trackKey: String,
        metadata: BackgroundTransferMetadata?,
        url: URL?,
        error: String?
    ) {
        guard tasks[trackKey]?.isActive == true || waiters[trackKey] != nil || metadata != nil else { return }
        if let url {
            tasks[trackKey] = DownloadTaskInfo(
                state: "done", progress: 100,
                fileName: url.lastPathComponent, error: nil, isActive: false
            )
        } else {
            tasks[trackKey] = DownloadTaskInfo(
                state: "error", progress: 0, fileName: nil,
                error: error ?? "Не удалось скачать файл", isActive: false
            )
        }

        let trackWaiters = waiters.removeValue(forKey: trackKey) ?? []
        let bulkResults = trackWaiters.filter(\.countsTowardBulk).count
            + (trackWaiters.isEmpty && metadata?.isBulk == true ? 1 : 0)
        for waiter in trackWaiters { waiter.onComplete?(url) }
        for _ in 0..<bulkResults { recordBulkResult(success: url != nil) }
    }

    private func restoreTransfers(_ restored: [RestoredBackgroundTransfer]) {
        var hasBulkTransfers = false
        for transfer in restored {
            let metadata = transfer.metadata
            hasBulkTransfers = hasBulkTransfers || metadata.isBulk
            tasks[metadata.key] = DownloadTaskInfo(
                state: transfer.isRunning ? "downloading" : "queued",
                progress: transfer.progress, fileName: nil, error: nil, isActive: true
            )
        }
        if hasBulkTransfers {
            bulkActive = true
        } else if bulkActive {
            bulkActive = false
            bulk = nil
            persistBulk()
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        backgroundEventsCompletionHandler = completionHandler
    }

    private func finishBackgroundEvents() {
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        handler?()
    }

    func downloadAll(_ tracks: [Track]) {
        guard !bulkActive else { return }
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert(key($0)).inserted }
        guard !unique.isEmpty else { return }
        bulk = BulkDownload(total: unique.count, done: 0, failed: 0)
        bulkActive = true
        bulkKeys = Set(unique.map { key($0) })
        persistBulk()
        for track in unique {
            requestDownload(track, force: false, isBulk: true, onComplete: nil)
        }
    }

    func cancelBulk() {
        let keysToCancel = bulkKeys
        bulkActive = false
        bulk = nil
        bulkKeys.removeAll()
        persistBulk()
        for key in keysToCancel { fallbackTasks[key]?.cancel() }
        session.getAllTasks { sessionTasks in
            let tasksToCancel = sessionTasks.filter { task in
                guard let metadata = BackgroundTransferMetadata.decode(task.taskDescription) else { return false }
                return metadata.isBulk || keysToCancel.contains(metadata.key)
            }
            tasksToCancel.forEach { $0.cancel() }
        }
    }

    private func recordBulkResult(success: Bool) {
        guard var current = bulk else { return }
        if success { current.done += 1 } else { current.failed += 1 }
        bulk = current
        bulkActive = current.done + current.failed < current.total
        if !bulkActive { bulkKeys.removeAll() }
        persistBulk()
    }

    private func persistBulk() {
        if let bulk, let data = try? JSONEncoder().encode(bulk) {
            UserDefaults.standard.set(data, forKey: Self.bulkStateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bulkStateKey)
        }
    }
}
