import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var healthText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("IP компьютера с larp-daemon (например 192.168.1.10) или домен туннеля (larp.example.com). HTTPS включи, если ходишь через Cloudflare Tunnel.")) {
                    TextField("Адрес демона", text: $settings.daemonHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    TextField("Порт", text: $settings.daemonPort)
                        .keyboardType(.numberPad)
                    Toggle("HTTPS (туннель)", isOn: $settings.useHTTPS)
                    SecureField("Токен доступа (auth_token)", text: $settings.authToken)
                        .autocorrectionDisabled()
                    Button("Проверить подключение") { checkHealth() }
                    if let healthText {
                        Text(healthText)
                            .font(.footnote)
                            .foregroundColor(healthText.contains("OK") ? .green : .red)
                    }
                }

                Section(footer: Text("Yandex-токен живёт на компьютере в ~/.config/larp-daemon/config.json — телефону он не нужен. VPN и туннель не нужны на домашнем Wi-Fi; через Cloudflare Tunnel работает и вне дома.")) {
                    Text("Поиск и скачивание идут через демон: дома по Wi-Fi, вне дома — через туннель.")
                }

                Section(footer: Text("Скачивание идёт через демон на компьютере: он сам качает (yt-dlp / прямые ссылки Yandex) и раздаёт mp3 по Wi-Fi.")) {
                    row(title: "Сервер", value: settings.daemonBaseURL?.absoluteString ?? "не настроен")
                    row(title: "Версия ядра", value: RustBridge.shared.version)
                }
            }
            .navigationTitle("Настройки")
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func checkHealth() {
        healthText = "…"
        guard let base = settings.daemonBaseURL else {
            healthText = "Укажи адрес демона"
            return
        }
        var req = settings.request(base.appendingPathComponent("health"))
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                if let error {
                    healthText = "Ошибка: \(error.localizedDescription)"
                } else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["ok"] as? Bool == true {
                    healthText = "OK — демон отвечает"
                } else {
                    healthText = "Ответ не распознан (\((resp as? HTTPURLResponse)?.statusCode ?? -1))"
                }
            }
        }.resume()
    }
}