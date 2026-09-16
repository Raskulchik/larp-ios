import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var healthText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("IP компьютера с larp-daemon (например 192.168.1.10). Демон работает только в локальной сети, туннель не нужен.")) {
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

                Section(footer: Text("Если включено, телефон передаёт проигрывание демону, а демон показывает «Слушаю …» в Discord (Rich Presence, процесс Discord должен быть запущен на компьютере).")) {
                    Toggle("Discord RPC", isOn: $settings.discordRPCEnabled)
                }

                Section(footer: Text("При открытии вкладки «Библиотека» недостающие треки автоматически скачиваются на телефон (через демон, файлы из ~/.cache/music-player-tui/downloads при этом не дублируются).")) {
                    Toggle("Автоскачивание Библиотеки", isOn: $settings.autoDownloadLibrary)
                }

                Section {
                    Button("Очистить кэш обложек") { ArtworkCache.clear() }
                } footer: {
                    Text("Удаляет сохранённые на телефоне обложки (Documents/ArtworkCache). Сами mp3 не трогаются.")
                }

                Section(footer: Text("Yandex-токен живёт на компьютере в ~/.config/music-player-tui/config.json — телефону он не нужен. Лайки и плейлисты хранятся в общей с music-player-tui базе (~/.config/music-player-tui/liked.db).")) {
                    Text("Поиск, скачивание и библиотека идут через демон по локальной сети.")
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