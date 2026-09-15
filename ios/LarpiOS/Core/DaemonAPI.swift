import Foundation

struct DaemonAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// REST-клиент к larp-daemon: лайки и плейлисты живут в общей с music-player-tui
/// базе (~/.config/music-player-tui/liked.db) на компьютере, телефон ходит за ними
/// по локальной сети.
enum DaemonAPI {

    private static func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        query: [URLQueryItem] = []
    ) async throws -> [String: Any] {
        guard let base = AppSettings.shared.daemonBaseURL else {
            throw DaemonAPIError(message: "Сервер не настроен (IP в Настройках)")
        }
        var comps = URLComponents(url: base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query
        }
        guard let url = comps.url else { throw DaemonAPIError(message: "Некорректный адрес") }

        var req = AppSettings.shared.request(url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DaemonAPIError(message: "Нет ответа от демона")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DaemonAPIError(message: msg ?? "демон ответил \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else {
            throw DaemonAPIError(message: "Некорректный ответ демона")
        }
        return obj
    }

    private static func decodeArray<T: Decodable>(_ value: Any?) throws -> [T] {
        guard let arr = value as? [Any], !arr.isEmpty else { return [] }
        let data = try JSONSerialization.data(withJSONObject: arr)
        return try JSONDecoder().decode([T].self, from: data)
    }

    // ============ likes ============

    static func liked(source: String? = nil) async throws -> [Track] {
        var query: [URLQueryItem] = []
        if let source {
            query.append(URLQueryItem(name: "source", value: source))
        }
        let obj = try await request("api/liked", query: query)
        return try decodeArray(obj["liked"])
    }

    /// Лайки аккаунта Яндекс Музыки («Мне нравится») прямо из API Яндекса,
    /// минуя локальную базу: демон тянет их постранично и кэширует на 5 минут.
    static func yandexLikes() async throws -> [Track] {
        let obj = try await request("api/yandex-likes")
        return try decodeArray(obj["likes"])
    }

    static func like(_ track: Track) async throws {
        let body = try JSONEncoder().encode(track)
        _ = try await request("api/like", method: "POST", body: body)
    }

    static func unlike(source: String, trackId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["source": source, "track_id": trackId])
        _ = try await request("api/unlike", method: "POST", body: body)
    }

    // ============ playlists ============

    static func playlists() async throws -> [PlaylistInfo] {
        let obj = try await request("api/playlists")
        return try decodeArray(obj["playlists"])
    }

    @discardableResult
    static func createPlaylist(name: String) async throws -> Int64 {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let obj = try await request("api/playlists", method: "POST", body: body)
        return (obj["id"] as? NSNumber)?.int64Value ?? 0
    }

    static func deletePlaylist(id: Int64) async throws {
        _ = try await request("api/playlists/\(id)", method: "DELETE")
    }

    static func playlistTracks(id: Int64) async throws -> [Track] {
        let obj = try await request("api/playlists/\(id)/tracks")
        return try decodeArray(obj["tracks"])
    }

    static func addToPlaylist(id: Int64, track: Track) async throws {
        let body = try JSONEncoder().encode(track)
        _ = try await request("api/playlists/\(id)/tracks", method: "POST", body: body)
    }

    static func removeFromPlaylist(id: Int64, source: String, trackId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["source": source, "track_id": trackId])
        _ = try await request("api/playlists/\(id)/tracks", method: "DELETE", body: body)
    }
}