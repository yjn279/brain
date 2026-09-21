-- brain schema for Turso (libSQL).
-- Bipartite graph: urls <-> tags, joined by has_tag. Visits are append-only events.
-- All timestamps are unix milliseconds.

PRAGMA foreign_keys = ON;

-- URL ledger. One row per distinct URL ever seen.
CREATE TABLE urls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL UNIQUE,
  title TEXT,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);
CREATE INDEX idx_urls_last_seen ON urls(last_seen);

-- Tag dictionary. Names are lowercased and deduplicated by the ingest run.
CREATE TABLE tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);

-- The only edge in the graph. One URL carries many tags; one tag spans many URLs.
-- source is part of the key so a user tag never overwrites the model's, and vice versa.
CREATE TABLE has_tag (
  url_id INTEGER NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  source TEXT NOT NULL CHECK(source IN ('llm', 'user')),
  confidence REAL NOT NULL DEFAULT 1.0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (url_id, tag_id, source)
);
CREATE INDEX idx_has_tag_tag ON has_tag(tag_id);

-- Visit events. One URL accumulates many visits over time.
-- The UNIQUE constraint makes re-ingesting an overlapping window a no-op.
CREATE TABLE visits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url_id INTEGER NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
  visited_at INTEGER NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('chrome', 'youtube')),
  UNIQUE (url_id, visited_at, source)
);
CREATE INDEX idx_visits_url_time ON visits(url_id, visited_at);

-- Ingest cursor. One row per source, holding the high-water mark of the last run.
CREATE TABLE ingest_state (
  source TEXT PRIMARY KEY,
  last_run_at INTEGER NOT NULL
);
