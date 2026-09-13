use crate::api;
use crate::db::Database;
use serde::Serialize;
use serde_json::{json, Value};
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::Mutex;

static DB: Mutex<Option<Database>> = Mutex::new(None);

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("build tokio runtime")
    })
}

unsafe fn cstr<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        return "";
    }
    CStr::from_ptr(p).to_str().unwrap_or("")
}

#[derive(Serialize)]
struct CResult {
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
}

fn to_c(res: &CResult) -> *mut c_char {
    let s = serde_json::to_string(res)
        .unwrap_or_else(|_| r#"{"ok":false,"result":null,"error":"serialize error"}"#.to_string());
    CString::new(s).ok().map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

fn ok(v: Value) -> *mut c_char {
    to_c(&CResult { ok: true, result: Some(v), error: None })
}

fn ok_unit() -> *mut c_char {
    ok(Value::Null)
}

fn err(e: impl ToString) -> *mut c_char {
    to_c(&CResult { ok: false, result: None, error: Some(e.to_string()) })
}

fn with_db<T>(f: impl FnOnce(&Database) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let guard = DB.lock().unwrap();
    match guard.as_ref() {
        Some(db) => f(db),
        None => anyhow::bail!("database not opened — call larp_db_open first"),
    }
}

fn track_from_json(text: &str) -> anyhow::Result<api::Track> {
    serde_json::from_str::<api::Track>(text).map_err(|e| anyhow::anyhow!("bad track json: {e}"))
}

/// Массив треков в JSON.
fn tracks_to_value(tracks: Vec<api::Track>) -> Value {
    Value::Array(tracks.iter().map(|t| serde_json::to_value(t).unwrap_or(Value::Null)).collect())
}

fn val_or_err<T>(res: anyhow::Result<T>) -> *mut c_char
where
    T: Serialize,
{
    match res {
        Ok(v) => ok(serde_json::to_value(v).unwrap_or(Value::Null)),
        Err(e) => err(e),
    }
}

// ================= search =================

/// source: "yandex" | "soundcloud" | "ytmusic"
#[allow(clippy::not_unsafe_ptr_arg_deref)]
#[no_mangle]
pub extern "C" fn larp_search(source: *const c_char, query: *const c_char, token: *const c_char) -> *mut c_char {
    let query = unsafe { cstr(query) };
    let token = unsafe { cstr(token) };
    let src = unsafe { cstr(source) };

    let result = match api::Source::from_str(src) {
        Some(api::Source::YandexMusic) => runtime().block_on(api::search_yandex(query, token)),
        Some(api::Source::SoundCloud) => runtime().block_on(api::search_soundcloud(query)),
        Some(api::Source::YouTubeMusic) => runtime().block_on(api::search_ytmusic(query)),
        None => return err("unknown source"),
    };

    match result {
        Ok(tracks) => ok(tracks_to_value(tracks)),
        Err(e) => err(e),
    }
}

#[no_mangle]
pub extern "C" fn larp_yandex_download_url(track_id: *const c_char, token: *const c_char) -> *mut c_char {
    let track_id = unsafe { cstr(track_id) };
    let token = unsafe { cstr(token) };
    val_or_err(runtime().block_on(api::get_yandex_download_url(track_id, token)))
}

// ================= db =================

/// dir — куда класть larp.db (например Documents на iOS)
#[no_mangle]
pub extern "C" fn larp_db_open(db_dir: *const c_char) -> *mut c_char {
    let dir = unsafe { cstr(db_dir) };
    if dir.is_empty() {
        return err("empty db_dir");
    }
    let path = PathBuf::from(dir).join("larp.db");
    match Database::open_at(&path) {
        Ok(db) => {
            *DB.lock().unwrap() = Some(db);
            ok_unit()
        }
        Err(e) => err(e),
    }
}

#[no_mangle]
pub extern "C" fn larp_db_get_liked() -> *mut c_char {
    match with_db(|db| db.get_liked()) {
        Ok(tracks) => ok(tracks_to_value(tracks)),
        Err(e) => err(e),
    }
}

/// track_json — JSON трека (id, title, artist, source, ...)
#[no_mangle]
pub extern "C" fn larp_db_like(track_json: *const c_char) -> *mut c_char {
    let text = unsafe { cstr(track_json) };
    match track_from_json(text).and_then(|t| with_db(|db| db.like_track(&t))) {
        Ok(()) => ok_unit(),
        Err(e) => err(e),
    }
}

#[no_mangle]
pub extern "C" fn larp_db_unlike(source: *const c_char, track_id: *const c_char) -> *mut c_char {
    let src = unsafe { cstr(source) };
    let id = unsafe { cstr(track_id) };
    match api::Source::from_str(src) {
        Some(s) => match with_db(|db| db.unlike_track(&s, id)) {
            Ok(()) => ok_unit(),
            Err(e) => err(e),
        },
        None => err("unknown source"),
    }
}

#[no_mangle]
pub extern "C" fn larp_db_is_liked(source: *const c_char, track_id: *const c_char) -> *mut c_char {
    let src = unsafe { cstr(source) };
    let id = unsafe { cstr(track_id) };
    match api::Source::from_str(src) {
        Some(s) => val_or_err(with_db(|db| db.is_liked(&s, id))),
        None => err("unknown source"),
    }
}

// ================= playlists =================

#[no_mangle]
pub extern "C" fn larp_playlist_create(name: *const c_char) -> *mut c_char {
    let name = unsafe { cstr(name) };
    if name.trim().is_empty() {
        return err("empty playlist name");
    }
    match with_db(|db| db.create_playlist(name)) {
        Ok(id) => ok(json!({ "id": id })),
        Err(e) => err(e),
    }
}

#[no_mangle]
pub extern "C" fn larp_playlist_list() -> *mut c_char {
    match with_db(|db| db.get_playlists()) {
        Ok(pls) => ok(Value::Array(
            pls.iter().map(|p| json!({ "id": p.id, "name": p.name, "count": p.count })).collect(),
        )),
        Err(e) => err(e),
    }
}

#[no_mangle]
pub extern "C" fn larp_playlist_tracks(id: i64) -> *mut c_char {
    match with_db(|db| db.get_playlist_tracks(id)) {
        Ok(tracks) => ok(tracks_to_value(tracks)),
        Err(e) => err(e),
    }
}

/// track_json — JSON трека
#[no_mangle]
pub extern "C" fn larp_playlist_add(id: i64, track_json: *const c_char) -> *mut c_char {
    let text = unsafe { cstr(track_json) };
    match track_from_json(text).and_then(|t| with_db(|db| db.add_to_playlist(id, &t))) {
        Ok(()) => ok_unit(),
        Err(e) => err(e),
    }
}

#[no_mangle]
pub extern "C" fn larp_playlist_remove(id: i64, source: *const c_char, track_id: *const c_char) -> *mut c_char {
    let src = unsafe { cstr(source) };
    let tid = unsafe { cstr(track_id) };
    match api::Source::from_str(src) {
        Some(s) => match with_db(|db| db.remove_from_playlist(id, &s, tid)) {
            Ok(()) => ok_unit(),
            Err(e) => err(e),
        },
        None => err("unknown source"),
    }
}

#[no_mangle]
pub extern "C" fn larp_playlist_delete(id: i64) -> *mut c_char {
    match with_db(|db| db.delete_playlist(id)) {
        Ok(()) => ok_unit(),
        Err(e) => err(e),
    }
}

// ================= misc =================

#[no_mangle]
pub extern "C" fn larp_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[no_mangle]
pub extern "C" fn larp_version() -> *const c_char {
    b"larp-core-0.1.0\0".as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(res: *mut c_char) -> String {
        let s = unsafe { CStr::from_ptr(res) }.to_string_lossy().into_owned();
        unsafe { drop(CString::from_raw(res)) };
        s
    }

    #[test]
    fn ffi_db_roundtrip() {
        let dir = std::env::temp_dir().join(format!("larp-ffi-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        let res = read(larp_db_open(dir_c.as_ptr()));
        assert!(res.contains("\"ok\":true"), "{res}");
        drop(dir_c);

        let track = json!({
            "id": "abc",
            "title": "Title",
            "artist": "Artist",
            "source": "ytmusic",
            "durationMs": 123000
        });
        let t = CString::new(serde_json::to_string(&track).unwrap()).unwrap();
        let res = read(larp_db_like(t.as_ptr()));
        assert!(res.contains("\"ok\":true"), "{res}");
        drop(t);

        let res = read(larp_db_get_liked());
        assert!(res.contains("abc"), "{res}");
        assert!(res.contains("ytmusic"), "{res}");

        let src = CString::new("ytmusic").unwrap();
        let id = CString::new("abc").unwrap();
        let res = read(larp_db_is_liked(src.as_ptr(), id.as_ptr()));
        assert!(res.contains("\"result\":true"), "{res}");
        drop(src);
        drop(id);

        let name = CString::new("pl").unwrap();
        let res = read(larp_playlist_create(name.as_ptr()));
        assert!(res.contains("\"ok\":true"), "{res}");
        let v: Value = serde_json::from_str(&res).unwrap();
        let pl_id = v["result"]["id"].as_i64().unwrap();
        drop(name);

        let res = read(larp_playlist_list());
        assert!(res.contains("pl"), "{res}");

        let t = CString::new(serde_json::to_string(&track).unwrap()).unwrap();
        let res = read(larp_playlist_add(pl_id, t.as_ptr()));
        assert!(res.contains("\"ok\":true"), "{res}");
        drop(t);

        let res = read(larp_playlist_tracks(pl_id));
        assert!(res.contains("abc"), "{res}");

        let src = CString::new("ytmusic").unwrap();
        let id = CString::new("abc").unwrap();
        let res = read(larp_playlist_remove(pl_id, src.as_ptr(), id.as_ptr()));
        assert!(res.contains("\"ok\":true"), "{res}");
        drop(src);
        drop(id);

        let res = read(larp_playlist_delete(pl_id));
        assert!(res.contains("\"ok\":true"), "{res}");
    }

    #[test]
    fn ffi_version() {
        let v = unsafe { CStr::from_ptr(larp_version()) }.to_string_lossy();
        assert!(v.contains("larp-core"));
    }
}