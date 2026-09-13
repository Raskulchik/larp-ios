import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let hostKey = "daemonHost"
    private static let portKey = "daemonPort"
    private static let tokenKey = "yandexToken"

    @Published var daemonHost: String {
        didSet { UserDefaults.standard.set(daemonHost, forKey: Self.hostKey) }
    }
    @Published var daemonPort: String {
        didSet { UserDefaults.standard.set(daemonPort, forKey: Self.portKey) }
    }
    @Published var yandexToken: String {
        didSet { UserDefaults.standard.set(yandexToken, forKey: Self.tokenKey) }
    }

    init() {
        let ud = UserDefaults.standard
        daemonHost = ud.string(forKey: Self.hostKey) ?? ""
        daemonPort = ud.string(forKey: Self.portKey) ?? "47110"
        yandexToken = ud.string(forKey: Self.tokenKey) ?? ""
    }

    var daemonBaseURL: URL? {
        var host = daemonHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        let port = Int(daemonPort.trimmingCharacters(in: .whitespaces)) ?? 47110
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        return comps.url
    }
}