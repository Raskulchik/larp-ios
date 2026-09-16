mod config;
mod dbapi;
mod discord_rpc;
mod download;
mod jobs;
mod lyrics;

use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use jobs::{AppState, Job, job_id};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Instant;

#[derive(Debug, Deserialize)]
struct DownloadReq {
    source: String,
    track_id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    artist: String,
}

#[derive(Serialize)]
struct Health {
    ok: bool,
    version: &'static str,
    port: u16,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let conf = config::Config::load()?;

    // Первый запуск: сохранить дефолтный конфиг, чтобы его было видно.
    if !std::path::Path::new(&config_file_path()).exists() {
        let _ = conf.save();
    }

    std::fs::create_dir_all(conf.files_dir())?;

    // Общая с TUI-плеером база лайков/плейлистов.
    let db = larp_core::db::Database::open_at(&conf.db_path)
        .map_err(|e| anyhow::anyhow!("open shared db {}: {e}", conf.db_path.display()))?;
    println!("shared db: {}", conf.db_path.display());

    let state = AppState::new(conf.clone(), db);

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/download", post(create_job))
        .route("/api/search", get(search))
        .route("/api/lyrics", get(lyrics::lyrics))
        .route("/api/jobs", get(list_jobs))
        .route("/api/jobs/:id", get(get_job))
        .route("/files/:name", get(serve_file))
        .route("/api/thumb", get(thumb))
        .route("/api/liked", get(dbapi::get_liked))
        .route("/api/like", post(dbapi::like_track))
        .route("/api/unlike", post(dbapi::unlike_track))
        .route("/api/yandex-likes", get(dbapi::yandex_likes))
        .route("/api/rpc/state", post(rpc_state))
        .route(
            "/api/playlists",
            get(dbapi::list_playlists).post(dbapi::create_playlist),
        )
        .route("/api/playlists/:id", delete(dbapi::delete_playlist))
        .route(
            "/api/playlists/:id/tracks",
            get(dbapi::get_playlist_tracks)
                .post(dbapi::add_playlist_track)
                .delete(dbapi::remove_playlist_track),
        )
        .layer(middleware::from_fn(logging))
        .with_state(state);

