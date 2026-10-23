import AVFoundation
import UIKit

/// Обложки живут внутри самих mp3 (ID3v2 APIC-фрейм), а не в отдельной папке.
/// Для ещё не скачанных треков — только кэш в памяти (диск не используется).
enum ArtworkStore {
    private static let memory = NSCache<NSString, UIImage>()

    // MARK: - Публичное API

    /// Обложка трека: у скачанного — из ID3-тега самого mp3, иначе из памяти/сети.
    @MainActor
    static func image(for track: Track?) async -> UIImage? {
        guard let track else { return nil }

        if let local = DownloadManager.shared.localFileURL(for: track) {
            let key = local.path as NSString
            if let cached = memory.object(forKey: key) { return cached }
            if let data = await embeddedArtworkData(from: local), let img = UIImage(data: data) {
                memory.setObject(img, forKey: key)
                return img
            }
            // Старые mp3 (скачаны до этой версии) — один раз вшиваем обложку и показываем.
            if let data = await fetchData(track.artworkUrl) {
                await embedInBackground(data, into: local)
                let img = UIImage(data: data)
                if let img { memory.setObject(img, forKey: key) }
                return img
            }
            return nil
        }

        guard let url = track.artworkUrl, !url.isEmpty else { return nil }
        if let cached = memory.object(forKey: url as NSString) { return cached }
        guard let data = await fetchData(url), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: url as NSString)
        return img
    }

    /// Вшить обложку в скачанный файл (вызывается после загрузки трека).
    @MainActor
    static func attachArtwork(from artworkUrl: String?, to fileURL: URL) async {
        // Демон уже мог вшить обложку сам — тогда не тратим запрос.
        if await embeddedArtworkData(from: fileURL) != nil { return }
        guard let data = await fetchData(artworkUrl) else { return }
        await embedInBackground(data, into: fileURL)
    }

    /// Удалить старую дисковую папку обложек из прошлых версий.
    @MainActor
    static func removeLegacyDiskCache() {
        let key = "artworkDiskCacheRemoved"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkCache", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Сеть (через прокси демона)

    @MainActor
    private static func fetchData(_ artworkUrl: String?) async -> Data? {
        guard let artworkUrl, !artworkUrl.isEmpty,
              let proxied = AppSettings.shared.thumbURL(for: artworkUrl) else { return nil }
        let req = AppSettings.shared.request(proxied)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return data.isEmpty ? nil : data
    }

    @MainActor
    private static func embedInBackground(_ imageData: Data, into fileURL: URL) async {
        _ = await Task.detached(priority: .utility) {
            try? embedArtwork(imageData, into: fileURL)
        }.value
    }

    // MARK: - Чтение обложки из mp3

    nonisolated static func embeddedArtworkData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = item.dataValue, !data.isEmpty { return data }
            if let value = item.value as? Data, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Запись ID3v2 APIC

    /// Добавить (или заменить) обложку в ID3-теге mp3, сохранив остальные фреймы.
    nonisolated static func embedArtwork(_ imageData: Data, into fileURL: URL) throws {
        guard !imageData.isEmpty else { return }
        let original = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard !original.isEmpty else { return }

        var version: UInt8 = 3          // 3 = ID3v2.3 (по умолчанию), 4 = ID3v2.4
        var audioStart = 0
        var keptFrames = Data()

        if original.count >= 10,
           original[0] == 0x49, original[1] == 0x44, original[2] == 0x33 { // "ID3"
            version = original[3]
            let flags = original[5]
            let tagSize = syncsafe(original, 6)
            let hasFooter = (flags & 0x10) != 0
            let tagEnd = 10 + tagSize + (hasFooter ? 10 : 0)
            audioStart = min(tagEnd, original.count)

            // Неизвестные/несовместимые версии и unsynchronisation не трогаем —
            // лучше оставить файл как есть, чем повредить тег.
            if version != 3 && version != 4 { return }
            if flags & 0x80 != 0 { return }

            var pos = 10
            let framesEnd = 10 + tagSize
            if flags & 0x40 != 0 { // extended header
                if version == 4 {
                    pos += max(syncsafe(original, pos), 6)
                } else {
                    pos += 4 + bigEndian(original, pos)
                }
            }
            while pos + 10 <= framesEnd {
                let idBytes = original[pos..<(pos + 4)]
                if idBytes.first == 0 { break }
                let id = String(bytes: idBytes, encoding: .isoLatin1) ?? ""
                let size = version == 4 ? syncsafe(original, pos + 4) : bigEndian(original, pos + 4)
                guard size > 0, pos + 10 + size <= framesEnd else { break }
                if id != "APIC" {
                    keptFrames.append(original[pos..<(pos + 10 + size)])
                }
                pos += 10 + size
            }
        }

        // APIC: кодировка 0 (ISO-8859-1), MIME, тип 3 (обложка), пустое описание, картинка.
        var body = Data([0x00])
        body.append(Data(mimeType(for: imageData).utf8))
        body.append(0x00)
        body.append(0x03)
        body.append(0x00)
        body.append(imageData)

        var frames = Data()
        frames.append(frame(id: "APIC", body: body, version: version))
        frames.append(keptFrames)

        var out = Data([0x49, 0x44, 0x33, version, 0x00, 0x00])
        out.append(syncsafeBytes(frames.count))
        out.append(frames)
        if audioStart < original.count {
            out.append(original[audioStart...])
        }
        try out.write(to: fileURL, options: .atomic)
    }

    // MARK: - ID3-утилиты

    private nonisolated static func frame(id: String, body: Data, version: UInt8) -> Data {
        var out = Data(id.utf8)
        out.append(version == 4 ? syncsafeBytes(body.count) : bigEndianBytes(body.count))
        out.append(contentsOf: [0x00, 0x00]) // flags
        out.append(body)
        return out
    }

    private nonisolated static func mimeType(for data: Data) -> String {
        if data.count >= 4, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return "image/png"
        }
        return "image/jpeg"
    }

    private nonisolated static func syncsafe(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset] & 0x7F) << 21)
            | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7)
            | Int(data[offset + 3] & 0x7F)
    }

    private nonisolated static func syncsafeBytes(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    private nonisolated static func bigEndian(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private nonisolated static func bigEndianBytes(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
