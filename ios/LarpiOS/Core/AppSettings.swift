import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let hostKey = "daemonHost"
    private static let portKey = "daemonPort"
    private static let tokenKey = "yandexToken"
    private static let httpsKey = "daemonHTTPS"
    private static let authKey = "daemonAuthToken"

    @Published var daemonHost: String {
        didSet { UserDefaults.standard.set(daemonHost, forKey: Self.hostKey) }
    }
    @Published var daemonPort: String {
        didSet { UserDefaults.standard.set(daemonPort, forKey: Self.portKey) }
    }
    @Published var yandexToken: String {
        didSet { UserDefaults.standard.set(yandexToken, forKey: Self.tokenKey) }
    }
    @Published var useHTTPS: Bool {
        didSet { UserDefaults.standard.set(useHTTPS, forKey: Self.httpsKey) }
    }
    @Published var authToken: String {
        didSet { UserDefaults.standard.set(authToken, forKey: Self.authKey) }
    }

    init() {
        let ud = UserDefaults.standard
        daemonHost = ud.string(forKey: Self.hostKey) ?? ""
        daemonPort = ud.string(forKey: Self.portKey) ?? "47110"
        yandexToken = ud.string(forKey: Self.tokenKey) ?? ""
        useHTTPS = ud.bool(forKey: Self.httpsKey)
        authToken = ud.string(forKey: Self.authKey) ?? ""
    }

    var daemonBaseURL: URL? {
        let host = daemonHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        let portText = daemonPort.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents()
        comps.scheme = useHTTPS ? "https" : "http"
        comps.host = host
        if let port = Int(portText), port > 0 {
            comps.port = port
        }
        return comps.url
    }

    /// URLRequest с токеном доступа демона (x-larp-token), если включён auth_token.
    func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if !authToken.isEmpty {
            req.setValue(authToken, forHTTPHeaderField: "x-larp-token")
        }
        return req
    }

    /// URL прокси обложки через демон (телефон сам не достаёт ни sndcdn, ни googleusercontent).
    func thumbURL(for artworkUrl: String?) -> URL? {
        guard let artworkUrl, !artworkUrl.isEmpty, let base = daemonBaseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("api/thumb"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "url", value: artworkUrl)]
        return comps.url
    }
}