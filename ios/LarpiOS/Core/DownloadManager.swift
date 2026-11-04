import AVFoundation
import Foundation

private enum AudioFile {
    static func durationMs(of url: URL) async -> Int64? {
        let asset = AVURLAsset(url: url)
        guard let secs = try? await asset.load(.duration).seconds, secs > 0 else { return nil }
        return Int64((secs * 1000).rounded())
    }
}

/// Скачивает готовые файлы с домашнего демона фоновой URLSession.
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

    @Published var tasks: [String: DownloadTaskInfo] = [:]
    @Published private(set) var bulk: BulkDownload?
    @Published private(set) var bulkActive = false
    @Published private(set) var durations: [String: Int64] = [:]

    private let docsDir: URL
    private let backgroundSession: URLSession
    private let backgroundDelegate: BackgroundDownloadDelegate
    private var completionHandlers: [String: (URL?) -> Void] = [:]
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        docsDir = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: Self.durationsKey),
           let saved = try? JSONDecoder().decode([String: Int64].self, from: data) {
            durations = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.bulkStateKey),
           let saved = try? JSONDecoder().decode(BulkDownload.self, from: data) {
            bulk = saved
            bulkActive = saved.done + saved.failed < saved.total
        }

        let delegate = BackgroundDownloadDelegate()
        backgroundDelegate = delegate
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 6 * 60 * 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        backgroundSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        delegate.onProgress = { [weak self] metadata, progress in
            Task { @MainActor [weak self] in self?.transferProgress(metadata, progress: progress) }
        }
        delegate.onFinished = { [weak self] metadata, url in
            Task { @MainActor [weak self] in self?.transferFinished(metadata, at: url) }
        }
        delegate.onFailure = { [weak self] metadata, message in
            Task { @MainActor [weak self] in self?.transferFailed(metadata, message: message) }
        }
        delegate.onEventsFinished = { [weak self] in
            Task { @MainActor [weak self] in self?.finishBackgroundEvents() }
        }

        backgroundSession.getAllTasks { [weak self] sessionTasks in
            let restored = sessionTasks.compactMap { task -> RestoredBackgroundTransfer? in
                guard let metadata = BackgroundTransferMetadata.decode(task.taskDescription) else { return nil }
                let total = task.countOfBytesExpectedToReceive
                let progress = total > 0 ? min(100, Double(task.countOfBytesReceived) / Double(total) * 100) : 0
                return RestoredBackgroundTransfer(metadata: metadata, progress: progress, isRunning: task.state == .running)
            }
            Task { @MainActor [weak self] in self?.restoreTransfers(restored) }
        }
    }

    private func key(_ track: Track) -> String { track.searchKey.md5Hex }
    static func taskKey(for track: Track) -> String { track.searchKey.md5Hex }
    private func fileURL(name: String) -> URL { docsDir.appendingPathComponent(name) }
    func info(for track: Track) -> DownloadTaskInfo? { tasks[Self.taskKey(for: track)] }

    func localFileURL(for track: Track) -> URL? {
        let ext = track.source == "local" ? (track.localFileExtension ?? "mp3") : "mp3"
        let url = fileURL(name: "\(key(track)).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remoteStreamURL(for track: Track) -> URL? {
        guard let base = AppSettings.shared.daemonBaseURL else { return nil }
        return base.appendingPathComponent("files").appendingPathComponent("\(key(track)).mp3")
    }

    func durationMs(for track: Track) -> Int64? { durations[key(track)] ?? track.durationMs }

    func measureDurationIfMissing(url: URL, track: Track) async -> Int64? {
        let k = key(track)
        if let d = durations[k] { return d }
        if let ms = await AudioFile.durationMs(of: url), ms > 0 { setDuration(ms, forKey: k); return ms }
        return track.durationMs
    }

    func measureLocalDurations() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: docsDir.path)) ?? []
        let allowed: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf"]
        for name in files {
            let url = fileURL(name: name)
            let base = url.deletingPathExtension().lastPathComponent
            guard allowed.contains(url.pathExtension.lowercased()), durations[base] == nil else { continue }
            Task { [weak self] in
                guard let self, let ms = await AudioFile.durationMs(of: url), ms > 0 else { return }
                self.setDuration(ms, forKey: base)
            }
        }
    }

    private func setDuration(_ ms: Int64, forKey key: String) {
        durations[key] = ms
        if let data = try? JSONEncoder().encode(durations) { UserDefaults.standard.set(data, forKey: Self.durationsKey) }
    }

    func isDownloading(_ track: Track) -> Bool { tasks[key(track)]?.isActive == true }

    func download(_ track: Track, onComplete: @escaping (URL?) -> Void) {
        let k = key(track)
        if let local = localFileURL(for: track) { onComplete(local); return }
        if tasks[k]?.isActive == true { completionHandlers[k] = onComplete; return }
        enqueue(track, isBulk: false, onComplete: onComplete)
    }

    private func enqueue(_ track: Track, isBulk: Bool, onComplete: ((URL?) -> Void)? = nil) {
        let k = key(track)
        guard let base = AppSettings.shared.daemonBaseURL else {
            tasks[k] = DownloadTaskInfo(state: "error", progress: 0, fileName: nil, error: "Сервер не настроен", isActive: false)
            onComplete?(nil)
            if isBulk { recordBulkResult(success: false) }
            return
        }
        guard var components = URLComponents(url: base.appendingPathComponent("api/download-file"), resolvingAgainstBaseURL: false) else {
            tasks[k] = DownloadTaskInfo(state: "error", progress: 0, fileName: nil, error: "Некорректный адрес сервера", isActive: false)
            onComplete?(nil)
            if isBulk { recordBulkResult(success: false) }
            return
        }
        components.queryItems = [
            URLQueryItem(name: "source", value: track.source),
            URLQueryItem(name: "track_id", value: track.id),
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "artist", value: track.artist)
        ]
        guard let url = components.url else { onComplete?(nil); return }
        var request = AppSettings.shared.request(url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6 * 60 * 60
        let task = backgroundSession.downloadTask(with: request)
        task.taskDescription = BackgroundTransferMetadata(key: k, track: track, isBulk: isBulk).taskDescription
        completionHandlers[k] = onComplete
        tasks[k] = DownloadTaskInfo(state: "downloading", progress: 0, fileName: nil, error: nil, isActive: true)
        task.resume()
    }

    private func transferProgress(_ metadata: BackgroundTransferMetadata, progress: Double) {
        let k = metadata.key
        if tasks[k] == nil { tasks[k] = DownloadTaskInfo(state: "transferring", progress: progress, fileName: nil, error: nil, isActive: true) }
        tasks[k]?.state = "transferring"
        tasks[k]?.progress = progress
    }

    private func transferFinished(_ metadata: BackgroundTransferMetadata, at url: URL) {
        let k = metadata.key
        let name = "\(k).mp3"
        tasks[k] = DownloadTaskInfo(state: "done", progress: 100, fileName: name, error: nil, isActive: false)
        completionHandlers.removeValue(forKey: k)?(url)
        if metadata.isBulk { recordBulkResult(success: true) }
        Task { [weak self] in
            guard let self, let ms = await AudioFile.durationMs(of: url), ms > 0 else { return }
            self.setDuration(ms, forKey: k)
        }
    }

    private func transferFailed(_ metadata: BackgroundTransferMetadata, message: String) {
        let k = metadata.key
        tasks[k] = DownloadTaskInfo(state: "error", progress: 0, fileName: nil, error: message, isActive: false)
        completionHandlers.removeValue(forKey: k)?(nil)
        if metadata.isBulk { recordBulkResult(success: false) }
    }

    private func recordBulkResult(success: Bool) {
        guard var current = bulk else { return }
        if success { current.done += 1 } else { current.failed += 1 }
        bulk = current
        bulkActive = current.done + current.failed < current.total
        persistBulk()
    }

    private func persistBulk() {
        if let bulk, let data = try? JSONEncoder().encode(bulk) {
            UserDefaults.standard.set(data, forKey: Self.bulkStateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bulkStateKey)
        }
    }

    private func restoreTransfers(_ restored: [RestoredBackgroundTransfer]) {
        var hasBulkTasks = false
        for transfer in restored {
            let metadata = transfer.metadata
            hasBulkTasks = hasBulkTasks || metadata.isBulk
            tasks[metadata.key] = DownloadTaskInfo(
                state: transfer.isRunning ? "transferring" : "queued",
                progress: transfer.progress,
                fileName: nil,
                error: nil,
                isActive: true
            )
        }
        if hasBulkTasks { bulkActive = true }
        else if bulkActive { bulkActive = false; persistBulk() }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else { completionHandler(); return }
        backgroundEventsCompletionHandler = completionHandler
    }

    private func finishBackgroundEvents() {
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        handler?()
    }

    /// Ставит все новые треки на системную фоновую очередь загрузок.
    func downloadAll(_ tracks: [Track]) {
        guard !bulkActive else { return }
        var seen = Set<String>()
        let pending = tracks.filter { track in
            let k = key(track)
            return seen.insert(k).inserted && localFileURL(for: track) == nil && !isDownloading(track)
        }
        guard !pending.isEmpty else { bulk = nil; persistBulk(); return }
        bulk = BulkDownload(total: pending.count, done: 0, failed: 0)
        bulkActive = true
        persistBulk()
        for track in pending { enqueue(track, isBulk: true) }
    }

    func cancelBulk() {
        backgroundSession.getAllTasks { [weak self] sessionTasks in
            let bulkTasks = sessionTasks.filter {
                BackgroundTransferMetadata.decode($0.taskDescription)?.isBulk == true
            }
            bulkTasks.forEach { $0.cancel() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in bulkTasks {
                    guard let meta = BackgroundTransferMetadata.decode(task.taskDescription) else { continue }
                    self.tasks[meta.key] = DownloadTaskInfo(state: "error", progress: 0, fileName: nil, error: "Отменено", isActive: false)
                    self.completionHandlers.removeValue(forKey: meta.key)?(nil)
                }
                self.bulkActive = false
                self.bulk = nil
                self.persistBulk()
            }
        }
    }
}
