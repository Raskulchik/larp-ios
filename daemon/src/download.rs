use crate::jobs::{AppState, Job, file_name_for};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

pub fn spawn_download(state: std::sync::Arc<AppState>, job: Job) {
    tokio::spawn(async move {
        if let Err(e) = run_download(&state, &job).await {
            eprintln!("job {} [{}] ERROR: {e:#}", job.id, job.source);
            let mut j = match state.get(&job.id).await {
                Some(j) => j,
                None => return,
            };
            j.state = "error".into();
            j.message = format!("{e:#}");
            j.updated_at = now();
            state.upsert(j).await;
            return;
        }
        if let Some(j) = state.get(&job.id).await {
            eprintln!(
                "job {} [{}] done: {} ({}B)",
                j.id,
                j.source,
                j.file_name.as_deref().unwrap_or("?"),
                j.size_bytes.unwrap_or(0)
            );
        }
    });
}

async fn update(state: &AppState, id: &str, f: impl FnOnce(&mut Job)) {
    if let Some(mut j) = state.get(id).await {
        f(&mut j);
        j.updated_at = now();
        state.upsert(j).await;
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

async fn run_download(state: &std::sync::Arc<AppState>, job: &Job) -> anyhow::Result<()> {
    let conf = &state.conf;
    std::fs::create_dir_all(conf.files_dir())?;
    let final_path = conf.files_dir().join(file_name_for(&job.id));

    // Уже скачано — просто отдаём ссылку.
    if final_path.exists() && std::fs::metadata(&final_path)?.len() > 0 {
        let size = std::fs::metadata(&final_path)?.len();
        update(state, &job.id, |j| {
            j.state = "done".into();
            j.progress = 100.0;
            j.file_name = Some(file_name_for(&job.id));
            j.file_url = Some(format!("/files/{}", file_name_for(&job.id)));
            j.size_bytes = Some(size);
            j.message = "already downloaded".into();
        }).await;
        return Ok(());
    }

    // Трек уже скачан TUI-плеером (файлы «Артист - Название.mp3» в tui_downloads_dir)?
    // Тогда не качаем заново — симлинк на файл с компа, phone тянет его по локальной сети.
    if !conf.tui_downloads_dir.as_os_str().is_empty() && conf.tui_downloads_dir.is_dir() {
        if let Some(src) = tui_download_match(&conf.tui_downloads_dir, &job.artist, &job.title) {
            std::os::unix::fs::symlink(&src, &final_path)?;
            let size = std::fs::metadata(&final_path)?.len();
            update(state, &job.id, |j| {
                j.state = "done".into();
                j.progress = 100.0;
                j.file_name = Some(file_name_for(&job.id));
                j.file_url = Some(format!("/files/{}", file_name_for(&job.id)));
                j.size_bytes = Some(size);
                j.message = "found in TUI downloads".into();
            }).await;
            return Ok(());
        }
    }

    update(state, &job.id, |j| j.state = "running".into()).await;

    match job.source.as_str() {
        "yandex" => download_yandex(state, job).await,
        "ytmusic" => download_ytd(state, job, YtdKind::YoutubeMusic).await,
        "soundcloud" => download_ytd(state, job, YtdKind::SoundCloud).await,
        other => anyhow::bail!("unknown source: {other}"),
    }
}

async fn download_yandex(state: &std::sync::Arc<AppState>, job: &Job) -> anyhow::Result<()> {
    let conf = &state.conf;
    let url = larp_core::api::get_yandex_download_url(&job.track_id, &conf.yandex_token).await?;
    if url.is_empty() {
        anyhow::bail!("empty yandex download url");
    }

    let final_path = conf.files_dir().join(file_name_for(&job.id));
    let tmp_path = conf.files_dir().join(format!(".tmp-{}", file_name_for(&job.id)));

    let client = reqwest::Client::new();
    let resp = client.get(&url).send().await?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("yandex download HTTP {status}");
    }

    let total = resp.content_length().unwrap_or(0);

    let mut stream = resp.bytes_stream();
    let mut file = tokio::fs::File::create(&tmp_path).await?;
    let mut written: u64 = 0;

    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        written += chunk.len() as u64;
        let pct = if total > 0 {
            (written as f32 / total as f32 * 100.0).min(100.0)
        } else {
            (written as f32 / 40_000_000.0 * 100.0).min(100.0)
        };
        update(state, &job.id, |j| {
            j.progress = pct;
            j.size_bytes = Some(written);
        }).await;
    }
    file.flush().await?;
    drop(file);

    tokio::fs::rename(&tmp_path, &final_path).await?;

    let size = std::fs::metadata(&final_path)?.len();
    update(state, &job.id, |j| {
        j.state = "done".into();
        j.progress = 100.0;
        j.file_name = Some(file_name_for(&job.id));
        j.file_url = Some(format!("/files/{}", file_name_for(&job.id)));
        j.size_bytes = Some(size);
        j.message = format!("{} bytes", size);
    }).await;

    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum YtdKind {
    YoutubeMusic,
    SoundCloud,
}

async fn download_ytd(state: &std::sync::Arc<AppState>, job: &Job, kind: YtdKind) -> anyhow::Result<()> {
    let conf = &state.conf;
    let url = match kind {
        YtdKind::YoutubeMusic => {
            format!("https://music.youtube.com/watch?v={}", job.track_id)
        }
        // yt-dlp качает SoundCloud только по ссылке вида soundcloud.com/user/track, а не по API.
        YtdKind::SoundCloud => larp_core::api::soundcloud_permalink(&job.track_id).await?,
    };

    let final_path = conf.files_dir().join(file_name_for(&job.id));
    let tmp_base = conf.files_dir().join(format!(".tmp-{}", job.id));

    let mut cmd = Command::new(&conf.ytdlp);
    cmd.args(["--newline", "--no-playlist", "-x"])
        .args(["--audio-format", "mp3", "--audio-quality", "128K"])
        .args(["-f", "bestaudio/best"])
        .args(["--force-overwrites", "--no-part"])
        .arg("-o")
        .arg(format!("{}.%(ext)s", tmp_base.display()))
        .arg(&url);

    if kind == YtdKind::YoutubeMusic {
        cmd.args(["--extractor-args", "youtube:player_client=mweb"]);
    }

    // YouTube Music / некоторые SoundCloud-треки отдают без кук только «Sign in to play» или 404.
    if !conf.ytdlp_cookies_browser.is_empty() {
        cmd.args(["--cookies-from-browser", &conf.ytdlp_cookies_browser]);
    } else if !conf.ytdlp_cookies.is_empty() {
        cmd.args(["--cookies", &conf.ytdlp_cookies]);
    }

    let mut child = cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    let stdout = child.stdout.take().expect("stdout");
    let stderr = child.stderr.take().expect("stderr");

    let state1 = state.clone();
    let id1 = job.id.clone();
    let _ = tokio::spawn(async move {
        let mut reader = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            if let Some(pct) = parse_ytdlp_progress(&line) {
                update(&state1, &id1, |j| {
                    j.progress = pct;
                    j.message = line.trim().to_string();
                }).await;
            }
        }
    });

    let state2 = state.clone();
    let id2 = job.id.clone();
    let _ = tokio::spawn(async move {
        let mut err = String::new();
        let mut reader = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            if line.starts_with("ERROR:") {
                err = line;
            }
        }
        if !err.is_empty() {
            update(&state2, &id2, |j| j.message = err).await;
        }
    });

    let status = child.wait().await?;
    if !status.success() {
        anyhow::bail!("yt-dlp failed: {}", state.get(&job.id).await.as_ref().and_then(|j| if !j.message.is_empty() { Some(j.message.clone()) } else { None }).unwrap_or_else(|| "unknown".into()));
    }

    // yt-dlp положил файл как .tmp-<id>.mp3
    let produced = conf.files_dir().join(format!(".tmp-{}.mp3", job.id));
    if !produced.exists() {
        anyhow::bail!("yt-dlp finished but no mp3 found (is ffmpeg installed?)");
    }

    tokio::fs::rename(&produced, &final_path).await?;

    let size = std::fs::metadata(&final_path)?.len();
    update(state, &job.id, |j| {
        j.state = "done".into();
        j.progress = 100.0;
        j.file_name = Some(file_name_for(&job.id));
        j.file_url = Some(format!("/files/{}", file_name_for(&job.id)));
        j.size_bytes = Some(size);
    }).await;

    Ok(())
}