    let addr = format!("{}:{}", conf.listen, conf.port);
    println!("larp-daemon v0.1.0 listening on http://{addr}");
    println!("download dir: {}", conf.files_dir().display());
    if !conf.yandex_token.is_empty() {
        println!("yandex token: configured");
    } else {
        println!("yandex token: NOT configured (so only soundcloud/ytmusic work)");
    }
    if !conf.ytdlp_cookies_browser.is_empty() {
        println!("yt-dlp cookies: from browser '{}'", conf.ytdlp_cookies_browser);
    } else if !conf.ytdlp_cookies.is_empty() {
        println!("yt-dlp cookies: from file {}", conf.ytdlp_cookies);
    } else {
        println!("yt-dlp cookies: NOT configured (YouTube Music / SoundCloud may need cookies from Firefox)");
    }

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

fn config_file_path() -> std::path::PathBuf {
    std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".to_string()))
        .join(".config")
        .join("larp-daemon")
        .join("config.json")
}

/// Статус проигрывания с телефона для Discord Rich Presence.
#[derive(Debug, Deserialize)]
struct RpcStateReq {
    enabled: bool,
    #[serde(default)]
    playing: bool,
    #[serde(default)]
    title: String,
    #[serde(default)]
    artist: String,
    #[serde(default)]
    artwork_url: Option<String>,
    #[serde(default)]
    duration_ms: Option<u64>,
    #[serde(default)]
    position_ms: Option<u64>,
}

async fn rpc_state(State(state): State<Arc<AppState>>, Json(req): Json<RpcStateReq>) -> Response {
    let Some(rpc) = state.discord.as_ref() else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"ok": false, "error": "discord rpc is disabled on daemon (нет discord_client_id)"})),
        )
            .into_response();
    };

    if !req.enabled || !req.playing {
        rpc.clear();
    } else {
        rpc.set_activity(
            &req.title,
            &req.artist,
            req.artwork_url.as_deref(),
            req.duration_ms,
            "Playing",
            req.position_ms,
            true,
        );
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

async fn logging(req: axum::extract::Request, next: Next) -> Response {
    let method = req.method().clone();
    let uri = req.uri().clone();
    let start = Instant::now();
    let resp = next.run(req).await;
    let status = resp.status();
    let ms = start.elapsed().as_millis();
    if status.as_u16() >= 400 {
        eprintln!("{method} {uri} → {status} {ms}ms");
    } else {
        println!("{method} {uri} → {status} {ms}ms");
    }
    resp
}

async fn health(State(state): State<Arc<AppState>>) -> Json<Health> {
    Json(Health {
        ok: true,
        version: "larp-daemon-0.1.0",
        port: state.conf.port,
    })
}

async fn create_job(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DownloadReq>,
) -> Response {
    if larp_core::api::Source::from_str(&req.source).is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"ok": false, "error": format!("unknown source {}", req.source)})),
        )
            .into_response();
    }
    if req.track_id.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"ok": false, "error": "track_id is empty"})),
        )
            .into_response();
    }

    let id = job_id(&req.source, &req.track_id);
    let existing = state.get(&id).await;
    if let Some(job) = existing {
        if job.state == "done" || job.state == "running" {
            return Json(serde_json::json!({"ok": true, "job": job})).into_response();
        }
    }

    let mut job = Job::new(
        id,
        req.source.clone(),
        req.track_id.clone(),
        req.title,
        req.artist,
    );
    state.upsert(job.clone()).await;
    if job.state != "done" {
        job.state = "queued".into();
        state.upsert(job.clone()).await;
    }
    download::spawn_download(state.clone(), job.clone());
    Json(serde_json::json!({"ok": true, "job": job})).into_response()
}

async fn list_jobs(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let jobs = state.all().await;
    let arr: Vec<serde_json::Value> = jobs
        .into_iter()
        .map(|j| serde_json::to_value(j).unwrap_or(serde_json::Value::Null))
        .collect();
    Json(serde_json::json!({"ok": true, "jobs": arr}))
}

#[derive(Deserialize)]
struct SearchReq {
    source: String,
    query: String,
}

/// Поиск через компьютер (не с телефона): телефону VPN не нужен,
/// токены и client_id живут на стороне демона.
async fn search(State(state): State<Arc<AppState>>, Query(q): Query<SearchReq>) -> Response {
    let result = match larp_core::api::Source::from_str(&q.source) {
        Some(larp_core::api::Source::YandexMusic) => {
            larp_core::api::search_yandex(&q.query, &state.conf.yandex_token).await
        }
        Some(larp_core::api::Source::SoundCloud) => larp_core::api::search_soundcloud(&q.query).await,
        Some(larp_core::api::Source::YouTubeMusic) => larp_core::api::search_ytmusic(&q.query).await,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"ok": false, "error": format!("unknown source {}", q.source)})),
            )
                .into_response();
        }
    };

    match result {
        Ok(tracks) => Json(serde_json::json!({"ok": true, "results": tracks})).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(serde_json::json!({"ok": false, "error": e.to_string()})),
        )
            .into_response(),
    }
}

async fn get_job(State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    match state.get(&id).await {
        Some(job) => Json(serde_json::json!({"ok": true, "job": job})).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"ok": false, "error": "no such job"})),
        )
            .into_response(),
    }
}

const CONTENT_TYPE_MP3: &str = "audio/mpeg";

#[derive(Deserialize)]
struct ThumbReq {
    #[serde(default)]
    url: String,
}

