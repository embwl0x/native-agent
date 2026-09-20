# Node.js CLI/runtime corpus — fetch notes

Frozen 2026-09-17. Tool under study: the Node.js CLI / runtime (flags + a few
runtime APIs whose behavior the flags depend on).

## What was fetched

All fetches were plain `curl -sS` against public `nodejs.org` versioned doc
pages. Raw bytes are in `raw/`, unmodified:

| file in `raw/` | URL | bytes |
|---|---|---|
| `v18.20.4_cli.html` | https://nodejs.org/docs/v18.20.4/api/cli.html | 164922 |
| `v18.20.4_fs.html` | https://nodejs.org/docs/v18.20.4/api/fs.html | 647071 |
| `v20.6.0_cli.html` | https://nodejs.org/docs/v20.6.0/api/cli.html | 174133 |
| `v20.6.0_fs.html` | https://nodejs.org/docs/v20.6.0/api/fs.html | 649811 |
| `v20.6.0_sea.html` | https://nodejs.org/docs/v20.6.0/api/single-executable-applications.html | 33362 |
| `v20.19.0_fs.html` | https://nodejs.org/docs/v20.19.0/api/fs.html | 659929 |
| `v22.5.1_cli.html` | https://nodejs.org/docs/v22.5.1/api/cli.html | 228946 |
| `v22.5.1_sqlite.html` | https://nodejs.org/docs/v22.5.1/api/sqlite.html | 41535 |
| `v22.20.0_cli.html` | https://nodejs.org/docs/v22.20.0/api/cli.html | 261276 |
| `v22.20.0_sqlite.html` | https://nodejs.org/docs/v22.20.0/api/sqlite.html | 94866 |
| `v24.8.0_cli.html` | https://nodejs.org/docs/v24.8.0/api/cli.html | 260118 |
| `v24.8.0_sqlite.html` | https://nodejs.org/docs/v24.8.0/api/sqlite.html | 95446 |
| `v24.8.0_process.html` | https://nodejs.org/docs/v24.8.0/api/process.html | 352345 |
| `v24.8.0_sea.html` | https://nodejs.org/docs/v24.8.0/api/single-executable-applications.html | 53261 |
| `v24.8.0_permissions.html` | https://nodejs.org/docs/v24.8.0/api/permissions.html | 29610 |
| `v22.13.0_changelog.md` | https://raw.githubusercontent.com/nodejs/node/main/doc/changelogs/CHANGELOG_V22.md | 872782 |

All returned HTTP 200. Nothing was blocked, rate-limited or paywalled.

## Excerpt extraction

`docs.jsonl` holds 12 excerpts, `N01`–`N12`. Each `text` is the **rendered
text of a contiguous run of the saved HTML** for that URL: tags stripped and
HTML entities unescaped, nothing else. No wording was paraphrased, reordered
or invented.

Two mechanical artifacts of tag-stripping that a reader should know about:

- Doc "History" tables render as `Version` / `Changes` rows on consecutive
  lines. In the excerpts these appear as e.g. `v22.13.0 SQLite is unflagged
  but still experimental.` on one line. That is the table content, not
  invented prose.
- The docs' dual CJS/ESM code tabs render both variants back to back, and a
  `copy` button label sits after code blocks. Where a code block was included
  I kept only one variant's lines and dropped the stray `copy` token; no
  sentence text was altered.

## Explicitly unavailable / not verified

- **`--env-file` quote characters in v20.6.0 (N01).** The v20.6.0 page's HTML
  renders the first allowed quote character as a backslash: `Values can start
  and end with the following quotes: \, " or '.` v22/v24 render it as a
  backtick. The excerpt reproduces v20.6.0 exactly as served. I did **not**
  verify against the running binary which character v20.6.0 actually accepted;
  treat this as a doc-text fact only, not a behavior fact.
- **`node:sqlite` flag requirement is nowhere stated in the `sqlite.html`
  pages.** I grepped `v22.5.1_sqlite.html`, `v22.20.0_sqlite.html` and
  `v24.8.0_sqlite.html` for `experimental-sqlite`: **zero hits in all three.**
  The flag story is only recoverable from `cli.html` (N06, N07). This is a
  real gap in the source docs, not a fetch failure.
- **CHANGELOG_V22.md was fetched from `main`, not from a v22.13.0 tag**, so it
  is not version-frozen. It is saved for provenance only; **no excerpt in
  `docs.jsonl` is drawn from it**, and no ground truth below depends on it.
- **`fs.watch` recursive-on-Linux**: the v18 caveat sentence is present
  (N10) and absent from v20.19.0 (N11) and v20.6.0 (checked, also absent).
  The corpus therefore pins the change to "somewhere at/before v20.6.0"; it
  does **not** contain a doc line naming the exact version that added Linux
  recursive support. Don't claim one.
- The SEA (`single-executable-applications.html`) and `permissions.html`
  pages were fetched and are in `raw/`, but no excerpt was taken from them —
  the v20.6.0 and v24.8.0 SEA texts are byte-identical in the sections I
  compared, so they carry no version conflict.

---

## COMBINATION QUESTIONS

Each answer requires reading **more than one** excerpt. "Wrong-answer excerpt"
is the single excerpt that, read alone, leads a confident reader astray.

### Q1. I run `node --env-file=.env app.js` on Node v20.6.0 and on Node v22.20.0. `.env` does not exist, and it contains (when it does exist) a value spanning two lines. What happens in each?

