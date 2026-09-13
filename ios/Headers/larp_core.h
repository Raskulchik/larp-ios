#ifndef LARP_CORE_H
#define LARP_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * larp-core — небольшое Rust-ядро для Larpi (iOS).
 * Все функции, возвращающие `char*`, отдают JSON вида:
 *   {"ok": true,  "result": <...>}
 *   {"ok": false, "result": null, "error": "текст ошибки"}
 * и должны быть освобождены через larp_free().
 *
 * Трек в JSON (точь-в-точь сериализуется из Rust):
 *   {"id":"...","title":"...","artist":"...","source":"yandex|soundcloud|ytmusic",
 *    "previewUrl":...?, "artworkUrl":...?, "durationMs":...?}
 */

// Поиск треков. source: "yandex" | "soundcloud" | "ytmusic".
// yandex_token обязателен только для "yandex".
char* larp_search(const char* source, const char* query, const char* yandex_token);

// Получить прямую ссылку на скачивание трека Yandex Music.
char* larp_yandex_download_url(const char* track_id, const char* yandex_token);

// Открыть/создать БД в директории (туда ляжет larp.db). На iOS — Documents.
char* larp_db_open(const char* db_dir);

char* larp_db_get_liked(void);
char* larp_db_like(const char* track_json);
char* larp_db_unlike(const char* source, const char* track_id);
char* larp_db_is_liked(const char* source, const char* track_id);

char* larp_playlist_create(const char* name);
char* larp_playlist_list(void);
char* larp_playlist_tracks(int64_t id);
char* larp_playlist_add(int64_t id, const char* track_json);
char* larp_playlist_remove(int64_t id, const char* source, const char* track_id);
char* larp_playlist_delete(int64_t id);

// Освободить строку, возвращённую выше.
void larp_free(char* ptr);

// Статическая строка версии (освобождать НЕ нужно).
const char* larp_version(void);

#ifdef __cplusplus
}
#endif

#endif // LARP_CORE_H