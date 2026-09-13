import Foundation
import CryptoKit

// ========== Модели ==========

enum SourceKind: String, CaseIterable, Identifiable {
    case yandex
    case soundcloud
    case ytmusic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yandex: return "Yandex"
        case .soundcloud: return "SoundCloud"
        case .ytmusic: return "YT Music"
        }
    }
}

struct Track: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let source: String // yandex | soundcloud | ytmusic
    let previewUrl: String?
    let artworkUrl: String?
    let durationMs: Int64?

    var sourceLabel: String {
        SourceKind(rawValue: source)?.label ?? source
    }

    /// Ключ = id в локальной БД (совпадает с серверной логикой дедупликации файлов).
    var searchKey: String { "\(source):\(id)" }
}

struct PlaylistInfo: Codable, Identifiable, Equatable {
    let id: Int64
    let name: String
    let count: Int
}

struct CreatedId: Decodable {
    let id: Int64
}

struct EmptyResult: Decodable {}

// ========== Утилиты ==========

extension String {
    var md5Hex: String {
        Insecure.MD5.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func secondsText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}