**Ground truth.** The two versions differ on both counts.
- Missing file: v22.20.0 documents "An error is thrown if the file does not
  exist" and offers `--env-file-if-exists` as the non-throwing variant
  (N02, N03). The v20.6.0 text documents neither the throw nor any
  `-if-exists` variant — `--env-file-if-exists` was only **added in v22.9.0**
  (N03), so it does not exist on v20.6.0 at all.
- Multi-line values: supported only from **v21.7.0 / v20.12.0** onward
  (history row in N02, N04). v20.6.0 predates that, and its own text
  (N01) describes the format strictly as "one line per key-value pair"
  with no multi-line clause.

So on v20.6.0: no `--env-file-if-exists` available, and a two-line value is
not supported. On v22.20.0: both work.

**Needs:** N01 + N02 + N03 (+ N04 for the multi-line rendering).
**Wrong alone:** **N02** — it carries the v20.12.0 multi-line history row and
reads like the current, universal description of `--env-file`, so a reader
concludes multi-line and `--env-file-if-exists` are available "since v20.6.0".
**N01** alone is equally wrong in the other direction: it makes `--env-file`
look like it never throws and never supported multi-line, at any version.

### Q2. On Node v22.5.1 versus Node v22.20.0, do I need a flag to `require('node:sqlite')`, and what does the flag do?

**Ground truth.** Yes on v22.5.1, no on v22.20.0 — and the flag's *polarity
flips*. On v22.5.1 the flag is `--experimental-sqlite`, "Added in: v22.5.0",
and it **enables** the module (N06). As of **v22.13.0** "SQLite is unflagged
but still experimental" (history row in N07), so on v22.20.0 the module
loads with no flag and the flag you would reach for is the negative
`--no-experimental-sqlite`, which **disables** it (N07).

Note the trap: both `--experimental-sqlite` and `--no-experimental-sqlite`
say "Added in: v22.5.0", so an "added in" line alone tells you nothing about
whether a flag is currently required.

**Needs:** N06 + N07.
**Wrong alone:** **N07** — it shows only the negative flag and the "unflagged"
row, so a reader concludes `node:sqlite` never needed a flag on any v22.
(**N06** alone gives the opposite error: that the flag is required through all
of v22.) Neither `sqlite.html` excerpt could settle this; see the gap noted
above.

### Q3. I want to restart my server on changes in `./src`. Does `node --watch-path=./src server.js` work on Linux, on macOS, and on Windows — and does the answer depend on the Node version?

**Ground truth.** Platform-gated, and the gate did **not** move with the
version. `--watch-path` "is only supported on macOS and Windows"; on any other
platform it throws `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM`. That sentence is
still present in the **v24.8.0** docs (N12), even though the same entry's
history says watch mode became stable in v22.0.0/v20.13.0. So on Linux it
fails on every version covered here; on macOS and Windows it works.

The trap is the near-identical `fs.watch({recursive:true})` restriction, which
*did* move: "only supported on macOS and Windows" in v18.20.4 (N10) is gone
from the v20.19.0 caveats (N11). Recursive `fs.watch` on Linux graduated;
`--watch-path` did not. "Watch mode is now stable" (N12 history) is a
stability statement, not a platform statement.

**Needs:** N12 + N10 + N11.
**Wrong alone:** **N11** — the v20.19.0 caveats with the platform restriction
removed, which invites "recursive/watch restrictions were lifted after v18, so
`--watch-path` is fine on Linux in v20+." It is not.

### Q4. Node v24, Windows. I set `process.env.MY_FLAG` in the main thread. Can a `Worker` read it back as `process.env.my_flag`?

**Ground truth.** No — and this is a Windows-only, thread-dependent split. On
Windows, `process.env` on the **main thread** is case-insensitive, so
`env.TEST = 1; env.test` reads `1`. But "On Windows, a copy of `process.env`
on a Worker instance operates in a **case-sensitive** manner unlike the main
thread" (N05). So `my_flag` misses inside the Worker; `MY_FLAG` hits.
Separately, the Worker gets a *copy*: later main-thread writes are not visible
across Worker threads at all. On POSIX/macOS both threads are case-sensitive,
so the lowercase lookup misses everywhere.

Relevant to `--env-file`: variables loaded from an env file land in
`process.env` (N02/N01), so a `.env` written with lowercase keys behaves
differently in a Worker on Windows than in the main thread on Windows.

**Needs:** N05 (+ N01 or N02 for the `--env-file` → `process.env` link).
**Wrong alone:** reading only the first clause of **N05** ("On Windows
operating systems, environment variables are case-insensitive") gives the
confident wrong answer "yes, Windows is case-insensitive, `my_flag` works" —
the Worker carve-out is in the same excerpt but several sentences later, and
no other excerpt contradicts the first clause.

### Q5 (bonus). Is the Permission Model stable, and which subsystems does it gate?

**Ground truth.** Version-dependent on both counts. On v20.6.0 the flag is
spelled `--experimental-permission`, marked "Stability: 1 - Experimental", and
gates three subsystems: File System, Child Process, Worker Threads (N08). By
v22.20.0 the flag is `--permission`, its history says "v22.13.0 Permission
Model is now stable", and it gates **five**: the original three plus WASI
(`--allow-wasi`) and Addons (`--allow-addons`) (N09). A v20.6.0 command line
using `--permission` or `--allow-wasi` is invalid.

**Needs:** N08 + N09.
**Wrong alone:** **N09** — "Added in: v20.0.0" on the `--permission` entry
makes the *current* spelling look like it has been valid since v20.0.0. The
flag added in v20.0.0 was `--experimental-permission`; the rename is only
visible by comparing with N08.
