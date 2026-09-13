use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use std::sync::Arc;

use crate::jobs::AppState;

#[derive(Debug, Deserialize)]
pub struct LyricsReq {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
}

/// GET /api/lyrics?title=...&artist=...
/// Search LRC lyrics via lrclib.net (public, no auth, no crypto).
/// All searching happens on the PC daemon side - the phone needs nothing.
pub async fn lyrics(
    State(_state): State<Arc<AppState>>,
    Query(q): Query<LyricsReq>,
) -> impl IntoResponse {
    let title = q.title.trim();
    let artist = q.artist.trim();

    if title.is_empty() && artist.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"ok": false, "error": "empty query"})),
        )
            .into_response();
    }

    match fetch_lyrics(title, artist).await {
        Ok(Some(lrc)) => Json(serde_json::json!({"ok": true, "lyrics": lrc})).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"ok": false, "error": "lyrics not found"})),
        )
            .into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(serde_json::json!({"ok": false, "error": e.to_string()})),
        )
            .into_response(),
    }
}

async fn fetch_lyrics(title: &str, artist: &str) -> anyhow::Result<Option<String>> {
    let url = format!(
        "https://lrclib.net/api/get?artist_name={}&track_name={}",
        urlencoding::encode(artist),
        urlencoding::encode(title)
    );

    let client = reqwest::Client::builder()
        .user_agent(
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36",
        )
        .build()?;

    let resp = client.get(&url).send().await?;
    let status = resp.status();
    let text = resp.text().await?;

    if std::env::var("LARP_DEBUG_LYRICS").is_ok() {
        eprintln!(
            "[lyrics] lrclib: status={status} len={} body={}",
            text.len(),
            &text[..text.len().min(400)]
        );
    }

    if !status.is_success() {
        return Ok(None);
    }

    let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
        anyhow::anyhow!("lrclib parse: {e} | status={status} body: {}", &text[..text.len().min(400)])
    })?;

    let lrc = v["syncedLyrics"]
        .as_str()
        .filter(|s| !s.trim().is_empty());

    Ok(lrc.map(|s| s.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*     ;
    use axum::extract::{Query as AxumQuery, rejection::QueryRejection};

    #[test]
    fn lyrics_req_parses() {
        let uri = axum::http::Uri::from_static(
            "/api/lyrics?title=Let%20It%20Happen&artist=Tame%20Impala",
        );
        let req = AxumQuery::<LyricsReq>::try_from_uri(&uri)
            .map(|q| q.0)
            .unwrap();
        assert_eq!(req.title, "Let It Happen");
        assert_eq!(req.artist, "Tame Impala");
    }
}