fn parse_ytdlp_progress(line: &str) -> Option<f32> {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| regex::Regex::new(r"\[download\]\s+(\d+(?:\.\d+)?)%").expect("regex"));
    if let Some(cap) = re.captures(line) {
        return cap.get(1).and_then(|m| m.as_str().parse::<f32>().ok());
    }
    None
}

/// Находит в папке скачанного TUI-плеером файл вида «Артист - Название.mp3»,
/// совпадающий с запрошенным треком (нормализация: регистр и лишние пробелы).
pub fn tui_download_match(dir: &std::path::Path, artist: &str, title: &str) -> Option<std::path::PathBuf> {
    let norm = |s: &str| -> String {
        s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
    };
    let want_artist = norm(artist.trim());
    let want_title = norm(title.trim());
    if want_artist.is_empty() || want_title.is_empty() {
        return None;
    }

    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let lower = name.to_lowercase();
        if !lower.ends_with(".mp3") {
            continue;
        }
        let stem = &name[..name.len() - ".mp3".len()];
        let (file_artist, file_title) = match stem.split_once(" - ") {
            Some((a, t)) => (a, t),
            None => continue,
        };
        if norm(file_artist) == want_artist && norm(file_title) == want_title {
            return Some(entry.path());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tui_match_finds_file_ignoring_case_and_spaces() {
        let dir = std::env::temp_dir().join(format!("larp-tui-match-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("Battlejuice - Made Of Steel.mp3"), b"data").unwrap();
        std::fs::write(dir.join("Other - track.mp3"), b"x").unwrap();

        let found = tui_download_match(&dir, "battlejuice", "Made   of Steel").unwrap();
        assert_eq!(
            found.file_name().unwrap().to_string_lossy(),
            "Battlejuice - Made Of Steel.mp3"
        );
        assert!(tui_download_match(&dir, "Nobody", "Nothing").is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}