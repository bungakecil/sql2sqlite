# sql2sqlite

Convert a `mysqldump` / `mariadb-dump` SQL file into a real SQLite database —
schema, data, indexes, foreign keys and views — with byte-exact data.

```
sql2sqlite dump.sql > converted.sqlite
sql2sqlite dump.sql -o converted.sqlite
```

## Why

The usual workarounds — the `mysql2sqlite` AWK script, or a pipeline of `sed`
rewrites — do line-based regex substitution, and realistic dumps break them:

- a semicolon inside `'it\'s; complicated'` splits the statement in the wrong place
- `_binary '…'` and `0x…` blob literals silently become text
- MySQL's `\0`, `\Z` and `\b` escapes survive verbatim into the output
- `KEY` clauses inside `CREATE TABLE` are simply not valid SQLite

`sql2sqlite` parses instead. Input is a byte stream — never round-tripped
through `String`, so latin1 and otherwise invalid UTF-8 survive untouched — and
every value is decoded into a typed value and bound through a prepared
statement. Row data is never re-emitted as SQL text, which eliminates a whole
class of escaping bugs by construction.

## Build

Requires Swift 6.0+ and the SQLite development headers.

| Platform | Package |
|---|---|
| Debian / Ubuntu | `libsqlite3-dev` |
| Fedora / RHEL | `sqlite-devel` |
| macOS (Homebrew) | `sqlite3` |

```bash
swift build -c release
swift test
.build/release/sql2sqlite --help
```

## Usage

```
sql2sqlite [options] [<file.sql>]      # "-" or omitted reads stdin

  -o, --output <path>   write the database directly to path
      --strict          treat warnings as errors
      --quiet           suppress per-warning output (the summary is still shown)
      --schema-only     skip INSERT statements
      --data-only       skip DDL (target tables must already exist)
      --check-fk        run PRAGMA foreign_key_check at the end
      --batch-size <n>  rows per transaction (default 100000)
      --version, --help
```

Diagnostics and the end-of-run summary go to **stderr**, because stdout carries
database bytes.

SQLite needs a seekable file descriptor and cannot write into a pipe, so the
stdout form builds the database in a temp file under `TMPDIR` and streams it to
fd 1 afterwards. Peak disk use is roughly 2× the database size; `-o` avoids that
entirely and is the better choice for large dumps. Writing to a terminal is
refused rather than spraying binary at your session.

## Container

```bash
podman build -t sql2sqlite:latest .
podman images sql2sqlite            # ~90-120 MB, thanks to --static-swift-stdlib

cp dump.sql data/
podman run --rm -v ./data:/data sql2sqlite:latest dump.sql -o converted.sqlite

# The `>` form works with plain run (no -t):
podman run --rm -v ./data:/data sql2sqlite:latest dump.sql > data/converted.sqlite
```

Docker is interchangeable with podman throughout.

**Under compose, use `-o`.** `compose run` does not redirect the way `>` does:
the shell redirect happens on the host while the process writes inside the
container.

```bash
docker compose run --rm sql2sqlite dump.sql -o converted.sqlite
```

**No compose implementation is installed on this machine.** `podman compose`
fails until you install one — `pip install podman-compose`, or your distro's
package.

**Rootless podman file ownership.** Output lands owned by a mapped UID. Add
`--userns=keep-id` to `podman run`, or `user: "${UID}:${GID}"` in compose.

**SELinux hosts** need a relabel flag on the mount: `./data:/data:z`.

## What gets skipped

Each of these emits a warning naming the construct, and the conversion
continues. `--strict` turns the first warning into a fatal error instead.

- triggers, stored procedures, stored functions and events
- `FULLTEXT` and `SPATIAL` indexes
- index prefix lengths (`KEY (name(10))` indexes the whole value)
- collations other than `*_ci` (→ `NOCASE`) and `*_bin` (→ `BINARY`)
- `ON UPDATE CURRENT_TIMESTAMP`
- function column defaults with no SQLite equivalent (e.g. `uuid()`)
- partitioning, users and grants
- `LOAD DATA INFILE`, and `mysqldump --tab` / `--xml` output
- MySQL-specific functions inside view or generated-column expressions, which
  are passed through unchanged and may not resolve

## Known conversion caveats

- **`DECIMAL` is declared `NUMERIC`.** This keeps the column queryable and
  comparable, at the cost of precision: `DECIMAL(10,2)` `1.50` reads back as
  `1.5`, and decimals wider than a double lose precision. Storing them as `TEXT`
  would be exact but would break every numeric comparison, so this was a
  deliberate trade.
- **`BIGINT UNSIGNED` above 2^63−1 becomes a double.** SQLite has no unsigned
  64-bit integer. A one-time warning fires the first time it happens.
- **A `UNIQUE KEY` over duplicate data is skipped with a warning**, not treated
  as fatal — the conversion still succeeds and exits 0. MySQL and SQLite differ
  on what counts as a duplicate (collation, trailing-space handling), so this
  is common in practice and rarely a reason to throw the whole run away.
- **Dates are `TEXT`.** ISO-8601-shaped values keep sorting and comparing
  correctly, and SQLite's date functions accept them.
- **Multi-database dumps are flattened into one namespace.** `USE` statements
  are ignored, and a duplicate table name across databases is a hard error.
- **Index names are prefixed with their table.** SQLite index names are
  schema-global while MySQL's are per-table, so `KEY idx_name` on table `posts`
  becomes `posts_idx_name`; remaining collisions get a `_2`, `_3` suffix.
- **`AUTO_INCREMENT` becomes `AUTOINCREMENT` only on a lone INTEGER PRIMARY
  KEY**, the one shape SQLite permits. Anything else drops it with a warning.
- **Generated columns are recomputed, not copied.** `STORED` and `VIRTUAL`
  columns keep their expression, and SQLite computes their values, so any value
  the dump supplies for a generated column is discarded. An `INSERT` without a
  column list may supply either every column in table order, generated ones
  included (what mysqldump writes), or only the writable columns. The first
  tuple's width picks the layout, and every later tuple in that statement must
  match it; any other width is an error, never padded or truncated. An explicit
  column list keeps its positions, and entries naming generated columns are
  skipped.
- **Indexes are created after the data loads**, and views after that, in
  repeated passes so view-on-view dependencies resolve whatever order the dump
  declared them in.
- **Function defaults collapse to SQLite bare keywords.** MySQL datetime functions
  (`NOW()`, `CURRENT_TIMESTAMP(6)`, `CURDATE()`, `CURTIME()`) map to SQLite's
  `CURRENT_TIMESTAMP`, `CURRENT_DATE`, and `CURRENT_TIME`, losing any sub-second
  precision argument. Furthermore, SQLite evaluates `CURRENT_TIMESTAMP` in **UTC**,
  whereas MySQL's `NOW()` uses the session time zone, so such a column may shift by
  the server's offset; `UTC_TIMESTAMP()` maps identically. A `NOT NULL` column whose
  function default was dropped (e.g. `DEFAULT uuid()`) still loads fine because dump
  `INSERT`s supply every column, but subsequent inserts that omit the column will fail
  the `NOT NULL` constraint. Complex compound expressions such as
  `DEFAULT (now() + interval 1 day)` are not decomposed and remain passed through.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success — warnings are allowed |
| `1` | conversion error |
| `2` | usage error |
