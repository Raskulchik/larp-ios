import Foundation

enum RustBridgeError: Error, LocalizedError {
    case nilResult
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .nilResult: return "Rust вернул nil"
        case .backend(let m): return m
        }
    }
}

struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let error: String?
}

/// Серийная очередь для блокирующих вызовов в Rust (SQLite не любит параллелизм).
final class BridgeQueue {
    static let shared = BridgeQueue()
    private let queue = OperationQueue()

    private init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    @discardableResult
    func run<T>(_ block: @escaping @Sendable () throws -> T,
                then: @escaping (Result<T, Error>) -> Void) -> Operation {
        let op = BlockOperation {
            let result: Result<T, Error>
            do { result = .success(try block()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { then(result) }
        }
        queue.addOperation(op)
        return op
    }
}

/// Тонкая обёртка над extern "C" функциями larp-core.
final class RustBridge {
    static let shared = RustBridge()
    private init() {}

    /// Результат обёрнут в {"ok": ..., "result": ..., "error": ...}.
    private func call<T: Decodable>(_ body: () -> UnsafeMutablePointer<CChar>?) throws -> T {
        guard let ptr = body() else { throw RustBridgeError.nilResult }
        defer { larp_free(ptr) }
        return try decode(String(cString: ptr))
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw RustBridgeError.nilResult }
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if !env.ok {
            throw RustBridgeError.backend(env.error ?? "unknown error")
        }
        guard let result = env.result ?? (T.self == EmptyResult.self ? EmptyResult() as? T : nil) else {
            throw RustBridgeError.backend("empty result")
        }
        return result
    }

    var version: String {
        guard let p = larp_version() else { return "?" }
        return String(cString: p)
    }

    // ============ search ============

    func search(_ source: SourceKind, query: String, yandexToken: String) throws -> [Track] {
        try call {
            query.withCString { cq in
                source.rawValue.withCString { cs in
                    yandexToken.withCString { ct in
                        larp_search(cs, cq, ct)
                    }
                }
            }
        }
    }

    // ============ db ============

    func dbOpen(directory: String) throws {
        let _: EmptyResult = try call {
            directory.withCString { larp_db_open($0) }
        }
    }

    func getLiked() throws -> [Track] {
        try call { larp_db_get_liked() }
    }

    func like(_ track: Track) throws {
        let json = try JSONEncoder().encode(track)
        let _: EmptyResult = try call {
            json.withUnsafeBytes { buf -> UnsafeMutablePointer<CChar>? in
                guard let base = buf.baseAddress else { return nil }
                return larp_db_like(base.assumingMemoryBound(to: CChar.self))
            }
        }
    }

    func unlike(source: String, trackId: String) throws {
        let _: EmptyResult = try call {
            source.withCString { cs in
                trackId.withCString { larp_db_unlike(cs, $0) }
            }
        }
    }

    func isLiked(source: String, trackId: String) throws -> Bool {
        try call {
            source.withCString { cs in
                trackId.withCString { larp_db_is_liked(cs, $0) }
            }
        }
    }

    // ============ playlists ============

    func createPlaylist(name: String) throws -> Int64 {
        let created: CreatedId = try call {
            name.withCString { larp_playlist_create($0) }
        }
        return created.id
    }

    func playlistList() throws -> [PlaylistInfo] {
        try call { larp_playlist_list() }
    }

    func playlistTracks(id: Int64) throws -> [Track] {
        try call { larp_playlist_tracks(id) }
    }

    func playlistAdd(id: Int64, track: Track) throws {
        let json = try JSONEncoder().encode(track)
        let _: EmptyResult = try call {
            json.withUnsafeBytes { buf -> UnsafeMutablePointer<CChar>? in
                guard let base = buf.baseAddress else { return nil }
                return larp_playlist_add(id, base.assumingMemoryBound(to: CChar.self))
            }
        }
    }

    func playlistRemove(id: Int64, source: String, trackId: String) throws {
        let _: EmptyResult = try call {
            source.withCString { cs in
                trackId.withCString { larp_playlist_remove(id, cs, $0) }
            }
        }
    }

    func playlistDelete(id: Int64) throws {
        let _: EmptyResult = try call { larp_playlist_delete(id) }
    }
}