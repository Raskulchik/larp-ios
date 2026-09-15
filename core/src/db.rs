use rusqlite::{Connection, params};
use std::path::Path;
use crate::api::{Source, Track};

#[derive(Debug, Clone, serde::Serialize)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub count: usize,
}

pub struct Database {
    conn: Connection,
}

fn source_str(source: &Source) -> &'static str {
    source.as_str()
}

fn source_from_str(s: &str) -> Source {
    Source::from_str(s).unwrap_or(Source::YouTubeMusic)
}

impl Database {
    pub fn open_at(path: &Path) -> anyhow::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS liked (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                track_id TEXT NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                artwork_url TEXT,
                duration_ms INTEGER,
                preview_url TEXT,
                liked_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(source, track_id)
            );

            CREATE TABLE IF NOT EXISTS playlists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS playlist_tracks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                playlist_id INTEGER NOT NULL,
                source TEXT NOT NULL,
                track_id TEXT NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                artwork_url TEXT,
                duration_ms INTEGER,
                preview_url TEXT,
                position INTEGER NOT NULL,
                FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
                UNIQUE(playlist_id, source, track_id)
            );"
        )?;

        Ok(Self { conn })
    }

    pub fn like_track(&self, track: &Track) -> anyhow::Result<()> {
        self.conn.execute(
            "INSERT INTO liked (source, track_id, title, artist, artwork_url, duration_ms, preview_url)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(source, track_id) DO UPDATE SET
               title = excluded.title,
               artist = excluded.artist,
               artwork_url = excluded.artwork_url,
               duration_ms = excluded.duration_ms,
               preview_url = excluded.preview_url
             ",
            params![
                source_str(&track.source),
                track.id,
                track.title,
                track.artist,
                track.artwork_url,
                track.duration_ms.map(|d| d as i64),
                track.preview_url,
            ],
        )?;
        Ok(())
    }

    pub fn unlike_track(&self, source: &Source, track_id: &str) -> anyhow::Result<()> {
        self.conn.execute(
            "DELETE FROM liked WHERE source = ?1 AND track_id = ?2",
            params![source_str(source), track_id],
        )?;
        Ok(())
    }

    pub fn is_liked(&self, source: &Source, track_id: &str) -> anyhow::Result<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM liked WHERE source = ?1 AND track_id = ?2",
            params![source_str(source), track_id],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn get_liked(&self) -> anyhow::Result<Vec<Track>> {
        let mut stmt = self.conn.prepare(
            "SELECT source, track_id, title, artist, artwork_url, duration_ms, preview_url FROM liked ORDER BY liked_at DESC"
        )?;

        let tracks = stmt.query_map([], |row| {
            let source_str: String = row.get(0)?;
            Ok(Track {
                id: row.get(1)?,
                title: row.get(2)?,
                artist: row.get(3)?,
                source: source_from_str(&source_str),
                artwork_url: row.get(4)?,
                duration_ms: row.get::<_, Option<i64>>(5)?.map(|d| d as u64),
                preview_url: row.get(6)?,
                album: None,
                year: None,
            })
        })?.collect::<Result<Vec<_>, _>>()?;

        Ok(tracks)
    }

    pub fn create_playlist(&self, name: &str) -> anyhow::Result<i64> {
        self.conn.execute(
            "INSERT INTO playlists (name) VALUES (?1)",
            params![name],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn get_playlists(&self) -> anyhow::Result<Vec<Playlist>> {
        let mut stmt = self.conn.prepare(
            "SELECT p.id, p.name,
                    (SELECT COUNT(*) FROM playlist_tracks pt WHERE pt.playlist_id = p.id) AS cnt
             FROM playlists p ORDER BY p.created_at DESC"
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Playlist {
                id: row.get(0)?,
                name: row.get(1)?,
                count: row.get::<_, i64>(2)? as usize,
            })
        })?.collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn delete_playlist(&self, id: i64) -> anyhow::Result<()> {
        self.conn.execute("DELETE FROM playlists WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn add_to_playlist(&self, playlist_id: i64, track: &Track) -> anyhow::Result<()> {
        let pos: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?1",
            params![playlist_id],
            |row| row.get(0),
        )?;
        self.conn.execute(
            "INSERT OR IGNORE INTO playlist_tracks
             (playlist_id, source, track_id, title, artist, artwork_url, duration_ms, preview_url, position)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                playlist_id,
                source_str(&track.source),
                track.id,
                track.title,
                track.artist,
                track.artwork_url,
                track.duration_ms.map(|d| d as i64),
                track.preview_url,
                pos,
            ],
        )?;
        Ok(())
    }

    pub fn remove_from_playlist(&self, playlist_id: i64, source: &Source, track_id: &str) -> anyhow::Result<()> {
        self.conn.execute(
            "DELETE FROM playlist_tracks WHERE playlist_id = ?1 AND source = ?2 AND track_id = ?3",
            params![playlist_id, source_str(source), track_id],
        )?;
        Ok(())
    }

    pub fn get_playlist_tracks(&self, playlist_id: i64) -> anyhow::Result<Vec<Track>> {
        let mut stmt = self.conn.prepare(
            "SELECT source, track_id, title, artist, artwork_url, duration_ms, preview_url
             FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position ASC"
        )?;
        let tracks = stmt.query_map(params![playlist_id], |row| {
            let source_str: String = row.get(0)?;
            Ok(Track {
                id: row.get(1)?,
                title: row.get(2)?,
                artist: row.get(3)?,
                source: source_from_str(&source_str),
                artwork_url: row.get(4)?,
                duration_ms: row.get::<_, Option<i64>>(5)?.map(|d| d as u64),
                preview_url: row.get(6)?,
                album: None,
                year: None,
            })
        })?.collect::<Result<Vec<_>, _>>()?;
        Ok(tracks)
    }
}

