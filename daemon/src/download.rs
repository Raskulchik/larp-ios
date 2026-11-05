use crate::jobs::{AppState, Job, file_name_for};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

/// Add old daemon downloads to music-player-tui's library with hard links.
/// The audio blocks remain shared, and the legacy daemon paths are preserved.
pub fn share_legacy_downloads(conf: &crate::config::Config) -> (usize, usize) {
    use id3::TagLike;
    use std::os::unix::fs::MetadataExt;

    let source_dir = conf.files_dir();
    let target_dir = &conf.tui_downloads_dir;
    let Ok(entries) = std::fs::read_dir(&source_dir) else {
        return (0, 0);
    };
    if std::fs::create_dir_all(target_dir).is_err() {
        return (0, 0);
    }

    let mut linked = 0;
    let mut skipped = 0;
    for entry in entries.flatten() {
        let source = entry.path();
        if source.extension().and_then(|ext| ext.to_str()) != Some("mp3")
            || !entry.file_type().map(|kind| kind.is_file()).unwrap_or(false)
        {
            continue;
        }
        let Ok(source_meta) = std::fs::metadata(&source) else {
            skipped += 1;
            continue;
        };
        if source_meta.len() == 0 {
            skipped += 1;
            continue;
        }

        let tags = id3::Tag::read_from_path(&source).ok();
        let title = tags.as_ref().and_then(|tag| tag.title()).unwrap_or_else(|| {
            source.file_stem().and_then(|s| s.to_str()).unwrap_or("Unknown track")
        });
        let artist = tags.as_ref().and_then(|tag| tag.artist()).unwrap_or("Unknown artist");
        let legacy_id = source.file_stem().and_then(|s| s.to_str()).unwrap_or("track");
        let existing_match = tui_download_match(target_dir, artist, title);
        if let Some(existing) = existing_match.as_ref() {
            let same_inode = std::fs::metadata(existing)
                .map(|m| m.dev() == source_meta.dev() && m.ino() == source_meta.ino())
                .unwrap_or(false);
            if same_inode {
                skipped += 1;
                continue;
            }
            if files_equal(&source, existing) {
                if replace_with_hard_link(&source, existing, legacy_id) {
                    linked += 1;
                } else {
                    skipped += 1;
                }
                continue;
            }
        }
        let sanitize = |s: &str| {
            s.chars()
                .map(|c| match c {
                    '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
                    _ => c,
                })
                .collect::<String>()
        };
        let stem = sanitize(&format!("{artist} - {title}"));
        let mut target = target_dir.join(format!("{stem}.mp3"));
        if existing_match.is_some() || target.exists() {
            let same_inode = std::fs::metadata(&target)
                .map(|m| m.dev() == source_meta.dev() && m.ino() == source_meta.ino())
                .unwrap_or(false);
            if same_inode {
                skipped += 1;
                continue;
            }
            target = target_dir.join(format!("{stem} [larp-{legacy_id}].mp3"));
        }
        if target.exists() {
            let same_inode = std::fs::metadata(&target)
                .map(|m| m.dev() == source_meta.dev() && m.ino() == source_meta.ino())
                .unwrap_or(false);
            if same_inode {
                skipped += 1;
                continue;
            }
            skipped += 1;
            continue;
        }
        match std::fs::hard_link(&source, &target) {
            Ok(()) => linked += 1,
            Err(_) => skipped += 1,
        }
    }
    (linked, skipped)
}

fn files_equal(a: &std::path::Path, b: &std::path::Path) -> bool {
    use std::io::Read;

    let Ok(ma) = std::fs::metadata(a) else { return false };
    let Ok(mb) = std::fs::metadata(b) else { return false };
    if ma.len() != mb.len() {
        return false;
    }
    let (Ok(mut fa), Ok(mut fb)) = (std::fs::File::open(a), std::fs::File::open(b)) else {
        return false;
    };
    let mut ba = [0u8; 64 * 1024];
    let mut bb = [0u8; 64 * 1024];
    loop {
        let (Ok(na), Ok(nb)) = (fa.read(&mut ba), fb.read(&mut bb)) else { return false };
        if na != nb || ba[..na] != bb[..nb] {
            return false;
        }
        if na == 0 {
            return true;
        }
    }
}

