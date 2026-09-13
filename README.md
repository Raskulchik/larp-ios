# Larpi — порт музыкального плеера larp-music-player на iOS

Перенос механик TUI-плеера (`~/music-player-tui`) в iOS-приложение:

- Плейлисты, лайки, поиск: **Yandex Music**, **SoundCloud**, **YouTube Music**
- Скачивание идёт **через домашний компьютер**: демон `larp-daemon` качает (yt-dlp / прямые ссылки Yandex) и раздаёт mp3 по Wi-Fi — телефон получает готовые файлы
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

Проверка из браузера/curl:
```bash
curl http://localhost:47110/health
# {"ok":true,...}
```

Firewall при необходимости (см. вывод setup.sh): открыть TCP 47110.
Узнать IP для телефона: `hostname -I`.

Конфиг демона: `~/.config/larp-daemon/config.json`
(`yandex_token`, `port`, `auth_token` — можно поставить токен для доступа к API демона).

### API демона (кратко)
- `POST /api/download` `{"source":"ytmusic","track_id":"...","title":"...","artist":"..."}` → job
- `GET  /api/jobs`, `GET /api/jobs/:id` → статус скачивания
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
Yandex-токен вводить на телефоне не нужно — он живёт на компьютере
(в `~/.config/larp-daemon/config.json`), поиск идёт через демон, VPN на телефоне не нужен.

## Как играет

- Трек: локальный mp3 из Documents → играет сразу.
- SoundCloud: сразу играет HLS-превью из поиска.
- Yandex/YT Music: отправляется задание на демон → качается на компьютер →
  передаётся на телефон → играет уже локальный файл (прогресс виден в строке трека).

## Проверки (можно с Linux)

```bash
cargo test                # 7 тестов: db/ffi core + range/имя-файла daemon
cd daemon && cargo run    # поднять демон локально, curl'ами гонять
```