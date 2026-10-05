use crate::config::{Config, DEFAULT_DISCORD_CLIENT_ID};
use crate::discord_rpc::DiscordRpc;
use larp_core::api::Track;
use larp_core::db::{Database, LikeOp, Playlist};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

const YANDEX_LIKES_TTL: Duration = Duration::from_secs(300);

/// Кэш лайков аккаунта Яндекс Музыки («Мне нравится»), постранично из API.
#[derive(Debug, Clone)]
pub struct CachedLikes {
    pub tracks: Vec<Track>,
    pub fetched_at: Instant,
}

impl Default for CachedLikes {
    fn default() -> Self {
        CachedLikes {
            tracks: Vec::new(),
            fetched_at: Instant::now() - YANDEX_LIKES_TTL,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Job {
    pub id: String,
    pub source: String,
    pub track_id: String,
    pub title: String,
    pub artist: String,
    pub state: String,      // queued | running | done | error
    pub message: String,
    pub progress: f32,      // 0..=100
    pub file_name: Option<String>,
    pub file_url: Option<String>,
    pub size_bytes: Option<u64>,
    pub created_at: u64,
    pub updated_at: u64,
}

impl Job {
    pub fn new(id: String, source: String, track_id: String, title: String, artist: String) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Job {
            id,
            source,
            track_id,
            title,
            artist,
            state: "queued".into(),
            message: String::new(),
            progress: 0.0,
            file_name: None,
            file_url: None,
            size_bytes: None,
            created_at: now,
            updated_at: now,
        }
    }
}

pub struct AppState {
    pub jobs: RwLock<HashMap<String, Job>>,
    pub conf: Config,
    /// Общая с music-player-tui база лайков/плейлистов (SQLite, доступ последовательный).
    pub db: Mutex<Database>,
    /// Кэш «Мне нравится» из API Яндекс Музыки.
    pub yandex_likes_cache: tokio::sync::Mutex<CachedLikes>,
    /// Discord Rich Presence: активность ставит телефон (или TUI-плеер). None — отключено.
    pub discord: Option<DiscordRpc>,
    /// Когда телефон последний раз прислал «playing=true» (фантомная проверка).
    pub rpc_last_seen: Mutex<Option<Instant>>,
    /// Сейчас ли показана активность в Discord.
    pub rpc_active: AtomicBool,
}

impl AppState {
    pub fn new(conf: Config, db: Database) -> Arc<Self> {
        let discord_id = if conf.discord_client_id.is_empty() {
            DEFAULT_DISCORD_CLIENT_ID
        } else {
            &conf.discord_client_id
        };
        let discord = DiscordRpc::new(discord_id);
        Arc::new(AppState {
            jobs: RwLock::new(HashMap::new()),
            conf,
            db: Mutex::new(db),
            yandex_likes_cache: tokio::sync::Mutex::new(CachedLikes::default()),
            discord,
            rpc_last_seen: Mutex::new(None),
            rpc_active: AtomicBool::new(false),
        })
    }

    pub async fn upsert(&self, job: Job) {
        let mut map = self.jobs.write().await;
        map.insert(job.id.clone(), job);
    }

    pub async fn get(&self, id: &str) -> Option<Job> {
        self.jobs.read().await.get(id).cloned()
    }

    pub async fn all(&self) -> Vec<Job> {
        let map = self.jobs.read().await;
        let mut v: Vec<Job> = map.values().cloned().collect();
        v.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        v
    }

    // ============ shared database (likes / playlists) ============

    pub fn like(&self, track: &Track) -> anyhow::Result<()> {
        self.db.lock().unwrap().like_track(track)
    }

    pub fn unlike(&self, source: &str, track_id: &str) -> anyhow::Result<()> {
        let src = larp_core::api::Source::from_str(source)
            .ok_or_else(|| anyhow::anyhow!("unknown source: {source}"))?;
        self.db.lock().unwrap().unlike_track(&src, track_id)
    }

    pub fn liked(&self, source: Option<&str>) -> anyhow::Result<Vec<Track>> {
        let db = self.db.lock().unwrap();
        let tracks = db.get_liked()?;
        match source {
            Some(s) if !s.is_empty() => {
                Ok(tracks.into_iter().filter(|t| t.source.as_str() == s).collect())
            }
            _ => Ok(tracks),
        }
    }

    /// Сверка телефона с компом: применяем его оффлайн-очередь лайков по порядку
    /// и отдаём актуальный список (одним ответом, без гонки между запросами).
    pub fn apply_like_ops(&self, ops: &[LikeOp]) -> anyhow::Result<Vec<Track>> {
        let db = self.db.lock().unwrap();
        db.apply_like_ops(ops)?;
        Ok(db.get_liked()?)
    }

    pub fn playlists(&self) -> anyhow::Result<Vec<Playlist>> {
        self.db.lock().unwrap().get_playlists()
    }

    pub fn create_playlist(&self, name: &str) -> anyhow::Result<i64> {
        self.db.lock().unwrap().create_playlist(name)
    }

    pub fn delete_playlist(&self, id: i64) -> anyhow::Result<()> {
        self.db.lock().unwrap().delete_playlist(id)
    }

    pub fn playlist_tracks(&self, id: i64) -> anyhow::Result<Vec<Track>> {
        self.db.lock().unwrap().get_playlist_tracks(id)
    }

    pub fn add_to_playlist(&self, id: i64, track: &Track) -> anyhow::Result<()> {
        self.db.lock().unwrap().add_to_playlist(id, track)
    }

    pub fn remove_from_playlist(&self, id: i64, source: &str, track_id: &str) -> anyhow::Result<()> {
        let src = larp_core::api::Source::from_str(source)
            .ok_or_else(|| anyhow::anyhow!("unknown source: {source}"))?;
        self.db.lock().unwrap().remove_from_playlist(id, &src, track_id)
    }

    /// Лайки аккаунта Яндекс Музыки с кэшированием на 5 минут.
    pub async fn yandex_likes(&self) -> anyhow::Result<Vec<Track>> {
        let mut cache = self.yandex_likes_cache.lock().await;
        if !cache.tracks.is_empty() && cache.fetched_at.elapsed() < YANDEX_LIKES_TTL {
            return Ok(cache.tracks.clone());
        }
        let tracks = larp_core::api::get_yandex_likes(&self.conf.yandex_token).await?;
        cache.tracks = tracks.clone();
        cache.fetched_at = Instant::now();
        Ok(tracks)
    }
}

pub fn job_id(source: &str, track_id: &str) -> String {
    format!("{:x}", md5::compute(format!("{}:{}", source, track_id).as_bytes()))
}

pub fn file_name_for(id: &str) -> String {
    format!("{}.mp3", id)
}