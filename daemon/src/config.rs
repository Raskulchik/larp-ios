use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const DEFAULT_PORT: u16 = 47110;

/// Тот же Discord App ID, что и у music-player-tui (см. ~/music-player-tui/src/config.rs).
pub const DEFAULT_DISCORD_CLIENT_ID: &str = "1409612809859366932";

fn home() -> PathBuf {
    std::env::var("HOME").unwrap_or_else(|_| ".".to_string()).into()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub listen: String,
    pub port: u16,
    pub yandex_token: String,
    pub download_dir: PathBuf,
    /// Общая с TUI-плеером база лайков/плейлистов music-player-tui.
    #[serde(default)]
    pub db_path: PathBuf,
    /// Папка, куда TUI-плеер качает mp3 (файлы вида «Артист - Название.mp3»).
    /// Если трек там уже есть, демон не качает его заново, а отдаёт файл с диска компа.
    #[serde(default)]
    pub tui_downloads_dir: PathBuf,
    pub ytdlp: String,
    /// Путь к cookies.txt (формат Netscape) для yt-dlp (SoundCloud / YouTube Music).
    #[serde(default)]
    pub ytdlp_cookies: String,
    /// Браузер для --cookies-from-browser, например "firefox". Имеет приоритет над ytdlp_cookies.
    #[serde(default)]
    pub ytdlp_cookies_browser: String,
    /// Discord Application ID для Rich Presence (тот же, что в music-player-tui).
    #[serde(default)]
    pub discord_client_id: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            listen: "0.0.0.0".to_string(),
            port: DEFAULT_PORT,
            yandex_token: String::new(),
            download_dir: home().join(".local").join("share").join("larp-daemon"),
            db_path: home()
                .join(".config")
                .join("music-player-tui")
                .join("liked.db"),
            tui_downloads_dir: home()
                .join(".cache")
                .join("music-player-tui")
                .join("downloads"),
            ytdlp: "yt-dlp".to_string(),
            ytdlp_cookies: String::new(),
            ytdlp_cookies_browser: String::new(),
            discord_client_id: DEFAULT_DISCORD_CLIENT_ID.to_string(),
        }
    }
}

fn config_file() -> PathBuf {
    home()
        .join(".config")
        .join("larp-daemon")
        .join("config.json")
}

impl Config {
    pub fn load() -> anyhow::Result<Self> {
        let mut cfg: Config = match std::fs::read_to_string(config_file()) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Config::default(),
        };

        if let Ok(port) = std::env::var("LARP_PORT") {
            if let Ok(p) = port.parse() {
                cfg.port = p;
            }
        }
        if let Ok(token) = std::env::var("LARP_YANDEX_TOKEN") {
            if !token.is_empty() {
                cfg.yandex_token = token;
            }
        }
        if let Ok(dir) = std::env::var("LARP_DOWNLOAD_DIR") {
            if !dir.is_empty() {
                cfg.download_dir = dir.into();
            }
        }
        if let Ok(db) = std::env::var("LARP_DB_PATH") {
            if !db.is_empty() {
                cfg.db_path = db.into();
            }
        }
        if cfg.db_path.as_os_str().is_empty() {
            cfg.db_path = Config::default().db_path;
        }
        if let Ok(dir) = std::env::var("LARP_TUI_DOWNLOADS_DIR") {
            if !dir.is_empty() {
                cfg.tui_downloads_dir = dir.into();
            }
        }
        if cfg.tui_downloads_dir.as_os_str().is_empty() {
            cfg.tui_downloads_dir = Config::default().tui_downloads_dir;
        }
        if let Ok(cookies) = std::env::var("LARP_YTDLP_COOKIES") {
            if !cookies.is_empty() {
                cfg.ytdlp_cookies = cookies;
            }
        }
        if let Ok(browser) = std::env::var("LARP_YTDLP_COOKIES_BROWSER") {
            if !browser.is_empty() {
                cfg.ytdlp_cookies_browser = browser;
            }
        }

        Ok(cfg)
    }

    pub fn save(&self) -> anyhow::Result<()> {
        let path = config_file();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(self)?;
        std::fs::write(path, text)?;
        Ok(())
    }

    pub fn files_dir(&self) -> PathBuf {
        self.download_dir.join("files")
    }
}