import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var healthText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("IP компьютера, на котором стоит larp-daemon (например 192.168.1.10). Телефон и комп — в одной сети.")) {
                    TextField("Адрес демона", text: $settings.daemonHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    TextField("Порт", text: $settings.daemonPort)
                        .keyboardType(.numberPad)
                    Button("Проверить подключение") { checkHealth() }
                    if let healthText {
                        Text(healthText)
                            .font(.footnote)
                            .foregroundColor(healthText.contains("OK") ? .green : .red)
                    }
                }

                Section(footer: Text("Нужен только для Yandex Music. Хранится локально на телефоне.")) {
                    SecureField("Yandex OAuth-токен", text: $settings.yandexToken)
                }

                Section(footer: Text("Скачивание идёт через демон на компьютере: он сам качает (yt-dlp / прямые ссылки Yandex) и раздаёт mp3 по Wi-Fi.")) {
                    LabeledContent("Сервер", value: settings.daemonBaseURL?.absoluteString ?? "не настроен")
                    LabeledContent("Версия ядра", value: RustBridge.shared.version)
                }
            }
            .navigationTitle("Настройки")
        }
    }

    private func checkHealth() {
        healthText = "…"
        guard let base = settings.daemonBaseURL else {
            healthText = "Укажи адрес демона"
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("health"))
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