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
        duration = TimeInterval(track.durationMs ?? 0) / 1000.0

        if let local = DownloadManager.shared.localFileURL(for: track) {
            playItem(local, track: track)
            return
        }

        // SoundCloud отдаёт HLS-превью — AVPlayer играет m3u8 напрямую.
        if track.source == "soundcloud", let preview = track.previewUrl, let url = URL(string: preview) {
            playItem(url, track: track)
            return
        }

        // Остальные источники (yandex/ytmusic) — через домашний демон.
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
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = !isPlaying
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    private func itemFinished() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            player.play()
            isPlaying = true
        case .all:
            next()
        case .off:
            player.pause()
            isPlaying = false
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
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlayingInfo()
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
        guard let s = track.artworkUrl, let url = URL(string: s) else {
            artwork = nil
            return
        }
        artworkTask?.cancel()
        artworkTask = Task {
            if let data = try? await URLSession.shared.data(from: url).0,
               let img = UIImage(data: data) {
                await MainActor.run {
                    self.artwork = img
                    self.updateNowPlaying(track)
                }
            }
        }
    }
}