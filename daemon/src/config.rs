use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const DEFAULT_PORT: u16 = 47110;

fn home() -> PathBuf {
    std::env::var("HOME").unwrap_or_else(|_| ".".to_string()).into()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub listen: String,
    pub port: u16,
    pub yandex_token: String,
    pub download_dir: PathBuf,
    pub ytdlp: String,
    /// Путь к cookies.txt (формат Netscape) для yt-dlp (SoundCloud / YouTube Music).
    #[serde(default)]
    pub ytdlp_cookies: String,
    /// Браузер для --cookies-from-browser, например "firefox". Имеет приоритет над ytdlp_cookies.
    #[serde(default)]
    pub ytdlp_cookies_browser: String,
    pub auth_token: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            listen: "0.0.0.0".to_string(),
            port: DEFAULT_PORT,
            yandex_token: String::new(),
            download_dir: home().join(".local").join("share").join("larp-daemon"),
            ytdlp: "yt-dlp".to_string(),
            ytdlp_cookies: String::new(),
            ytdlp_cookies_browser: String::new(),
            auth_token: String::new(),
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