# Ingest

Read today's browsing from Chrome and YouTube, tag each new URL, and append the result to
the brain database in Turso. This prompt runs unattended once a day as a Claude Code
Desktop Scheduled Task, so it must complete without asking any questions.

## Contract

The run reads two sources by two different means, because they are not equally reachable.
Chrome history comes from the local history database on disk, since the `chrome://history/`
page cannot be opened or read by a browser extension and shows only titles and domains
rather than full URLs. YouTube history comes from the signed-in web page through the Claude
in Chrome extension, which is the only place that data exists.

From there the run derives tags for URLs newer than the last cursor and appends rows to
Turso. It writes nothing back to the browser, deletes nothing from the database, and
touches no file in this repository.

Failure is loud and non-destructive. If any step fails, stop and let the error surface
rather than substituting a default or skipping ahead. Because the cursor advances only
after a successful write, the next run re-reads the same window and reprocesses it safely.
Every insert below is idempotent, so a partial run costs nothing but repeated work.

## Credentials

Load the database endpoint and token from `~/.config/brain/env`, which lives outside
the repository and is never committed. Read it with Bash at the start of the run.

```shell
set -a && . "$HOME/.config/brain/env" && set +a
```

The file defines `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN`. If either is empty, stop
immediately and report the missing variable. Never echo the token, never write it to a
file, and never include it in the run summary.

## Steps

Follow these in order. Each step depends on the one before it.

1. Read the cursor. Query `SELECT source, last_run_at FROM ingest_state` and keep the value
   per source. When a source has no row, use `now - 24h` as its starting point. Call this
   value `since` for the rest of the run.
2. Read Chrome history from disk, as described in the section below. Keep visits newer than
   `since`, and stop after `200` rows.
3. Read YouTube history. Open `https://www.youtube.com/feed/history` with
   `mcp__claude-in-chrome__navigate`, then extract the page with
   `mcp__claude-in-chrome__read_page` using `filter: "all"`. The `interactive` filter
   returns only the navigation sidebar, and `get_page_text` returns nothing at all, because
   the page renders entirely in JavaScript. Collect `link` elements whose `href` contains
   `/watch?v=`, taking the link text as the title. Stop after `200` entries.
4. Date the YouTube entries. The page groups videos under day headings such as 今日 or
   昨日 rather than exact times, so use the start of that day in local time, expressed in
   unix milliseconds, as `visited_at`. A fixed value per day keeps the same watch
   deduplicating against itself on every later run; the current clock time would not.
5. Filter. Drop every URL matching the exclusion patterns below before it reaches the model
   or the database.
6. Derive tags. For each surviving URL, infer `3` to `8` topical tags from its title and
   URL. Tags are lowercase English noun phrases describing subject matter, not format or
   sentiment. Return strict JSON and nothing else: `{"tags": ["...", "..."]}`.
7. Write. Execute the statements in the Database section against the Turso HTTP API.
8. Advance the cursor. Upsert `ingest_state` for each source with the current unix
   milliseconds, but only after the writes of step 7 succeeded.
9. Report. Print the number of URLs, visits, and tag edges added, then exit. A run that
   finds nothing new prints zeros and still counts as success.

## Chrome

Chrome keeps its history in a SQLite database at
`~/Library/Application Support/Google/Chrome/Default/History`. The running browser holds a
lock on it, so copy the file to a temporary directory, read the copy, and delete it when
the query is done. Never write to the original.

Timestamps there are microseconds since 1601-01-01, not unix milliseconds, so both the
comparison and the result need converting.

```shell
SRC="$HOME/Library/Application Support/Google/Chrome/Default/History"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$SRC" "$TMP/history"
sqlite3 "$TMP/history" "
  SELECT u.url, u.title, v.visit_time / 1000 - 11644473600000 AS visited_at_ms
  FROM visits v JOIN urls u ON u.id = v.url
  WHERE v.visit_time > ($SINCE_MS + 11644473600000) * 1000
  ORDER BY v.visit_time DESC
  LIMIT 200;"
```

Reading this file requires a Bash permission rule, because it holds personal data and is
blocked by default. Grant it once during the first manual run; without it this step fails
and the Chrome half of the graph stays empty.

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
would otherwise have to enumerate. YouTube watch URLs are the one exception: keep the `v`
parameter, since it is the identity of the video rather than a tracking artefact.

## Database

Turso speaks HTTP at the same host as the libSQL URL, with a different scheme. Take
`TURSO_DATABASE_URL`, replace the leading `libsql://` with `https://`, and append
`/v2/pipeline`. Authenticate with a bearer token.

```shell
curl -sS -X POST "${TURSO_DATABASE_URL/libsql:\/\//https://}/v2/pipeline" \
  -H "Authorization: Bearer ${TURSO_AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  --fail-with-body \
  -d @"$TMP/request.json"
```

The body holds a list of requests ending in a `close`. Write it to the temporary directory
created for the Chrome step, never into this repository, because it carries URLs and titles.
Bind every value as an argument rather than interpolating it into the SQL, so that titles
containing quotes cannot break the statement.

```json
{
  "requests": [
    {
      "type": "execute",
      "stmt": {
        "sql": "INSERT INTO urls (url, title, first_seen, last_seen) VALUES (?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET first_seen = MIN(urls.first_seen, excluded.first_seen), last_seen = MAX(urls.last_seen, excluded.last_seen), title = COALESCE(excluded.title, urls.title)",
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

Write the four statements below in this order. Run `urls`, `tags`, and `has_tag` once per
distinct URL, and `visits` once per visit row, since one URL visited three times yields
three visit rows but a single URL row.

The upsert on `urls` takes the minimum of the two `first_seen` values and the maximum of the
two `last_seen` values rather than overwriting. The Chrome query returns visits newest
first, so a plain assignment would walk `last_seen` backwards as older rows of the same URL
arrived. `visits` and `has_tag` ignore duplicates, so reprocessing a window changes
nothing.

| Target | Statement |
| :-- | :-- |
| `urls` | `INSERT INTO urls (url, title, first_seen, last_seen) VALUES (?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET first_seen = MIN(urls.first_seen, excluded.first_seen), last_seen = MAX(urls.last_seen, excluded.last_seen), title = COALESCE(excluded.title, urls.title)` |
| `tags` | `INSERT INTO tags (name) VALUES (?) ON CONFLICT(name) DO NOTHING` |
| `visits` | `INSERT OR IGNORE INTO visits (url_id, visited_at, source) VALUES ((SELECT id FROM urls WHERE url = ?), ?, ?)` |
| `has_tag` | `INSERT OR REPLACE INTO has_tag (url_id, tag_id, source, confidence, created_at) VALUES ((SELECT id FROM urls WHERE url = ?), (SELECT id FROM tags WHERE name = ?), 'llm', ?, ?)` |

Advance the cursor with an upsert, because the row does not exist on the first run and a
bare `UPDATE` would silently match nothing and leave the cursor behind forever.

```sql
INSERT INTO ingest_state (source, last_run_at) VALUES (?, ?)
  ON CONFLICT(source) DO UPDATE SET last_run_at = excluded.last_run_at;
```
