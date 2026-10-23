use crate::config::Config;
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// Точные метаданные (крупная обложка) из `ytmeta.py` —
/// того же скрипта, что в Raskulchik/larp-music-player.
#[derive(Debug, Clone, Default)]
pub struct YtMeta {
    pub artwork_url: Option<String>,
}

#[derive(Deserialize)]
struct MetaJson {
    #[serde(default)]
    ok: bool,
    #[serde(default)]
    artwork_url: Option<String>,
}

/// Ищем скрипт рядом с бинарником, в конфигах и в репозитории larp-music-player.
fn script_path() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(p) = std::env::var("LARP_YTMETA") {
        candidates.push(PathBuf::from(p));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("ytmeta.py"));
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        candidates.push(PathBuf::from(&home).join(".config/larp-daemon/ytmeta.py"));
        candidates.push(PathBuf::from(&home).join(".config/music-player-tui/ytmeta.py"));
        candidates.push(PathBuf::from(&home).join("music-player-tui/ytmeta.py"));
    }
    candidates.push(PathBuf::from("/usr/share/larp-music-player/ytmeta.py"));
    // Для запуска из исходников (в собранном пакете пути может не быть — не страшно).
    candidates.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("ytmeta.py"));

    candidates.into_iter().find(|p| p.exists())
}

/// Python с ytmusicapi: сначала venv рядом со скриптом/в larp-music-player, потом системный.
fn python_for(script: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("LARP_PYTHON") {
        let p = PathBuf::from(p);
        if p.exists() {
            return p;
        }
    }
    if let Some(dir) = script.parent() {
        let p = dir.join(".venv/bin/python");
        if p.exists() {
            return p;
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        for rel in [
            ".config/larp-daemon/.venv/bin/python",
            "music-player-tui/.venv/bin/python",
        ] {
            let p = PathBuf::from(&home).join(rel);
            if p.exists() {
                return p;
            }
        }
    }
    PathBuf::from("python3")
}

/// Запросить метаданные у ytmeta.py. `source` — yandex | soundcloud | ytmusic | itunes.
/// Ошибки/таймауты не фатальны: возвращаем None, вызывающий код использует запасной вариант.
pub async fn get_meta(source: &str, id: &str, conf: &Config) -> Option<YtMeta> {
    let src = match source {
        "ytmusic" | "soundcloud" | "yandex" | "itunes" => source.to_string(),
        _ => return None,
    };
    if id.is_empty() {
        return None;
    }
    let script = script_path()?;
    let python = python_for(&script);

    let extra = match src.as_str() {
        "yandex" if !conf.yandex_token.is_empty() => Some(conf.yandex_token.clone()),
        "soundcloud" => larp_core::api::get_sc_client_id().await.ok(),
        _ => None,
    };

    let id = id.to_string();
    let task = tokio::task::spawn_blocking(move || {
        let mut cmd = Command::new(&python);
        cmd.arg(&script).arg(&src).arg(&id);
        if let Some(e) = extra.as_deref() {
            cmd.arg(e);
        }
        let out = cmd.output().ok()?;
        if !out.status.success() {
            return None;
        }
        let v: MetaJson = serde_json::from_slice(&out.stdout).ok()?;
        if !v.ok {
            return None;
        }
        Some(YtMeta {
            artwork_url: v.artwork_url.filter(|u| !u.is_empty()),
        })
    });

    match tokio::time::timeout(Duration::from_secs(35), task).await {
        Ok(Ok(meta)) => meta,
        _ => None,
    }
}

/// Скачать картинку (обложку) по URL. Возвращает (content-type, байты).
pub async fn fetch_image(url: &str) -> Option<(String, Vec<u8>)> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return None;
    }
    let resp = reqwest::Client::new()
        .get(url)
        .header(
            reqwest::header::USER_AGENT,
            concat!("larp-daemon/", env!("CARGO_PKG_VERSION")),
        )
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();
    let bytes = resp.bytes().await.ok()?.to_vec();
    if bytes.is_empty() {
        return None;
    }
    Some((content_type, bytes))
}

/// Вшить обложку в mp3 (ID3 APIC), сохранив остальные теги. Заменяет переднюю обложку.
pub fn embed_cover(path: &Path, image: &[u8]) -> anyhow::Result<()> {
    use id3::frame::{Picture, PictureType};
    use id3::{Tag, TagLike, Version};

    let mut tag = Tag::read_from_path(path).unwrap_or_default();
    tag.remove_picture_by_type(PictureType::CoverFront);
    tag.add_frame(Picture {
        mime_type: mime_of(image).to_string(),
        picture_type: PictureType::CoverFront,
        description: String::new(),
        data: image.to_vec(),
    });
    tag.write_to_path(path, Version::Id3v24)?;
    Ok(())
}

fn mime_of(data: &[u8]) -> &'static str {
    if data.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if data.len() > 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        "image/webp"
    } else {
        "image/jpeg"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use id3::TagLike;

    #[test]
    fn embed_cover_keeps_existing_tags() {
        use id3::frame::PictureType;

        let dir = std::env::temp_dir().join(format!("larp-cover-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("track.mp3");
        std::fs::write(&path, [0xFF, 0xFB, 0x90, 0x00]).unwrap();

        let mut tag = id3::Tag::new();
        tag.set_title("Original title");
        tag.set_artist("Original artist");
        tag.write_to_path(&path, id3::Version::Id3v24).unwrap();

        let jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
        embed_cover(&path, &jpeg).unwrap();

        let tag = id3::Tag::read_from_path(&path).unwrap();
        assert_eq!(tag.title(), Some("Original title"));
        assert_eq!(tag.artist(), Some("Original artist"));
        let pic = tag.pictures().next().expect("cover");
        assert_eq!(pic.picture_type, PictureType::CoverFront);
        assert_eq!(pic.mime_type, "image/jpeg");
        assert_eq!(pic.data, jpeg);

        std::fs::remove_dir_all(&dir).ok();
    }
}
