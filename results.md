# Results and observations

All numbers come from the recorded runs in [`results/logs/`](results/logs) (rclone v1.75.2,
Ubuntu 22.04 on WSL2, both S3 endpoints on loopback). Loopback has no network latency, so the
timings mainly reflect disk and CPU. The comments explain where real cloud storage would behave
differently.

## 1. Basic operations ([log](results/logs/01-local-operations.log))

| Experiment | Observation |
|---|---|
| `copy` run twice | 1st: 6 files `Copied (new)`, 100 MiB. 2nd: `There was nothing to transfer`, `Checks: 6 / 6`. Unchanged files are skipped. |
| extra file at the destination, then `copy` | the file survived. **copy never deletes.** |
| changed source file, then `copy` | only that file: `Copied (replaced existing)`, 61 B |
| `move` | files are moved and gone from the source; the empty `2026/` folder stays unless `--delete-empty-src-dirs` is given. If the destination folder does not exist, local `move` just renames the directory (no data copied). |
| `sync` + stale destination file | `--dry-run` reported `Skipped delete … old-export.csv`; the real sync deleted it |
| corrupted file, **same size and modtime** | `copy` said `nothing to transfer` (it compares size + modtime only). `check` reported `md5 differ`. `copy --checksum` repaired it. |

**copy vs move vs sync for files already at the destination:**
- **copy** skips identical files, overwrites changed ones, and leaves extra destination files alone.
- **move** does the same as copy, then deletes each successfully transferred source file. A
  source file that already exists identically at the destination is simply deleted from the source.
- **sync** does the same as copy, plus it **deletes destination files that are not in the source**,
  so the destination becomes a mirror.

## 2. S3 operations ([log](results/logs/02-s3-operations.log))

- Creating buckets, uploading, listing, downloading and deleting all worked with no config file
  (`rclone config file` → `Configuration is in memory only`).
- The downloaded 100 MB file was byte-identical (`cmp`), and `check data/source :s3:videos`
  matched the local MD5 against the S3 ETag.
- Bucket → bucket on the same endpoint: `Copied (server-side copy)`, `Server Side Copies: 6 @ 100.001 MiB`.
- S3 has no folders: `docs/notes/` only exists as a common prefix of object keys.

## 3. Configuration-free execution ([log](results/logs/03-config-free.log))

- All four styles (connection string, flags, `RCLONE_S3_*`, `RCLONE_CONFIG_<NAME>_*`) worked
  with `--config data/empty-rclone.conf`, and the file was still 0 bytes at the end.
- With named env remotes, `rclone copy prova:… provb:…` used **endpoint A's keys to read and
  endpoint B's keys to write** in a single command; `check` found 0 differences.
- B's keys against A failed with `403 InvalidAccessKeyId`, which proves the credentials are really checked.
- Two pitfalls found along the way:
  - an endpoint containing `:` must be quoted inside a connection string
    (`endpoint='http://…'`), otherwise rclone reports `Custom endpoint 'http' was not a valid URI`
  - list-valued env vars are parsed as CSV, so `RCLONE_AUTH_KEY=key,secret` became two broken
    entries; it needs `RCLONE_AUTH_KEY='"key,secret"'`

## 4. Transfer reliability ([log](results/logs/04-reliability.log))

| Experiment | Observation |
|---|---|
| 1 GB upload, `--s3-chunk-size 64M --s3-upload-concurrency 4` | `Multi-thread Copied (new)` in 5.6 s (20.5 s on a cold first run). `check` matched via the MD5 rclone stores in object metadata (a multipart ETag is not an MD5). |
| 6 × 25 MB, `--transfers 1` vs `6` | 1.10 s vs 0.38 s |
| `--bwlimit 20M`, 100 MB | stats held at 20.0 MiB/s; 5.3 s total |
| progress / stats | `--stats 1s` printed a block every second (bytes, %, speed, ETA, files done); `--use-json-log` gives the same as a JSON `stats` object |
| server SIGKILLed 3 s into a 100 MB upload, restarted 7 s later | low-level retries failed while the server was down → `Attempt 1/5 failed` → after `--retries-sleep 3s`, `Attempt 2/5 succeeded`; `check`: 0 differences |
| rclone SIGKILLed 15 s into 6 × 25 MB + 1 GB | all 6 small files had completed; the 1 GB object did not exist, but `list-multipart-uploads` showed its orphaned upload |
| same command re-run | **the 6 finished files were skipped** (only checked); **the 1 GB file was uploaded again from byte 0** (10.5 s); `check`: 7 matching. `backend cleanup -o max-age=0s` removed the orphaned upload. |
| local destination killed after 2 s | left `upload-1GB.bin.c7a93da1.partial` (165 MB); the re-run wrote the whole file again and the `.partial` disappeared |

