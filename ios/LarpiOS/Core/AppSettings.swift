import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let hostKey = "daemonHost"
    private static let portKey = "daemonPort"
    private static let discordRPCKey = "discordRPCEnabled"
    private static let autoDownloadKey = "autoDownloadLibrary"

    @Published var daemonHost: String {
        didSet { UserDefaults.standard.set(daemonHost, forKey: Self.hostKey) }
    }
    @Published var daemonPort: String {
        didSet { UserDefaults.standard.set(daemonPort, forKey: Self.portKey) }
    }
    /// Показывать «Слушаю …» в Discord через демон (флажок в Настройках).
    @Published var discordRPCEnabled: Bool {
        didSet {
            UserDefaults.standard.set(discordRPCEnabled, forKey: Self.discordRPCKey)
            PlayerEngine.shared.pushDiscordRPC()
        }
    }
    /// Автоматически скачивать недостающие треки Библиотеки на телефон.
    @Published var autoDownloadLibrary: Bool {
        didSet { UserDefaults.standard.set(autoDownloadLibrary, forKey: Self.autoDownloadKey) }
    }

    init() {
        let ud = UserDefaults.standard
        daemonHost = ud.string(forKey: Self.hostKey) ?? ""
        daemonPort = ud.string(forKey: Self.portKey) ?? "47110"
        discordRPCEnabled = ud.object(forKey: Self.discordRPCKey) as? Bool ?? true
        autoDownloadLibrary = ud.object(forKey: Self.autoDownloadKey) as? Bool ?? true
    }

    /// Демон ходит только по локальной сети (http, без туннеля).
    var daemonBaseURL: URL? {
        let host = daemonHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        let portText = daemonPort.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        if let port = Int(portText), port > 0 {
            comps.port = port
        }
        return comps.url
    }

    func request(_ url: URL) -> URLRequest {
        URLRequest(url: url)
    }

    /// URL прокси обложки через демон (телефон сам не достаёт ни sndcdn, ни googleusercontent).
    func thumbURL(for artworkUrl: String?) -> URL? {
        guard let artworkUrl, !artworkUrl.isEmpty, let base = daemonBaseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("api/thumb"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "url", value: artworkUrl)]
        return comps.url
    }
}