/// Вспомогательный путь для тестов (временная папка).
#[cfg(test)]
pub fn temp_db_path(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("larp-core-test-{}", std::process::id()));
    dir.join(format!("{}.db", name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn like_and_playlist_crud() {
        let path = temp_db_path("t1");
        let _ = std::fs::remove_file(&path);
        let db = Database::open_at(&path).expect("open db");

        let track = Track {
            id: "video-id".to_string(),
            title: "Song".to_string(),
            artist: "Artist".to_string(),
            source: Source::YouTubeMusic,
            preview_url: None,
            artwork_url: None,
            duration_ms: Some(120_000),
            album: None,
            year: None,
        };

        db.like_track(&track).expect("like");
        assert!(db.is_liked(&track.source, &track.id).expect("is_liked"));
        assert_eq!(db.get_liked().expect("liked").len(), 1);
        db.unlike_track(&track.source, &track.id).expect("unlike");
        assert!(!db.is_liked(&track.source, &track.id).expect("not liked"));

        let pl_id = db.create_playlist("Test").expect("create playlist");
        db.add_to_playlist(pl_id, &track).expect("add");
        db.add_to_playlist(pl_id, &track).expect("add dup");
        assert_eq!(db.get_playlist_tracks(pl_id).expect("tracks").len(), 1);

        let pls = db.get_playlists().expect("playlists");
        assert!(pls.iter().any(|p| p.id == pl_id && p.count == 1));

        let track_same = Track {
            id: "video-id2".to_string(),
            title: "Song 2".to_string(),
            artist: "Artist".to_string(),
            source: Source::YouTubeMusic,
            preview_url: None,
            artwork_url: None,
            duration_ms: None,
            album: None,
            year: None,
        };
        db.add_to_playlist(pl_id, &track_same).expect("add 2");
        assert_eq!(db.get_playlist_tracks(pl_id).expect("tracks 2").len(), 2);

        db.remove_from_playlist(pl_id, &track.source, &track.id).expect("remove");
        assert_eq!(db.get_playlist_tracks(pl_id).expect("tracks 3").len(), 1);

        db.delete_playlist(pl_id).expect("delete");
        assert!(!db.get_playlists().expect("list").iter().any(|p| p.id == pl_id));

        let _ = std::fs::remove_file(&path);
    }
}