**Takeaways:**
- Retry granularity is the **file**. rclone does not resume a half-finished S3 multipart upload
  in a new run. For very large files, smaller units (or one object per video rendition) limit
  how much a failure costs.
- A crash leaves orphaned multipart parts that **are billed on real S3**. Use
  `rclone backend cleanup` or a bucket lifecycle rule ("abort incomplete multipart uploads after N days").
- Simulating a real outage needed SIGKILL: with SIGTERM the server shut down gracefully and
  finished the in-flight upload first, so nothing failed.

## 5. Sync and data safety ([log](results/logs/05-sync-safety.log))

Scenario: the destination holds v1 plus a manually uploaded PDF. The source has 1 modified,
1 renamed, 1 deleted and 1 new file.

- `check --combined -` showed `* index.html`, `+ about-us.html`, `+ careers.html`, `- about.html`,
  `- pricing.html`, `- hand-uploaded.pdf`.
- `sync --dry-run` listed 3 copies and **3 deletes**, including the manual upload nobody intended to
  lose. A rename appears as delete + new.
- `sync --backup-dir :s3:site-trash/<date>` moved the old `index.html`, `about.html`,
  `pricing.html` and `hand-uploaded.pdf` into the trash prefix (server-side). `rclone cat` of the
  backup returned `home v1`, so nothing was lost.
- After the sync, `check` and `check --download` both found 0 differences.

**Why `rclone sync` is dangerous:**
1. **An empty or wrong source deletes the destination.** The dry-run of `sync data/empty-dir
   :s3:site` would delete all 4 files. A failed mount, a typo or an unset `$VAR` all look like an
   empty source.
2. **`--max-delete 2`** cancelled that sync (`--max-delete threshold reached`), but 2 files were
   already gone. It is a tripwire, not a substitute for `--dry-run`.
3. **Swapped arguments** make the destination the source of truth. `sync :s3:site data/sync-src
   --dry-run` would have deleted a new local draft, which `copy` would never do.
4. `--delete-excluded` combined with filters deletes everything the filter excludes.

`transfer.sh` builds these lessons in: it refuses an empty source (exit 65), sets `--max-delete
100`, offers `--backup-dir` and `--dry-run`, and quotes every path.

## 6. transfer.sh ([log](results/logs/06-transfer-script.log))

15/15 test cases passed: argument validation (64), local copy + verify, repeated copy transfers
nothing, missing source (3), local → S3, S3 A → S3 B via `--env-file`, dry-run changes nothing,
empty-source refusal (65), sync with backup-dir, wrong credentials (non-zero), unreadable env
file (64). No secret values were found in any log.

## 7. Bonus ([log](results/logs/07-bonus.log))

| Experiment | Observation |
|---|---|
| server-side copy vs `--disable copy` vs A → B, 1 GB | 12.0 s (`Copied (server-side copy)`), 21.2 s (download + re-upload), 14.7 s (cross-provider stream). On real S3, server-side copy moves no bytes through the client and is usually far faster and free of egress costs. Here the "server" is a process on the same disk, so the gap is small. |
| 300 × 8 KB, `--transfers 1` vs `16` | 0.52 s vs 0.38 s. Against real S3, each request costs tens of ms of latency, so parallel transfers matter far more for many small files. |
| `--checkers 1` vs `16` (all files already present) | 0.28 s vs 0.18 s |
| 1 GB download, `--multi-thread-streams 1` vs `4` | 13.6 s vs 18.2 s. On loopback with WSL disk I/O, parallel ranged writes were *slower*. This pays off when a single TCP stream cannot fill the link (real networks), so measure before tuning. |
| crypt | the provider only sees names like `uokogui8cuauaheiagu32rr3ro` and content starting `RCLONE\0\0` + ciphertext; `cryptcheck` verified the copies without decrypting |
| mount (`--vfs-cache-mode writes`) | browsing and reading work; writes are uploaded after the file is closed (`--vfs-write-back`, default 5 s); `mv` became server-side copy + delete. No locking, no hard links, slow listings on big buckets. Use copy/sync for pipelines. |
| systemd timer | a transient `systemd-run --user --on-active=2s` unit ran `transfer.sh --verify` with credentials in the unit environment: `VERIFIED` + `OK` in the journal |
| Python `subprocess` | `{"bytes": 1194, "transfers": 2, "errors": 0}` parsed from the JSON log; bad credentials raised `TransferError` with exit code 1 |

