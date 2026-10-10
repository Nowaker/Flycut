CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events(
    ingest_seq INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE, device_id TEXT NOT NULL, clock INTEGER NOT NULL,
    op TEXT NOT NULL, item_id TEXT NOT NULL, json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS items(
    item_id TEXT PRIMARY KEY, payload TEXT,
    create_clock INTEGER NOT NULL DEFAULT 0,
    create_device TEXT NOT NULL DEFAULT '', create_event TEXT NOT NULL DEFAULT '',
    favorite INTEGER NOT NULL DEFAULT 0, favorite_clock INTEGER NOT NULL DEFAULT 0,
    favorite_device TEXT NOT NULL DEFAULT '', favorite_event TEXT NOT NULL DEFAULT '',
    recent_clock INTEGER NOT NULL DEFAULT 0,
    recent_device TEXT NOT NULL DEFAULT '', recent_event TEXT NOT NULL DEFAULT '',
    deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS items_recent ON items(
    recent_clock DESC, recent_device DESC, recent_event DESC, item_id DESC
);
CREATE TABLE IF NOT EXISTS checkpoints(backend TEXT PRIMARY KEY, uploaded INTEGER NOT NULL, cursor TEXT NOT NULL);
