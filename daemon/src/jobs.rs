use crate::config::Config;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

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
}

impl AppState {
    pub fn new(conf: Config) -> Arc<Self> {
        Arc::new(AppState {
            jobs: RwLock::new(HashMap::new()),
            conf,
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
}

pub fn job_id(source: &str, track_id: &str) -> String {
    format!("{:x}", md5::compute(format!("{}:{}", source, track_id).as_bytes()))
}

pub fn file_name_for(id: &str) -> String {
    format!("{}.mp3", id)
}