/// Прокси превьюшек (обложек): телефон часто не достаёт ни sndcdn, ни googleusercontent.
async fn thumb(Query(q): Query<ThumbReq>) -> Response {
    if !q.url.starts_with("http://") && !q.url.starts_with("https://") {
        return (StatusCode::BAD_REQUEST, "bad url").into_response();
    }
    let resp = match reqwest::get(&q.url).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("thumb: fetch failed: {e}");
            return StatusCode::BAD_GATEWAY.into_response();
        }
    };
    let status = resp.status();
    if !status.is_success() {
        return (status, "upstream error").into_response();
    }
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();
    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            eprintln!("thumb: body read failed: {e}");
            return StatusCode::BAD_GATEWAY.into_response();
        }
    };
    (
        status,
        [(header::CONTENT_TYPE, content_type)],
        axum::body::Body::from(bytes.to_vec()),
    )
        .into_response()
}

async fn serve_file(State(state): State<Arc<AppState>>, Path(name): Path<String>, headers: HeaderMap) -> Response {
    if !is_valid_file_name(&name) {
        return (StatusCode::BAD_REQUEST, "bad file name").into_response();
    }
    let path = state.conf.files_dir().join(&name);
    let meta = match tokio::fs::metadata(&path).await {
        Ok(m) => m,
        Err(_) => return (StatusCode::NOT_FOUND, "not found").into_response(),
    };
    if !meta.is_file() {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    }
    let total = meta.len();
    let bytes = match tokio::fs::read(&path).await {
        Ok(b) => b,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };

    let mut status = StatusCode::OK;
    let mut start = 0u64;
    let mut end = total.saturating_sub(1);

    if let Some(range) = headers.get(header::RANGE) {
        if let Some(parsed) = parse_range(range, total) {
            start = parsed.0;
            end = parsed.1;
            status = StatusCode::PARTIAL_CONTENT;
        }
    }

    let len = (end - start + 1) as usize;
    let body_bytes = bytes[start as usize..start as usize + len].to_vec();

    let mut resp = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, CONTENT_TYPE_MP3)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, len.to_string())
        .header(header::CONTENT_RANGE, format!("bytes {}-{}/{}", start, end, total))
        .body(axum::body::Body::from(body_bytes))
        .unwrap();

    resp.headers_mut().insert("Access-Control-Allow-Origin", HeaderValue::from_static("*"));
    resp
}

fn is_valid_file_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() == 36 && name.ends_with(".mp3") && name[..32].bytes().all(|b| b.is_ascii_hexdigit())
}

fn parse_range(hv: &HeaderValue, total: u64) -> Option<(u64, u64)> {
    let v = hv.to_str().ok()?;
    let v = v.strip_prefix("bytes=")?;
    let (a, b) = v.split_once('-')?;

    if a.is_empty() {
        // suffix range: last N bytes
        let n: u64 = b.parse().ok()?;
        if n == 0 {
            return None;
        }
        let start = total.saturating_sub(n);
        return Some((start, total.saturating_sub(1)));
    }

    let start: u64 = a.parse().ok()?;
    if start >= total {
        return Some((start, start)); // пустой slice, 416 лучше, но для AVPlayer хватает
    }
    let end = if b.is_empty() {
        total.saturating_sub(1)
    } else {
        b.parse::<u64>().unwrap_or(total.saturating_sub(1)).min(total.saturating_sub(1))
    };
    Some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_name_check() {
        let name = crate::jobs::file_name_for(&format!("{:x}", md5::compute(b"ytmusic:abc")));
        assert!(is_valid_file_name(&name));
        assert!(!is_valid_file_name("../evil.mp3"));
        assert!(!is_valid_file_name(&name.replacen("mp3", "exe", 1)));
        assert!(!is_valid_file_name("not-a-hash.mp3"));
    }

    #[test]
    fn range_parse() {
        assert_eq!(parse_range(&HeaderValue::from_static("bytes=0-99"), 1000), Some((0, 99)));
        assert_eq!(parse_range(&HeaderValue::from_static("bytes=500-"), 1000), Some((500, 999)));
        assert_eq!(parse_range(&HeaderValue::from_static("bytes=-200"), 1000), Some((800, 999)));
        assert!(parse_range(&HeaderValue::from_static("bytes="), 1000).is_none());
    }
}