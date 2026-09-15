# Larpi — порт музыкального плеера larp-music-player на iOS

Перенос механик TUI-плеера (`~/music-player-tui`) в iOS-приложение:

- Плейлисты, лайки, поиск: **Yandex Music**, **SoundCloud**, **YouTube Music**
- Лайки и плейлисты — в **общей базе** с TUI-плеером (`~/.config/music-player-tui/liked.db`), на телефоне видно то же, что и в music-player-tui
- Скачивание идёт **через домашний компьютер**: демон `larp-daemon` качает (yt-dlp / прямые ссылки Yandex) и раздаёт mp3 по Wi-Fi — телефон получает готовые файлы
- Демон работает **только в локальной сети** (http, без туннеля)
- Discord RPC убран полностью
- Плеер: системный **AVPlayer** (фоновая игра, Control Center, Now Playing)
- GUI: SwiftUI

Исходный проект `~/music-player-tui` не тронут.

## Состав

```
core/    Rust-ядро для iOS (поиск + лайки/плейлисты + FFI-слой C)
daemon/  Rust-сервер на Arch-боксе (HTTP API + Range-раздача mp3), автозапуск
ios/     SwiftUI-приложение (XcodeGen project.yml + исходники)
setup.sh        установка демона на Arch + автозапуск (systemd --user)
larp-daemon.service  юнит systemd
```

## 1. Демон на компьютере (Arch/GNOME)

Требуется: `rust`, `yt-dlp`, `ffmpeg`.

```bash
cd ~/larp-ios
./setup.sh
```

Что делает: соберёт `larp-daemon`, скопирует в `~/.local/bin`, подтянет Yandex-токен из
`~/.config/music-player-tui/config.json`, включит сервис `systemctl --user enable --now larp-daemon`.
Лайки и плейлисты демон читает/пишет прямо в базу TUI-плеера `~/.config/music-player-tui/liked.db`.

Проверка из браузера/curl:
```bash
curl http://localhost:47110/health
# {"ok":true,...}
```

Firewall при необходимости (см. вывод setup.sh): открыть TCP 47110.
Узнать IP для телефона: `hostname -I`.

Конфиг демона: `~/.config/larp-daemon/config.json`
(`yandex_token`, `port`, `db_path` — путь к общей базе, по умолчанию
`~/.config/music-player-tui/liked.db`).

Куки для yt-dlp (SoundCloud / YouTube Music):
- `ytdlp_cookies_browser` — браузер для `--cookies-from-browser`: `"firefox"` или
  путь к профилю типа `"firefox:/home/user/.config/mozilla/firefox/xxx.default-release"`
  (нужно, если профиль Firefox не лежит в `~/.mozilla`).
- `ytdlp_cookies` — путь к cookies.txt в формате Netscape (если `ytdlp_cookies_browser` пуст).

### API демона (кратко)
- `POST /api/download` `{"source":"ytmusic","track_id":"...","title":"...","artist":"..."}` → job
- `GET  /api/jobs`, `GET /api/jobs/:id` → статус скачивания
- `GET  /api/liked[?source=yandex]` → лайки из общей базы (фильтр по источнику)
- `POST /api/like` (трек JSON), `POST /api/unlike` `{"source","track_id"}`
- `GET  /api/yandex-likes` → реальные лайки аккаунта Яндекс Музыки (POST, кэш 5 мин, 400 если токен не настроен, 502 при ошибке API)
- `GET  /api/playlists`, `POST /api/playlists` `{"name"}`,
  `DELETE /api/playlists/:id`,
  `GET /api/playlists/:id/tracks`,
  `POST /api/playlists/:id/tracks` (трек JSON),
  `DELETE /api/playlists/:id/tracks` `{"source","track_id"}`
- `GET  /files/<md5>.mp3` → файл (Range/206 поддерживается — нужен для seek в AVPlayer)

## 2. Сборка iOS-приложения (нужен Mac c Xcode)

С этого Linux-бокса iOS не собрать — только с Mac.

```bash
# на Mac, в ~/larp-ios
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./ios/build-rust.sh          # соберёт larp-core для iOS → ios/libs/
xcodegen generate --spec ios/project.yml
open ios/LarpiOS.xcodeproj
```

В Xcode: выбрать свою команду (подпись или Free Account), открыть
`Signing & Capabilities` → выбрать Team, потом Run на симулятор или телефон.

- Симулятор использует `ios/libs/iphonesimulator/liblarp_core.a` (физический
  iPhone собирает iPod touch / `iphoneos`) — пути уже настроены в project.yml через
  `$(PLATFORM_NAME)`.
- Режим фоновой музыки включён в Info.plist (`UIBackgroundModes: audio`).
- Локальная сеть: при первом подключении iOS спросит разрешение (текст задан в project.yml).

## 3. Настройка на телефоне

Настройки → указать IP компьютера + порт (47110) → «Проверить подключение».
Только домашний Wi-Fi (локальная сеть, http без туннеля). Yandex-токен вводить
на телефоне не нужно — он живёт на компьютере (в `~/.config/music-player-tui/config.json`),
поиск идёт через демон, VPN на телефоне не нужен.

Лайки и плейлисты на телефоне — те же, что в TUI-плеере (общая база). В разделе
«Плейлисты» сверху есть плейлист **«Мне нравится»** — лайки из Яндекс Музыки.

## Как играет

- Трек из лайков/плейлиста: скачивается через демон → играет локальный файл (прогресс виден в строке трека).
- SoundCloud: сразу играет HLS-превью из поиска.
- Yandex/YT Music из поиска: задание на демон → качается на компьютер →
  передаётся на телефон → играет уже локальный файл (прогресс виден в строке трека).

## Проверки (можно с Linux)

```bash
cargo test                # 8 тестов: db/ffi core + range/имя-файла daemon
cd daemon && cargo run    # поднять демон локально, curl'ами гонять
```