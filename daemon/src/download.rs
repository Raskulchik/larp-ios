use crate::jobs::{AppState, Job, file_name_for};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

pub fn spawn_download(state: std::sync::Arc<AppState>, job: Job) {
    tokio::spawn(async move {
        if let Err(e) = run_download(&state, &job).await {
            let mut j = match state.get(&job.id).await {
                Some(j) => j,
                None => return,
            };
            j.state = "error".into();
            j.message = format!("{e:#}");
            j.updated_at = now();
            state.upsert(j).await;
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

    update(state, &job.id, |j| j.state = "running".into()).await;

    match job.source.as_str() {
        "yandex" => download_yandex(state, job).await,
        "ytmusic" => download_ytd(state, job, true).await,
        "soundcloud" => download_ytd(state, job, false).await,
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

async fn download_ytd(state: &std::sync::Arc<AppState>, job: &Job, is_ytm: bool) -> anyhow::Result<()> {
    let conf = &state.conf;
    let url = if is_ytm {
        format!("https://music.youtube.com/watch?v={}", job.track_id)
    } else {
        format!("https://api.soundcloud.com/tracks/{}", job.track_id)
    };

    let final_path = conf.files_dir().join(file_name_for(&job.id));
    let tmp_base = conf.files_dir().join(format!(".tmp-{}", job.id));

    let mut cmd = Command::new(&conf.ytdlp);
    cmd.args(["--newline", "--no-playlist", "-x"])
        .args(["--audio-format", "mp3", "--audio-quality", "128K"])
        .args(["-f", "bestaudio"])
        .args(["--force-overwrites", "--no-part"])
        .arg("-o")
        .arg(format!("{}.%(ext)s", tmp_base.display()))
        .arg(&url);

    if is_ytm {
        cmd.args(["--extractor-args", "youtube:player_client=mweb"]);
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