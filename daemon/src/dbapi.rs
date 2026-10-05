// REST API демона для лайков и плейлистов поверх общей с music-player-tui базы
// (~/.config/music-player-tui/liked.db).
use crate::jobs::AppState;
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use larp_core::api::Track;
use larp_core::db::LikeOp;
use serde::Deserialize;
use std::sync::Arc;

#[derive(Debug, Deserialize)]
pub struct UnlikeReq {
    pub source: String,
    pub track_id: String,
}

#[derive(Debug, Deserialize)]
pub struct PlaylistReq {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct RemoveReq {
    pub source: String,
    pub track_id: String,
}

#[derive(Debug, Deserialize)]
pub struct LikedQuery {
    #[serde(default)]
    pub source: Option<String>,
}

fn err(e: anyhow::Error) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(serde_json::json!({"ok": false, "error": format!("{e:#}")})),
    )
        .into_response()
}

fn bad(msg: impl Into<String>) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(serde_json::json!({"ok": false, "error": msg.into()})),
    )
        .into_response()
}

fn ok_unit() -> Response {
    Json(serde_json::json!({"ok": true})).into_response()
}

// ============ likes ============

pub async fn get_liked(
    State(state): State<Arc<AppState>>,
    Query(q): Query<LikedQuery>,
) -> Response {
    match state.liked(q.source.as_deref()) {
        Ok(tracks) => Json(serde_json::json!({"ok": true, "liked": tracks})).into_response(),
        Err(e) => err(e),
    }
}

pub async fn like_track(
    State(state): State<Arc<AppState>>,
    Json(track): Json<Track>,
) -> Response {
    match state.like(&track) {
        Ok(()) => ok_unit(),
        Err(e) => err(e),
    }
}

pub async fn unlike_track(
    State(state): State<Arc<AppState>>,
    Json(req): Json<UnlikeReq>,
) -> Response {
    match state.unlike(&req.source, &req.track_id) {
        Ok(()) => ok_unit(),
        Err(e) => bad(format!("{e:#}")),
    }
}

#[derive(Debug, Deserialize)]
pub struct SyncLikedReq {
    /// Оффлайн-очередь телефона: применяется строго по порядку.
    #[serde(default)]
    pub ops: Vec<LikeOp>,
}

/// Сверка с компом: телефон присылает накопившиеся оффлайн-лайки/анлайки,
/// демон применяет их к общей базе и отдаёт итоговый список одним ответом.
pub async fn sync_liked(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SyncLikedReq>,
) -> Response {
    match state.apply_like_ops(&req.ops) {
        Ok(tracks) => Json(serde_json::json!({"ok": true, "liked": tracks})).into_response(),
        Err(e) => err(e),
    }
}

/// Лайки аккаунта Яндекс Музыки («Мне нравится») — не из local DB, а из API Яндекса.
pub async fn yandex_likes(State(state): State<Arc<AppState>>) -> Response {
    if state.conf.yandex_token.is_empty() {
        return bad("Yandex token is not configured");
    }
    match state.yandex_likes().await {
        Ok(tracks) => Json(serde_json::json!({"ok": true, "likes": tracks})).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(serde_json::json!({"ok": false, "error": format!("{e:#}")})),
        )
            .into_response(),
    }
}

// ============ playlists ============

pub async fn list_playlists(State(state): State<Arc<AppState>>) -> Response {
    match state.playlists() {
        Ok(pls) => Json(serde_json::json!({"ok": true, "playlists": pls})).into_response(),
        Err(e) => err(e),
    }
}

pub async fn create_playlist(
    State(state): State<Arc<AppState>>,
    Json(req): Json<PlaylistReq>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return bad("empty playlist name");
    }
    match state.create_playlist(name) {
        Ok(id) => Json(serde_json::json!({"ok": true, "id": id})).into_response(),
        Err(e) => bad(format!("{e:#}")),
    }
}

pub async fn delete_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
) -> Response {
    match state.delete_playlist(id) {
        Ok(()) => ok_unit(),
        Err(e) => err(e),
    }
}

pub async fn get_playlist_tracks(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
) -> Response {
    match state.playlist_tracks(id) {
        Ok(tracks) => Json(serde_json::json!({"ok": true, "tracks": tracks})).into_response(),
        Err(e) => err(e),
    }
}

pub async fn add_playlist_track(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
    Json(track): Json<Track>,
) -> Response {
    match state.add_to_playlist(id, &track) {
        Ok(()) => ok_unit(),
        Err(e) => err(e),
    }
}

pub async fn remove_playlist_track(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
    Json(req): Json<RemoveReq>,
) -> Response {
    match state.remove_from_playlist(id, &req.source, &req.track_id) {
        Ok(()) => ok_unit(),
        Err(e) => bad(format!("{e:#}")),
    }
}