/// Atomically replace one legacy directory entry with a hard link to its
/// identical shared-library file; the track remains available at both paths.
fn replace_with_hard_link(
    legacy: &std::path::Path,
    shared: &std::path::Path,
    stable_id: &str,
) -> bool {
    let Some(parent) = legacy.parent() else { return false };
    let temp = parent.join(format!(".share-{stable_id}-{}.tmp", std::process::id()));
    if std::fs::hard_link(shared, &temp).is_err() {
        return false;
    }
    if std::fs::rename(&temp, legacy).is_err() {
        let _ = std::fs::remove_file(temp);
        return false;
    }
    true
}

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
    std::fs::create_dir_all(&conf.tui_downloads_dir)?;

    if let Some(path) = state.downloaded_track_path(&job.id)? {
        if path.is_file() {
            return mark_download_done(state, job, &path, "found in shared download database").await;
        }
        state.forget_downloaded_track(&job.id)?;
    }

    // Reuse the actual TUI download in place; no symlink or second audio copy.
    if let Some(path) = tui_download_match(&conf.tui_downloads_dir, &job.artist, &job.title) {
        return mark_download_done(state, job, &path, "found in music-player-tui downloads").await;
    }

    // Keep serving files made by older daemon versions until they are naturally
    // replaced. New downloads are written into the shared TUI library.
    let legacy_path = conf.files_dir().join(file_name_for(&job.id));

    // Уже скачано — просто отдаём ссылку.
    if legacy_path.is_file() && std::fs::metadata(&legacy_path)?.len() > 0 {
        return mark_download_done(state, job, &legacy_path, "found in legacy daemon downloads").await;
    }

    update(state, &job.id, |j| j.state = "running".into()).await;

    match job.source.as_str() {
        "yandex" => download_yandex(state, job).await,
        "ytmusic" => download_ytd(state, job, YtdKind::YoutubeMusic).await,
        "soundcloud" => download_ytd(state, job, YtdKind::SoundCloud).await,
        other => anyhow::bail!("unknown source: {other}"),
    }
}

async fn mark_download_done(
    state: &std::sync::Arc<AppState>,
    job: &Job,
    path: &std::path::Path,
    message: &str,
) -> anyhow::Result<()> {
    let size = std::fs::metadata(path)?.len();
    state.remember_downloaded_track(job, path, size)?;
    update(state, &job.id, |j| {
        j.state = "done".into();
        j.progress = 100.0;
        j.file_name = Some(file_name_for(&job.id));
        j.file_url = Some(format!("/files/{}", file_name_for(&job.id)));
        j.size_bytes = Some(size);
        j.message = message.to_string();
    })
    .await;
    Ok(())
}

fn shared_download_path(state: &AppState, job: &Job) -> std::path::PathBuf {
    let sanitize = |s: &str| {
        s.chars()
            .map(|c| match c {
                '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
                _ => c,
            })
            .collect::<String>()
    };
    let stem = sanitize(&format!("{} - {}", job.artist, job.title));
    let primary = state.conf.tui_downloads_dir.join(format!("{stem}.mp3"));
    if !primary.exists() || tui_download_match(&state.conf.tui_downloads_dir, &job.artist, &job.title).is_some() {
        return primary;
    }
    state
        .conf
        .tui_downloads_dir
        .join(format!("{stem} [larp-{}].mp3", job.id))
}

/// Обложку берём через ytmeta.py (крупную) и вшиваем в ID3 — она живёт в самом треке.
/// Если ytmeta недоступен, у yt-dlp-файлов остаётся обложка от `--embed-thumbnail`.
async fn attach_cover(state: &AppState, job: &Job, path: &std::path::Path) {
    let Some(meta) = crate::meta::get_meta(&job.source, &job.track_id, &state.conf).await else {
        return;
    };
    let Some(url) = meta.artwork_url else { return };
    let Some((_, bytes)) = crate::meta::fetch_image(&url).await else {
        return;
    };
    let path = path.to_path_buf();
    let _ = tokio::task::spawn_blocking(move || {
        if let Err(e) = crate::meta::embed_cover(&path, &bytes) {
            eprintln!("cover: embed failed: {e}");
        }
    })
    .await;
}

async fn download_yandex(state: &std::sync::Arc<AppState>, job: &Job) -> anyhow::Result<()> {
    let conf = &state.conf;
    let url = larp_core::api::get_yandex_download_url(&job.track_id, &conf.yandex_token).await?;
    if url.is_empty() {
        anyhow::bail!("empty yandex download url");
    }

    let final_path = shared_download_path(state, job);
    let tmp_path = conf.tui_downloads_dir.join(format!(".tmp-{}.mp3", job.id));

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

    attach_cover(state, job, &final_path).await;

    let size = std::fs::metadata(&final_path)?.len();
    mark_download_done(state, job, &final_path, &format!("{} bytes", size)).await
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

    let final_path = shared_download_path(state, job);
    let tmp_base = conf.tui_downloads_dir.join(format!(".tmp-{}", job.id));

    let mut cmd = Command::new(&conf.ytdlp);
    cmd.args(["--newline", "--no-playlist", "-x"])
        .args(["--audio-format", "mp3", "--audio-quality", "128K"])
        .args(["--convert-thumbnails", "jpg", "--embed-thumbnail"])
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

    // The output template above points into tui_downloads_dir, not the legacy
    // daemon files directory. Look beside the final shared-library destination.
    let produced = tmp_base.with_extension("mp3");
    let produced_size = std::fs::metadata(&produced)
        .map(|meta| meta.len())
        .unwrap_or(0);
    if produced_size == 0 {
        anyhow::bail!(
            "yt-dlp exited successfully but produced no MP3 at {}",
            produced.display()
        );
    }

    tokio::fs::rename(&produced, &final_path).await?;

    attach_cover(state, job, &final_path).await;

    let size = std::fs::metadata(&final_path)?.len();
    mark_download_done(state, job, &final_path, &format!("{} bytes", size)).await
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
