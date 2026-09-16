import AVFoundation
import Foundation
import UIKit

/// Реальная длительность mp3 через AVFoundation (не парсинг строк).
private enum AudioFile {
    static func durationMs(of url: URL) async -> Int64? {
        let asset = AVURLAsset(url: url)
        guard let secs = try? await asset.load(.duration).seconds, secs > 0 else { return nil }
        return Int64((secs * 1000).rounded())
    }
}

/// Управление скачиванием через домашний демон (larp-daemon).
/// Файл качается на Arch-боксе (yt-dlp / yandex), потом передаётся на телефон в Documents/Downloads.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    struct DownloadTaskInfo {
        var state: String // queued | downloading | transferring | done | error
        var progress: Double
        var fileName: String?
        var error: String?
        var isActive: Bool
    }

    /// Прогресс массового скачивания плейлиста.
    struct BulkDownload {
        var total: Int
        var done: Int
        var failed: Int
    }

    // JobStatus повторяет JSON демона (snake_case → camelCase).
    private struct JobStatus: Codable {
        let id: String
        let source: String
        let trackId: String
        let title: String
        let artist: String
        let state: String
        let progress: Double
        let message: String?
        let fileName: String?
        let fileUrl: String?
        let sizeBytes: Int64?
    }

    private struct JobResponse: Codable { let job: JobStatus }
    private struct DownloadResponse: Codable { let job: JobStatus }

    @Published var tasks: [String: DownloadTaskInfo] = [:]

    /// Массовое скачивание плейлиста целиком.
    @Published private(set) var bulk: BulkDownload?
    @Published private(set) var bulkActive = false
    private var bulkTask: Task<Void, Never>?

    /// Реальная длительность из аудиофайлов локально скачанных треков (ms),
    /// по ключу <md5 searchKey>. YT Music не всегда отдаёт длительность в поиске,
    /// поэтому берём её из самого mp3.
    @Published private(set) var durations: [String: Int64] = [:]
    private static let durationsKey = "larp.localDurationsMs"

    // Фоновое продление: iOS даёт процессу время после сворачивания,
    // пока идёт скачивание (периодически перезапрашиваем).
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var lastBgRearm = Date()

    private let docsDir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }()

    private var pollers: [String: Task<Void, Never>] = [:]

    private static let jobDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private init() {
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: Self.durationsKey),
           let dict = try? JSONDecoder().decode([String: Int64].self, from: data) {
            durations = dict
        }
    }

    private func key(_ track: Track) -> String { track.searchKey.md5Hex }
    static func taskKey(for track: Track) -> String { track.searchKey.md5Hex }
    private func fileURL(name: String) -> URL { docsDir.appendingPathComponent(name) }

    func info(for track: Track) -> DownloadTaskInfo? {
        tasks[Self.taskKey(for: track)]
    }

    func localFileURL(for track: Track) -> URL? {
        let name = "\(key(track)).mp3"
        let url = fileURL(name: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remoteStreamURL(for track: Track) -> URL? {
        guard let base = AppSettings.shared.daemonBaseURL else { return nil }
        return base.appendingPathComponent("files").appendingPathComponent("\(key(track)).mp3")
    }

    /// Длительность трека: из измеренного локального файла, иначе из метаданных трека.
    func durationMs(for track: Track) -> Int64? {
        durations[key(track)] ?? track.durationMs
    }

    /// Измерить длительность локального файла, если ещё не измеряли.
    func measureDurationIfMissing(url: URL, track: Track) async -> Int64? {
        let k = key(track)
        if let d = durations[k] { return d }
        if let ms = await AudioFile.durationMs(of: url), ms > 0 {
            setDuration(ms, forKey: k)
            return ms
        }
        return track.durationMs
    }

    /// Однократно измерить длительности всех уже скачанных mp3 (по имени файла = md5 ключ).
    func measureLocalDurations() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: docsDir.path)) ?? []
        for name in files where name.hasSuffix(".mp3") {
            let base = String(name.dropLast(4))
            guard durations[base] == nil else { continue }
            let url = fileURL(name: name)
            Task { [weak self] in
                guard let self else { return }
                if let ms = await AudioFile.durationMs(of: url), ms > 0 {
                    self.setDuration(ms, forKey: base)
                }
            }
        }
    }

    private func setDuration(_ ms: Int64, forKey k: String) {
        durations[k] = ms
        if let data = try? JSONEncoder().encode(durations) {
            UserDefaults.standard.set(data, forKey: Self.durationsKey)
        }
    }

    /// Уже скачивается/скачано?
    func isDownloading(_ track: Track) -> Bool {
        tasks[key(track)]?.isActive == true
    }

    /// Начать скачивание. onComplete вызовится с локальным URL при успехе.
    func download(_ track: Track, onComplete: @escaping (URL?) -> Void) {
        let k = key(track)

        if let local = localFileURL(for: track) {
            onComplete(local)
            return
        }
        if tasks[k]?.isActive == true {
            return
        }
        guard let base = AppSettings.shared.daemonBaseURL else {
            tasks[k] = DownloadTaskInfo(state: "error", progress: 0, fileName: nil, error: "Сервер не настроен", isActive: false)
            return
        }

        tasks[k] = DownloadTaskInfo(state: "queued", progress: 0, fileName: nil, error: nil, isActive: true)

        var req = AppSettings.shared.request(base.appendingPathComponent("api/download"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode([
            "source": track.source,
            "track_id": track.id,
            "title": track.title,
            "artist": track.artist
        ])

        let poller = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    self.complete(k, error: "демон ответил \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    return
                }
                let job = try Self.jobDecoder.decode(DownloadResponse.self, from: data).job
                await self.pollUntilDone(initial: job, key: k, track: track, onComplete: onComplete)
            } catch {
                self.complete(k, error: error.localizedDescription)
            }
            self.pollers[k] = nil
        }
        pollers[k] = poller
    }

    private func pollUntilDone(initial: JobStatus, key k: String, track: Track, onComplete: @escaping (URL?) -> Void) async {
        var job = initial
        if job.state == "done" {
            await transfer(initial, key: k, track: track, onComplete: onComplete)
            return
        }
        for _ in 0..<360 { // до ~6 минут
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let base = AppSettings.shared.daemonBaseURL else { break }
            do {
                let url = base.appendingPathComponent("api/jobs").appendingPathComponent(job.id)
                let (data, resp) = try await URLSession.shared.data(for: AppSettings.shared.request(url))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { break }
                job = try Self.jobDecoder.decode(JobResponse.self, from: data).job
            } catch { break }

            self.tasks[k]?.progress = job.progress
            self.tasks[k]?.state = "downloading"

            switch job.state {
            case "done":
                await transfer(job, key: k, track: track, onComplete: onComplete)
                return
            case "error":
                complete(k, error: job.message ?? "ошибка скачивания")
                return
            default:
                continue
            }
        }
        complete(k, error: "таймаут ожидания демона")
    }

    private func transfer(_ job: JobStatus, key k: String, track: Track, onComplete: @escaping (URL?) -> Void) async {
        guard let base = AppSettings.shared.daemonBaseURL else {
            complete(k, error: "сервер не настроен")
            return
        }
        let name = "\(k).mp3"
        tasks[k]?.state = "transferring"
        tasks[k]?.progress = 100

        do {
            let url = base.appendingPathComponent("files").appendingPathComponent(name)
            let (tmp, resp) = try await URLSession.shared.download(for: AppSettings.shared.request(url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                complete(k, error: "не удалось получить файл")
                return
            }
            let dest = fileURL(name: name)
            try FileManager.default.moveItem(at: tmp, to: dest)
            tasks[k] = DownloadTaskInfo(state: "done", progress: 100, fileName: name, error: nil, isActive: false)
            onComplete(FileManager.default.fileExists(atPath: dest.path) ? dest : nil)
            Task { await ArtworkCache.prefetch(track.artworkUrl) }
            Task { [weak self] in
                guard let self else { return }
                if let ms = await AudioFile.durationMs(of: dest), ms > 0 {
                    self.setDuration(ms, forKey: k)
                }
            }
        } catch {
            complete(k, error: error.localizedDescription)
        }
    }

    private func complete(_ k: String, error: String) {
        tasks[k] = DownloadTaskInfo(state: "error", progress: 0, fileName: nil, error: error, isActive: false)
    }

    // ============ массовое скачивание плейлиста ============

    /// Скачивает все треки списка локально на телефон (по 3 параллельно).
    /// Уже скачанные и качающиеся пропускаются. Повторный запуск пока идёт — игнорируется.
    func downloadAll(_ tracks: [Track]) {
        guard !bulkActive else { return }
        let pending = tracks.filter { localFileURL(for: $0) == nil && !isDownloading($0) }
        guard !pending.isEmpty else {
            bulk = nil
            return
        }
        bulkActive = true
        bulk = BulkDownload(total: pending.count, done: 0, failed: 0)
        rearmBackground()

        let concurrency = 3
        bulkTask?.cancel()
        bulkTask = Task { @MainActor in
            var index = 0
            while index < pending.count && !Task.isCancelled {
                let end = min(index + concurrency, pending.count)
                let slice = Array(pending[index..<end])
                index = end
                let keys = slice.map { key($0) }
                for track in slice {
                    download(track) { _ in }
                }
                await waitSignals(keys)
                for k in keys {
                    if let st = tasks[k], st.state == "done" {
                        bulk?.done += 1
                    } else {
                        bulk?.failed += 1
                    }
                }
            }
            bulkActive = false
            endBackground()
        }
    }

    func cancelBulk() {
        bulkTask?.cancel()
        bulkTask = nil
        bulkActive = false
        bulk = nil
        endBackground()
    }

    /// Ждёт, пока все ключи закончат скачивание (done/error).
    private func waitSignals(_ keys: [String]) async {
        while !keys.allSatisfy({ tasks[$0]?.state == "done" || tasks[$0]?.state == "error" }) {
            rearmBackground()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // ============ фоновый режим ============

    /// Попросить iOS не усыплять приложение, пока качаем (перезапрашиваем каждые ~20 с).
    private func rearmBackground() {
        guard bgTask == .invalid, Date().timeIntervalSince(lastBgRearm) > 20 else { return }
        lastBgRearm = Date()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "larp-bulk-download") { [weak self] in
            DispatchQueue.main.async {
                self?.bgTask = .invalid
            }
        }
    }

    private func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}