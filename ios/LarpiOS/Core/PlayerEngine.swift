import AVFoundation
import MediaPlayer
import UIKit

/// Плеер на AVPlayer: локальные mp3 из Documents, HLS-превью SoundCloud, фоновая игра
/// с управлением из Control Center.
@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    enum RepeatMode { case off, all, one }

    @Published var queue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false

    var isShuffleOn: Bool { isShuffled }
    @Published var artwork: UIImage?

    var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?

    init() {
        configureAudioSession()
        configureRemoteCommands()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            DispatchQueue.main.async {
                self?.currentTime = seconds
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // ============ управление ============

    /// Начинает проигрывание очереди. Terем, что ещё не скачано, — ставит в очередь на скачивание.
    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = min(max(index, 0), tracks.count - 1)
        loadCurrent()
    }

    private func loadCurrent() {
        guard let track = currentTrack else { return }
        currentTime = 0
        duration = TimeInterval(DownloadManager.shared.durationMs(for: track) ?? 0) / 1000.0

        if let local = DownloadManager.shared.localFileURL(for: track) {
            playItem(local, track: track)
            if DownloadManager.shared.durationMs(for: track) == nil {
                Task { [weak self] in
                    guard let self,
                          let ms = await DownloadManager.shared.measureDurationIfMissing(url: local, track: track),
                          ms > 0 else { return }
                    self.duration = TimeInterval(ms) / 1000.0
                    self.updateNowPlaying(track)
                }
            }
            return
        }

        // Остальные источники (включая SoundCloud — его HLS-превью телефон без VPN не тянет) — через демон.
        DownloadManager.shared.download(track) { [weak self] localURL in
            Task { @MainActor in
                guard let self, let localURL else { return }
                self.playItem(localURL, track: track)
            }
        }
    }

    private func playItem(_ url: URL, track: Track) {
        let item = AVPlayerItem(url: url)
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.itemFinished() }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlaying(track)
        loadArtwork(track)
        pushDiscordRPC()
        ensureRPCHeartbeat()
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            rpcHeartbeat?.cancel()
            rpcHeartbeat = nil
        } else {
            player.play()
            ensureRPCHeartbeat()
        }
        isPlaying = !isPlaying
        updateNowPlayingInfo()
        pushDiscordRPC()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        pushDiscordRPC()
    }

    // ============ Discord Rich Presence ============

    /// Пока играет — фоном шлёт демону «я жив» каждые 15 с, чтобы демон
    /// не посчитал активность фантомной (просто трек длинный и тихий).
    private var rpcHeartbeat: Task<Void, Never>?

    private func ensureRPCHeartbeat() {
        if rpcHeartbeat != nil { return }
        guard AppSettings.shared.discordRPCEnabled else { return }
        rpcHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.isPlaying else { break }
                self.pushDiscordRPC()
            }
            self?.rpcHeartbeat = nil
        }
    }

    /// Отправить состояние проигрывания демону → Discord (если включено в Настройках).
    func pushDiscordRPC() {
        guard let base = AppSettings.shared.daemonBaseURL else { return }
        var body: [String: Any] = [
            "enabled": AppSettings.shared.discordRPCEnabled,
            "playing": isPlaying,
            "title": currentTrack?.title ?? "",
            "artist": currentTrack?.artist ?? ""
        ]
        if duration > 0 {
            body["duration_ms"] = Int64(duration * 1000)
        }
        if currentTime > 0 {
            body["position_ms"] = Int64(currentTime * 1000)
        }
        if let art = currentTrack?.artworkUrl {
            body["artwork_url"] = art
        }
        var req = AppSettings.shared.request(base.appendingPathComponent("api/rpc/state"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private func itemFinished() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            player.play()
            isPlaying = true
        case .all, .off:
            // .off: идём по очереди, останавливаемся только после последнего трека.
            next()
        }
    }

    func shuffle() {
        guard queue.count > 1 else { return }
        let anchor = currentTrack?.searchKey
        var rest = queue.filter { $0.searchKey != anchor }
        rest.shuffle()
        var newQueue = [Track]()
        if let anchor { newQueue.append(queue.first { $0.searchKey == anchor } ?? queue[0]) }
        newQueue.append(contentsOf: rest)
        queue = newQueue
        currentIndex = 0
        isShuffled = true
    }

    func next() {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            loadCurrent()
        } else if repeatMode == .all {
            currentIndex = 0
            loadCurrent()
        } else {
            player.pause()
            isPlaying = false
            rpcHeartbeat?.cancel()
            rpcHeartbeat = nil
            pushDiscordRPC()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            currentIndex -= 1
            loadCurrent()
        } else {
            player.pause()
            isPlaying = false
            rpcHeartbeat?.cancel()
            rpcHeartbeat = nil
            pushDiscordRPC()
        }
    }

    /// Перейти на трек в очереди (из списка очереди).
    func playAt(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent()
    }

    /// Удалить трек из очереди (свайп в списке очереди).
    func removeAt(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            player.pause()
            isPlaying = false
            pushDiscordRPC()
        }
    }

    // ============ Now Playing / Control Center ============

    private func updateNowPlaying(_ track: Track) {
        let mpic = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let img = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        mpic.nowPlayingInfo = info
    }

    private func updateNowPlayingInfo() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.play()
                self?.isPlaying = true
                self?.updateNowPlayingInfo()
                self?.ensureRPCHeartbeat()
                self?.pushDiscordRPC()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlayingInfo()
                self?.rpcHeartbeat?.cancel()
                self?.rpcHeartbeat = nil
                self?.pushDiscordRPC()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func loadArtwork(_ track: Track) {
        artworkTask?.cancel()
        if let cached = ArtworkCache.cachedImage(for: track.artworkUrl) {
            artwork = cached
            updateNowPlaying(track)
            return
        }
        guard let proxied = AppSettings.shared.thumbURL(for: track.artworkUrl) else {
            artwork = nil
            return
        }
        artworkTask = Task {
            let req = AppSettings.shared.request(proxied)
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let img = UIImage(data: data) {
                ArtworkCache.cache(img, for: track.artworkUrl)
                await MainActor.run {
                    self.artwork = img
                    self.updateNowPlaying(track)
                }
            }
        }
    }
}