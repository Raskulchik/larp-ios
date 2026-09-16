import CryptoKit
import UIKit

/// Дисковый кэш обложек: `Documents/ArtworkCache/<sha256>.jpg`.
/// Позволяет показывать оффлайн и не перезапрашивать при каждом появлении строки.
enum ArtworkCache {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func fileURL(for artworkUrl: String) -> URL {
        let hex = SHA256.hash(data: Data(artworkUrl.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return dir.appendingPathComponent("\(hex).jpg")
    }

    static func cachedImage(for artworkUrl: String?) -> UIImage? {
        guard let artworkUrl, !artworkUrl.isEmpty else { return nil }
        let path = fileURL(for: artworkUrl).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return UIImage(contentsOfFile: path)
    }

    @discardableResult
    static func cache(_ image: UIImage, for artworkUrl: String?) -> Bool {
        guard let artworkUrl, !artworkUrl.isEmpty else { return false }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        return (try? data.write(to: fileURL(for: artworkUrl), options: .atomic)) != nil
    }

    /// Скачать и закэшировать обложку (best-effort).
    static func prefetch(_ artworkUrl: String?) async {
        guard let artworkUrl, !artworkUrl.isEmpty,
              cachedImage(for: artworkUrl) == nil,
              let proxy = AppSettings.shared.thumbURL(for: artworkUrl) else { return }
        let req = AppSettings.shared.request(proxy)
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let img = UIImage(data: data) {
            cache(img, for: artworkUrl)
        }
    }
}
