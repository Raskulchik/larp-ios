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
        .map(|t| {
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
        })
        .collect();

    Ok(tracks)
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

fn ytm_item_to_track(item: &serde_json::Value) -> Option<Track> {
    let video_id = item.get("playlistItemData")
        .and_then(|p| p.get("videoId"))
        .and_then(|v| v.as_str())
        .or_else(|| item.get("navigationEndpoint")
            .and_then(|n| n.get("watchEndpoint"))
            .and_then(|w| w.get("videoId"))
            .and_then(|v| v.as_str()))
        .map(|s| s.to_string())?;

    let columns = item.get("flexColumns")?.as_array()?;
    let title = columns.get(0)?
        .pointer("/musicResponsiveListItemFlexColumnRenderer/text/runs")
        .and_then(|r| r.as_array())?
        .first()?
        .get("text")?
        .as_str()?
        .to_string();

    let subtitle_runs: Vec<String> = columns.get(1)
        .and_then(|col| col.pointer("/musicResponsiveListItemFlexColumnRenderer/text/runs"))
        .and_then(|r| r.as_array())
        .map(|runs| runs.iter()
            .filter_map(|r| r.get("text").and_then(|t| t.as_str()).map(|s| s.to_string()))
            .collect())
        .unwrap_or_default();

    let is_typed = subtitle_runs.first().map_or(false, |s| {
        matches!(s.as_str(), "Song" | "Video" | "Artist" | "Album" | "Single" | "Episode")
    });
    let artist_runs: Box<dyn Iterator<Item = &String>> = if is_typed {
        Box::new(subtitle_runs.iter().skip(1))
    } else {
        Box::new(subtitle_runs.iter())
    };

    let artist = artist_runs
        .map(|s| s.trim())
        .filter(|s| !s.is_empty() && *s != "•" && *s != "," && *s != "&"
            && !s.contains("views") && !s.contains("subscribers") && !s.contains("years ago")
            && !s.chars().all(|c| c.is_ascii_digit() || c == ':' || c == ' '))
        .collect::<Vec<_>>()
        .join(" ");
    let artist = if artist.is_empty() { "Unknown".to_string() } else { artist };

    let duration_ms = subtitle_runs.iter()
        .rev()
        .find_map(|s| {
            let s = s.trim();
            let parts: Vec<&str> = s.split(':').collect();
            if parts.len() == 2 {
                let min: u64 = parts[0].parse().ok()?;
                let sec: u64 = parts[1].parse().ok()?;
                Some((min * 60 + sec) * 1000)
            } else {
                None
            }
        });

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
}