The rclone error for bad S3 credentials can be misleading. With a wrong secret, rclone reported
`is a file not a directory` (its existence probe got a 403). When an S3 path "should" exist,
check the credentials first.

## Demonstration questions

**1. What happens when `rclone copy` is executed twice with the same source and destination?**
The second run lists both sides, finds every file has the same size and modification time, and
transfers nothing (`There was nothing to transfer`, `Checks: 6 / 6`). It is idempotent: safe to
re-run after a failure, and only missing or changed files move.

**2. What happens if a file exists at the destination but not at the source when `rclone sync` runs?**
It is deleted from the destination (`old-export.csv: Deleted`). With `--backup-dir` it is moved
there instead. `--dry-run` shows it as `Skipped delete`, and `--max-delete` limits how many such
deletes may happen.

**3. How does rclone determine whether a file needs to be transferred?**
By default it compares **size and modification time** (on S3 the modtime is stored in object
metadata). If they match, the file is skipped. Other modes: `--checksum` compares size + hash
(MD5/SHA1, the S3 ETag or stored MD5), `--size-only` compares size only, `--update` skips files
that are newer at the destination, and `--ignore-existing` skips anything already present. Our
same-size, same-modtime corruption was missed by the default mode and caught by `--checksum` and `check`.

**4. Can rclone transfer data directly between two S3 providers without downloading it to the local machine?**
Between buckets on the **same** provider and endpoint, yes: rclone issues a server-side
`CopyObject` and no data passes through the client (`Copied (server-side copy)`). Between
**different** providers, no. The data streams through the machine running rclone: it is read
from A and written to B in memory, without being stored on local disk, but it does use that
machine's bandwidth (and egress fees apply). To keep that traffic off a laptop, run rclone on a
server close to the providers.

**5. What happens when a network connection is interrupted halfway through a 1 GB upload?**
Within one run, rclone retries the failed HTTP requests (`--low-level-retries`). If those fail,
the file fails and `--retries` re-runs the operation; in our test attempt 2/5 succeeded after the
server returned. If the rclone process itself dies, files that completed are kept and skipped next
time, while the interrupted 1 GB file is **uploaded again from the start**: the next run does not
resume the multipart upload. The abandoned parts stay on the server as an incomplete multipart
upload until they are aborted with `rclone backend cleanup` or a lifecycle rule. No partial
object becomes visible, because S3 only creates the object when the multipart upload is completed.

**6. How would you securely execute rclone from a Celery worker without maintaining an `rclone.conf` file?**
- Define the remote with `RCLONE_CONFIG_<NAME>_*` variables (or `RCLONE_S3_*`) and set `RCLONE_CONFIG=""`.
- Get the credentials at task time from a secrets manager or the worker's injected environment,
  never from git, the task arguments or the broker message. On AWS, prefer an IAM role (`env_auth=true`).
- Call `subprocess.run([...], env=child_env, timeout=...)` with a **list** of arguments (no
  shell) and the credentials only in `env`, never in argv.
- Use `--use-json-log` to parse stats and errors. Map exit code 5 (temporary) to a Celery retry
  with backoff, and other codes to failure. Never log the environment.
- Give each worker scoped keys (only the buckets it needs). Avoid `--dry-run`-less `sync` from
  task input, and validate paths.

[`examples/python/run_rclone.py`](examples/python/run_rclone.py) implements this pattern.

## Applying this at Testpress / TPStreams

- **Video uploads and backups:** use `copy --checksum` + `check` for integrity, a multipart
  chunk size tuned to link speed, and a lifecycle rule for abandoned multipart uploads.
- **Moving between storage providers** (for example, for cost): run rclone on a server near both
  providers. It is a streamed transfer, so plan for egress costs and use `--bwlimit` during business hours.
- **Mirrors:** use `sync` only with `--dry-run` review, `--backup-dir` or bucket versioning, and `--max-delete`.
- **Automation:** Celery or systemd timers calling `transfer.sh` or `subprocess`, with
  credentials from the environment, JSON logs into monitoring, and alerts on non-zero exit codes.
