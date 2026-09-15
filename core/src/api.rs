use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Source {
    YandexMusic,
    SoundCloud,
    YouTubeMusic,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::YandexMusic => "yandex",
            Source::SoundCloud => "soundcloud",
            Source::YouTubeMusic => "ytmusic",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "yandex" => Some(Source::YandexMusic),
            "soundcloud" => Some(Source::SoundCloud),
            "ytmusic" => Some(Source::YouTubeMusic),
            _ => None,
        }
    }
}

impl Serialize for Source {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Source {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Source::from_str(&s).ok_or_else(|| serde::de::Error::custom(format!("unknown source: {s}")))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub source: Source,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<u16>,
}

impl Track {
    pub fn local_key(&self) -> String {
        format!("{}:{}", self.source.as_str(), self.id)
    }
}

// ========== Yandex Music ==========

const YM_API: &str = "https://api.music.yandex.net";
const YM_SIGN_SALT: &str = "XGRlBW9FXlekgbPrRHuSiA";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmSearchResponse {
    result: YmSearchResult,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmSearchResult {
    tracks: Option<YmSearchTracks>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmSearchTracks {
    results: Vec<YmTrack>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmTrack {
    id: serde_json::Value,
    title: Option<String>,
    #[serde(default)]
    artists: Vec<YmArtist>,
    duration_ms: Option<u64>,
    #[serde(default)]
    available: Option<bool>,
    #[serde(default)]
    cover_uri: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmArtist {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmDownloadInfoResponse {
    result: Vec<YmDownloadInfo>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmDownloadInfo {
    codec: String,
    download_info_url: String,
}

#[derive(Debug, Deserialize)]
struct YmDownloadUrl {
    host: String,
    path: String,
    ts: String,
    s: String,
}

fn clean_token(token: &str) -> String {
    token.chars().take_while(|&c| c != '&').collect()
}

pub async fn search_yandex(query: &str, token: &str) -> anyhow::Result<Vec<Track>> {
    if token.is_empty() {
        anyhow::bail!("Yandex token is not configured");
    }

    let url = format!(
        "{}/search/?text={}&type=track&page=0&nocorrect=false",
        YM_API,
        urlencoding::encode(query)
    );

    let resp = reqwest::Client::new()
        .get(&url)
        .header("Authorization", format!("OAuth {}", clean_token(token)))
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Yandex HTTP {}: {}", status, body);
    }

    let text = resp.text().await?;
    let resp: YmSearchResponse = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Yandex parse error: {} | body: {}", e, &text[..text.len().min(500)]))?;

    let tracks = resp
        .result
        .tracks
        .map(|t| t.results)
        .unwrap_or_default()
        .into_iter()
        .filter(|t| t.available.unwrap_or(false))
        .map(ym_track_to_track)
        .collect();

    Ok(tracks)
}

fn ym_track_to_track(t: YmTrack) -> Track {
    let id = match &t.id {
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => s.clone(),
        _ => "0".to_string(),
    };
    let artist = t.artists.first()
        .and_then(|a| a.name.clone())
        .unwrap_or_else(|| "Unknown".to_string());
    let artwork_url = t.cover_uri.map(|uri| {
        format!("https://{}", uri.replace("%%", "400x400"))
    });
    Track {
        id,
        title: t.title.unwrap_or_default(),
        artist,
        source: Source::YandexMusic,
        preview_url: None,
        artwork_url,
        duration_ms: t.duration_ms,
        album: None,
        year: None,
    }
}

// ============ Yandex Music: лайки аккаунта («Мне нравится») ============

const YM_PAGE_SIZE: usize = 100;
const YM_MAX_PAGES: usize = 100; // до 10 000 треков
const YM_TRACK_BATCH: usize = 100; // id треков на один запрос /tracks

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmStatusResponse {
    result: YmStatus,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmStatus {
    account: YmAccount,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YmAccount {
    uid: i64,
}

async fn yandex_uid(token: &str) -> anyhow::Result<i64> {
    let url = format!("{}/account/status", YM_API);
    let resp = reqwest::Client::new()
        .get(&url)
        .header("Authorization", format!("OAuth {}", clean_token(token)))
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Yandex account status HTTP {}: {}", status, body);
    }
    let text = resp.text().await?;
    let resp: YmStatusResponse = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Yandex status parse error: {} | body: {}", e, &text[..text.len().min(500)]))?;
    Ok(resp.result.account.uid)
}

/// Все лайки аккаунта («Мне нравится») из Яндекс Музыки.
///
/// `/users/{uid}/likes/tracks` отдаёт только ссылки (id, albumId, timestamp),
/// поэтому детали треков дотаскиваем табличным запросом `/tracks?track-ids=…`.
pub async fn get_yandex_likes(token: &str) -> anyhow::Result<Vec<Track>> {
    if token.is_empty() {
        anyhow::bail!("Yandex token is not configured");
    }

    let uid = yandex_uid(token).await?;
    let client = reqwest::Client::new();

    // 1. id лайкнутых треков. API может игнорировать page-size и отдавать всё сразу —
    //    дедуплицируем и останавливаемся, когда новая страница не добавила id.
    let mut ids: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = Default::default();
    for page in 0..YM_MAX_PAGES {
        let url = format!(
            "{}/users/{}/likes/tracks?page={}&page-size={}",
            YM_API, uid, page, YM_PAGE_SIZE
        );
        let resp = client
            .get(&url)
            .header("Authorization", format!("OAuth {}", clean_token(token)))
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Yandex likes HTTP {}: {}", status, body);
        }
        let text = resp.text().await?;
        let page_ids = parse_likes_ids(&text)
            .map_err(|e| anyhow::anyhow!("Yandex likes parse error: {} | body: {}", e, &text[..text.len().min(500)]))?;
        if page_ids.is_empty() {
            break;
        }
        let mut added = 0;
        for id in page_ids {
            if seen.insert(id.clone()) {
                ids.push(id);
                added += 1;
            }
        }
        if added == 0 {
            break;
        }
    }

    // 2. Детали треков батчами.
    let mut tracks = Vec::with_capacity(ids.len());
    for chunk in ids.chunks(YM_TRACK_BATCH) {
        let ids_csv = chunk.join(",");
        let url = format!("{}/tracks?track-ids={}", YM_API, ids_csv);
        let resp = client
            .get(&url)
            .header("Authorization", format!("OAuth {}", clean_token(token)))
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Yandex tracks HTTP {}: {}", status, body);
        }
        let text = resp.text().await?;
        let root: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| anyhow::anyhow!("Yandex tracks parse error: {} | body: {}", e, &text[..text.len().min(500)]))?;
        if let Some(items) = root.get("result").and_then(|r| r.as_array()) {
            for item in items {
                if item.is_null() || item.get("error").is_some() {
                    continue;
                }
                if let Ok(t) = serde_json::from_value::<YmTrack>(item.clone()) {
                    tracks.push(ym_track_to_track(t));
                }
            }
        }
    }

    Ok(tracks)
}

/// Достаёт id лайкнутых треков из ответа /users/{uid}/likes/tracks
/// (детали треков там не отдаются — только ссылки; путь result.library.tracks).
fn parse_likes_ids(text: &str) -> anyhow::Result<Vec<String>> {
    let v: serde_json::Value = serde_json::from_str(text)?;
    let Some(result) = v.get("result") else {
        return Ok(Vec::new());
    };
    let arr = result
        .pointer("/library/tracks")
        .or_else(|| result.get("tracks"))
        .or_else(|| if result.is_array() { Some(result) } else { None });
    let Some(arr) = arr else {
        return Ok(Vec::new());
    };
    let mut ids = Vec::new();
    if let Some(list) = arr.as_array() {
        for item in list {
            match item.get("id") {
                Some(serde_json::Value::Number(n)) => ids.push(n.to_string()),
                Some(serde_json::Value::String(s)) => ids.push(s.clone()),
                _ => {}
            }
        }
    }
    Ok(ids)
}

pub async fn get_yandex_download_url(track_id: &str, token: &str) -> anyhow::Result<String> {
    let url = format!("{}/tracks/{}/download-info", YM_API, track_id);

    let resp = reqwest::Client::new()
        .get(&url)
        .header("Authorization", format!("OAuth {}", clean_token(token)))
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Yandex download HTTP {}: {}", status, body);
    }

    let text = resp.text().await?;
    let resp: YmDownloadInfoResponse = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Yandex download parse error: {} | body: {}", e, &text[..text.len().min(500)]))?;

    let info = resp.result.iter()
        .find(|i| i.codec == "mp3" || i.codec == "flac")
        .or(resp.result.first())
        .ok_or_else(|| anyhow::anyhow!("No download info found"))?;

    let xml_url = &info.download_info_url;
    let xml_text = reqwest::get(xml_url).await?.text().await?;

    let download_url: YmDownloadUrl = serde_xml_rs::from_str(&xml_text)?;

    let path_no_slash = download_url.path.strip_prefix('/').unwrap_or(&download_url.path);
    let sign_input = format!("{}{}{}", YM_SIGN_SALT, path_no_slash, download_url.s);
    let sign = format!("{:x}", md5::compute(sign_input.as_bytes()));

    let direct_url = format!(
        "https://{}/get-mp3/{}/{}/{}",
        download_url.host, sign, download_url.ts, path_no_slash
    );

    Ok(direct_url)
}

// ========== SoundCloud ==========

const SC_API: &str = "https://api-v2.soundcloud.com";

const SC_HEADERS: [(&str, &str); 4] = [
    (
        "User-Agent",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36",
    ),
    ("Accept", "application/json, text/plain, */*"),
    ("Accept-Language", "en-US,en;q=0.9"),
    ("Origin", "https://soundcloud.com"),
];

static SC_CLIENT_ID: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

pub fn set_sc_client_id(id: &str) {
    if !id.is_empty() {
        *SC_CLIENT_ID.lock().unwrap() = Some(id.to_string());
    }
}

fn sc_request(client: &reqwest::Client, url: &str) -> reqwest::RequestBuilder {
    let mut rb = client.get(url);
    for (k, v) in SC_HEADERS {
        rb = rb.header(k, v);
    }
    rb
}

async fn get_sc_client_id() -> anyhow::Result<String> {
    if let Some(id) = SC_CLIENT_ID.lock().unwrap().as_ref() {
        return Ok(id.clone());
    }

    let client = reqwest::Client::new();
    let html = sc_request(&client, "https://soundcloud.com/")
        .send().await?
        .text().await?;

    let script_re = regex::Regex::new(r#"src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#)?;
    let cid_re = regex::Regex::new(r#"client_id:"([a-zA-Z0-9]+)""#)?;

    let mut script_urls: Vec<String> = script_re.captures_iter(&html)
        .filter_map(|cap| cap.get(1).map(|m| m.as_str().to_string()))
        .collect();
    script_urls.reverse();

    for js_url in &script_urls {
        let js_text = match sc_request(&client, js_url).send().await {
            Ok(r) => match r.text().await {
                Ok(t) => t,
                Err(_) => continue,
            },
            Err(_) => continue,
        };
        if let Some(m) = cid_re.captures(&js_text) {
            let id = m[1].to_string();
            *SC_CLIENT_ID.lock().unwrap() = Some(id.clone());
            return Ok(id);
        }
    }

    anyhow::bail!("Could not extract SoundCloud client_id from JS bundles")
}

#[derive(Debug, Deserialize)]
struct ScSearchResponse {
    collection: Vec<ScTrack>,
}

#[derive(Debug, Deserialize)]
struct ScTrack {
    id: i64,
    title: String,
    duration: u64,
    #[serde(default)]
    artwork_url: Option<String>,
    user: ScUser,
    #[serde(default)]
    media: Option<ScMedia>,
}

#[derive(Debug, Deserialize)]
struct ScUser {
    username: String,
}

#[derive(Debug, Deserialize)]
struct ScMedia {
    #[serde(default)]
    transcodings: Vec<ScTranscoding>,
}

#[derive(Debug, Deserialize)]
struct ScTranscoding {
    url: String,
    format: ScFormat,
}

#[derive(Debug, Deserialize)]
struct ScFormat {
    protocol: String,
    mime_type: String,
}

/// По id трека получаем нормальную ссылку soundcloud.com/<user>/<slug> —
/// yt-dlp умеет качать только такие, API-ссылки он не разбирает.
pub async fn soundcloud_permalink(track_id: &str) -> anyhow::Result<String> {
    let client_id = get_sc_client_id().await?;

    let url = format!(
        "{}/tracks/{}?client_id={}",
        SC_API,
        urlencoding::encode(track_id),
        urlencoding::encode(&client_id)
    );

    let resp = sc_request(&reqwest::Client::new(), &url)
        .send()
        .await?;
    let status = resp.status();
    let body = resp.text().await?;
    if !status.is_success() || body.trim().is_empty() || body.trim() == "{}" {
        SC_CLIENT_ID.lock().unwrap().take();
        anyhow::bail!("SoundCloud track not found (HTTP {status}): {}", &body[..body.len().min(200)]);
    }

    let v: serde_json::Value = serde_json::from_str(&body)?;
    if v.get("id").is_none() {
        SC_CLIENT_ID.lock().unwrap().take();
        anyhow::bail!("SoundCloud track not found: {}", &body[..body.len().min(200)]);
    }

    v.get("permalink_url")
        .and_then(|p| p.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("no permalink_url in SoundCloud track response"))
}

pub async fn search_soundcloud(query: &str) -> anyhow::Result<Vec<Track>> {
    let client_id = get_sc_client_id().await?;

    let url = format!(
        "{}/search/tracks?q={}&client_id={}&limit=20",
        SC_API,
        urlencoding::encode(query),
        urlencoding::encode(&client_id)
    );

    let body = sc_request(&reqwest::Client::new(), &url)
        .send().await?
        .text().await?;

    if body.trim() == "{}" || body.trim().is_empty() {
        SC_CLIENT_ID.lock().unwrap().take();
        anyhow::bail!("SoundCloud returned empty — client_id may be expired.");
    }

    let resp: ScSearchResponse = serde_json::from_str(&body)?;

    let tracks = resp.collection.into_iter().map(|t| {
        let artwork = t.artwork_url.map(|u| u.replace("-large", "-t500x500"));

        let mut preview_url = None;
        if let Some(ref media) = t.media {
            if let Some(tc) = media.transcodings.iter().find(|tc| tc.format.protocol == "cbc-encrypted-hls" && tc.format.mime_type.starts_with("audio/mp4")) {
                preview_url = Some(tc.url.clone());
            }
            if preview_url.is_none() {
                if let Some(tc) = media.transcodings.iter().find(|tc| tc.format.protocol == "hls") {
                    preview_url = Some(tc.url.clone());
                }
            }
        }

        Track {
            id: t.id.to_string(),
            title: t.title,
            artist: t.user.username,
            source: Source::SoundCloud,
            preview_url,
            artwork_url: artwork,
            duration_ms: Some(t.duration),
            album: None,
            year: None,
        }
    }).collect();

    Ok(tracks)
}

// ========== YouTube Music ==========

fn ytm_client() -> reqwest::Client {
    reqwest::Client::new()
}

pub async fn search_ytmusic(query: &str) -> anyhow::Result<Vec<Track>> {
    let body = serde_json::json!({
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20240311.01.00",
                "hl": "en"
            }
        },
        "query": query,
    });

    let url = "https://music.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

    let resp = ytm_client()
        .post(url)
        .header("Content-Type", "application/json")
        .header("Origin", "https://music.youtube.com")
        .header("Referer", "https://music.youtube.com/")
        .json(&body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("YouTube Music HTTP {}: {}", status, resp.text().await.unwrap_or_default());
    }

    let text = resp.text().await?;
    let root: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("YouTube Music parse error: {} | body: {}", e, &text[..text.len().min(500)]))?;

    let mut tracks = Vec::new();
    collect_ytm_tracks(&root, &mut tracks);

    Ok(tracks)
}

const YTM_TRACK_TYPES: [&str; 2] = ["Song", "Video"];

fn collect_ytm_tracks(value: &serde_json::Value, out: &mut Vec<Track>) {
    match value {
        serde_json::Value::Object(map) => {
            for (k, v) in map {
                if k == "musicResponsiveListItemRenderer" {
                    if let Some(track) = ytm_item_to_track(v) {
                        out.push(track);
                    }
                } else {
                    collect_ytm_tracks(v, out);
                }
            }
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                collect_ytm_tracks(v, out);
            }
        }
        _ => {}
    }
}

fn ytm_flex_runs(item: &serde_json::Value, col: usize) -> Vec<String> {
    item.get("flexColumns")
        .and_then(|a| a.as_array())
        .and_then(|a| a.get(col))
        .and_then(|c| c.pointer("/musicResponsiveListItemFlexColumnRenderer/text/runs"))
        .and_then(|r| r.as_array())
        .map(|runs| {
            runs.iter()
                .filter_map(|r| r.get("text").and_then(|t| t.as_str()).map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// "7:48" → 468_000, "1:02:03" → 3_723_000, иначе None.
fn parse_duration_str(s: &str) -> Option<u64> {
    let parts: Vec<&str> = s.split(':').collect();
    let secs: u64 = match parts.len() {
        2 => parts[1].parse::<u64>().ok()? + parts[0].parse::<u64>().ok()? * 60,
        3 => parts[2].parse::<u64>().ok()?
            + parts[1].parse::<u64>().ok()? * 60
            + parts[0].parse::<u64>().ok()? * 3600,
        _ => return None,
    };
    if secs == 0 {
        return None;
    }
    Some(secs * 1000)
}

/// Акт убьет длительность из accessibility-label: "Song • 7 minutes, 48 seconds".
fn ytm_label_duration(label: &str) -> Option<u64> {
    let re_min = regex::Regex::new(r"(\d+)\s*minutes?,?\s*(?:and\s*)?(\d+)\s*seconds").ok()?;
    if let Some(caps) = re_min.captures(label) {
        let m: u64 = caps[1].parse().ok()?;
        let s: u64 = caps[2].parse().ok()?;
        return Some((m * 60 + s) * 1000);
    }
    let re_sec = regex::Regex::new(r"(\d+)\s*seconds").ok()?;
    if let Some(caps) = re_sec.captures(label) {
        let s: u64 = caps[1].parse().ok()?;
        return Some(s * 1000);
    }
    None
}

fn ytm_play_label(item: &serde_json::Value) -> Option<String> {
    item.pointer("/overlay/musicItemThumbnailOverlayRenderer/content/musicPlayButtonRenderer/accessibilityPlayData/accessibilityData/label")
        .and_then(|l| l.as_str())
        .map(|s| s.to_string())
}

fn ytm_item_to_track(item: &serde_json::Value) -> Option<Track> {
    let video_id = item.get("playlistItemData")
        .and_then(|p| p.get("videoId"))
        .and_then(|v| v.as_str())
        .or_else(|| item.get("navigationEndpoint")
            .and_then(|n| n.get("watchEndpoint"))
            .and_then(|w| w.get("videoId"))
            .and_then(|v| v.as_str()))
        .map(|s| s.to_string())?;

    let col0 = ytm_flex_runs(item, 0);
    let col1 = ytm_flex_runs(item, 1);

    let item_type = col1.first().map(|s| s.trim()).unwrap_or("");
    if !YTM_TRACK_TYPES.contains(&item_type) {
        return None;
    }

    let title = col0.first()?.clone();

    // Артист: второй текстовый run в col1 (если это имя, а не длительность).
    let mut artist = String::new();
    for s in col1.iter().skip(1) {
        let s = s.trim();
        if s.is_empty() || s == "•" || s == "·" {
            continue;
        }
        if parse_duration_str(s).is_some() {
            continue;
        }
        if s.contains("views") || s.contains("plays") || s.contains("subscribers") || s.contains("audience") {
            continue;
        }
        artist = s.to_string();
        break;
    }
    // В новых ответах артист песен часто живет только в label: "Play <title> - <artist>".
    if artist.is_empty() {
        if let Some(label) = ytm_play_label(item) {
            let s = label.strip_prefix("Play ").unwrap_or(&label).trim();
            if let Some(rest) = s.strip_prefix(title.trim()) {
                artist = rest
                    .strip_prefix(" - ")
                    .unwrap_or(rest)
                    .trim()
                    .to_string();
            }
        }
    }
    if artist.is_empty() {
        artist = "Unknown".into();
    }

    // Длительность: из col1 ("7:48") либо из label ("7 minutes, 48 seconds").
    let mut duration_ms = col1.iter().find_map(|s| parse_duration_str(s.trim()));
    if duration_ms.is_none() {
        if let Some(label) = ytm_play_label(item) {
            duration_ms = ytm_label_duration(&label);
        }
    }

    let artwork_url = item.get("thumbnail")
        .and_then(|t| t.get("musicThumbnailRenderer"))
        .and_then(|t| t.get("thumbnail"))
        .and_then(|t| t.get("thumbnails"))
        .and_then(|t| t.as_array())
        .and_then(|arr| arr.last())
        .and_then(|t| t.get("url"))
        .and_then(|u| u.as_str())
        .map(|s| s.to_string());

    Some(Track {
        id: video_id,
        title,
        artist,
        source: Source::YouTubeMusic,
        preview_url: None,
        artwork_url,
        duration_ms,
        album: None,
        year: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_roundtrip() {
        for s in [Source::YandexMusic, Source::SoundCloud, Source::YouTubeMusic] {
            let json = serde_json::to_string(&s).unwrap();
            assert_eq!(serde_json::from_str::<Source>(&json).unwrap(), s);
        }
        assert_eq!(Source::from_str("yandex"), Some(Source::YandexMusic));
        assert_eq!(Source::from_str("nope"), None);
    }

    #[test]
    fn track_serialize_shape() {
        let t = Track {
            id: "v1".into(),
            title: "Song".into(),
            artist: "Artist".into(),
            source: Source::YouTubeMusic,
            preview_url: None,
            artwork_url: Some("http://img".into()),
            duration_ms: Some(1000),
            album: None,
            year: None,
        };
        let v: serde_json::Value = serde_json::to_value(&t).unwrap();
        assert_eq!(v["source"], "ytmusic");
        assert_eq!(v["id"], "v1");
        assert!(v.get("previewUrl").is_none(), "absent fields omitted");
        assert_eq!(v["artworkUrl"], "http://img");
    }

    #[test]
    fn ym_likes_ids_parses() {
        // Формат /users/{uid}/likes/tracks: только ссылки id/albumId/timestamp
        let text = r#"{"result":{"isWritable":true,"library":{"uid":1,"revision":1,"tracks":[
            {"id":144220916,"albumId":25670052,"timestamp":"2025-01-01T00:00:00Z"},
            {"id":"144220917","albumId":25670052,"timestamp":"2025-01-01T00:00:00Z"}
        ]}}}"#;
        let ids = parse_likes_ids(text).unwrap();
        assert_eq!(ids, vec!["144220916", "144220917"]);

        // Пустой результат
        assert!(parse_likes_ids(r#"{"result":null}"#).unwrap().is_empty());
        // Старый плоский формат result.tracks
        let old = r#"{"result":{"tracks":[{"id":100},{"id":101}]}}"#;
        assert_eq!(parse_likes_ids(old).unwrap().len(), 2);
    }
}