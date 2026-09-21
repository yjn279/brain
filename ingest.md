# Ingest

Read today's browsing history from Chrome and YouTube, tag each new URL, and append the
result to the brain-graph database in Turso. This prompt runs unattended once a day as a
Claude Code Desktop Scheduled Task, so it must complete without asking any questions.

## Contract

The run does exactly three things: it reads two history pages through the Claude in Chrome
extension, it derives tags for URLs that are new since the last cursor, and it appends rows
to Turso. It writes nothing back to the browser, deletes nothing from the database, and
touches no file in this repository.

Failure is loud and non-destructive. If any step fails, stop and let the error surface
rather than substituting a default or skipping ahead. Because the cursor advances only
after a successful write, the next run re-reads the same window and reprocesses it safely.
Every insert below is idempotent, so a partial run costs nothing but repeated work.

## Credentials

Load the database endpoint and token from `~/.config/brain-graph/env`, which lives outside
the repository and is never committed. Read it with Bash at the start of the run.

```shell
set -a && . "$HOME/.config/brain-graph/env" && set +a
```

The file defines `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN`. If either is empty, stop
immediately and report the missing variable. Never echo the token, never write it to a
file, and never include it in the run summary.

## Steps

Follow these in order. Each step depends on the one before it.

1. Read the cursor. Query `SELECT source, last_run_at FROM ingest_state` and keep the value
   per source. When a source has no row, use `now - 24h` as its starting point. Call this
   value `since` for the rest of the run.
2. Read Chrome history. Open `chrome://history/` with
   `mcp__claude-in-chrome__navigate`, then extract the visible rows with
   `mcp__claude-in-chrome__get_page_text`. Keep only entries newer than `since`. The list
   scrolls infinitely, so stop after `200` entries even if older rows remain.
3. Read YouTube history. Open `https://www.youtube.com/feed/history` the same way and
   extract watched videos newer than `since`, under the same `200` entry cap.
4. Filter. Drop every URL matching the exclusion patterns below before it reaches the model
   or the database.
5. Derive tags. For each surviving URL, infer `3` to `8` topical tags from its title and
   URL. Tags are lowercase English noun phrases describing subject matter, not format or
   sentiment. Return strict JSON and nothing else: `{"tags": ["...", "..."]}`.
6. Write. Execute the statements in the section below against the Turso HTTP API.
7. Advance the cursor. Upsert `ingest_state` for each source with the current unix
   milliseconds, but only after the writes of step 6 succeeded.
8. Report. Print the number of URLs, visits, and tag edges added, then exit. A run that
   finds nothing new prints zeros and still counts as success.

## Exclusions

Browsing history mixes ordinary reading with authenticated sessions and private matters.
Skip any URL matching these patterns, and never send a skipped URL or its title to the
model.

| Pattern | Reason |
| :-- | :-- |
| `localhost`, `127.0.0.1`, `*.local`, private IP ranges | Local development, not reading |
| Any URL carrying `token`, `access_token`, `code`, `session`, `key`, `password`, `signature` in its query | Credentials leak through query strings |
| `*/login*`, `*/signin*`, `*/oauth*`, `*/auth/*`, `*/sso*`, `*/reset-password*` | Authentication flows |
| `mail.google.com`, `*/inbox*`, `*/messages*`, `web.whatsapp.com` | Private correspondence |
| Banking, brokerage, insurance, and payment domains | Financial records |
| `*/health*`, `*/medical*`, clinic and pharmacy domains | Medical information |
| `chrome://*`, `chrome-extension://*`, `file://*`, `about:*` | Browser internals, not content |

Strip the query string and fragment from every URL that survives, keeping scheme, host, and
path. This removes tracking parameters and session identifiers that the patterns above
would otherwise have to enumerate.

## Database

Turso speaks HTTP at the same host as the libSQL URL, with a different scheme. Take
`TURSO_DATABASE_URL`, replace the leading `libsql://` with `https://`, and append
`/v2/pipeline`. Authenticate with a bearer token.

```shell
curl -sS -X POST "${TURSO_DATABASE_URL/libsql:\/\//https://}/v2/pipeline" \
  -H "Authorization: Bearer ${TURSO_AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  --fail-with-body \
  -d @request.json
```

The body holds a list of requests ending in a `close`. Bind every value as an argument
rather than interpolating it into the SQL, so that titles containing quotes cannot break
the statement.

```json
{
  "requests": [
    {
      "type": "execute",
      "stmt": {
        "sql": "INSERT INTO urls (url, title, first_seen, last_seen) VALUES (?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET last_seen = excluded.last_seen, title = COALESCE(excluded.title, urls.title)",
        "args": [
          { "type": "text", "value": "https://example.com/article" },
          { "type": "text", "value": "An article" },
          { "type": "integer", "value": "1774400000000" },
          { "type": "integer", "value": "1774400000000" }
        ]
      }
    },
    { "type": "close" }
  ]
}
```

Write the four statements below in this order, once per URL. The upsert on `urls` keeps
`last_seen` current, which the plain insert-or-ignore of a first draft would have left
stale. `visits` and `has_tag` ignore duplicates, so reprocessing a window changes nothing.

| Target | Statement |
| :-- | :-- |
| `urls` | `INSERT INTO urls (url, title, first_seen, last_seen) VALUES (?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET last_seen = excluded.last_seen, title = COALESCE(excluded.title, urls.title)` |
| `tags` | `INSERT INTO tags (name) VALUES (?) ON CONFLICT(name) DO NOTHING` |
| `visits` | `INSERT OR IGNORE INTO visits (url_id, visited_at, source) VALUES ((SELECT id FROM urls WHERE url = ?), ?, ?)` |
| `has_tag` | `INSERT OR REPLACE INTO has_tag (url_id, tag_id, source, confidence, created_at) VALUES ((SELECT id FROM urls WHERE url = ?), (SELECT id FROM tags WHERE name = ?), 'llm', ?, ?)` |

Advance the cursor with an upsert, because the row does not exist on the first run and a
bare `UPDATE` would silently match nothing and leave the cursor behind forever.

```sql
INSERT INTO ingest_state (source, last_run_at) VALUES (?, ?)
  ON CONFLICT(source) DO UPDATE SET last_run_at = excluded.last_run_at;
```
