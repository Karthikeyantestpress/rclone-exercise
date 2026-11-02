# rclone commands used

All commands run with `RCLONE_CONFIG=""` (in-memory config, no `rclone.conf`). The S3 examples
use `:s3:`, an on-the-fly remote whose settings come from these variables:

```bash
export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT=$S3_A_ENDPOINT
export RCLONE_S3_ACCESS_KEY_ID=$S3_A_ACCESS_KEY RCLONE_S3_SECRET_ACCESS_KEY=$S3_A_SECRET_KEY
```

The full scripts are in [`experiments/`](experiments). Their real output is in [`results/logs/`](results/logs).

## Listing

| Command | What it does |
|---|---|
| `rclone ls PATH` | every file, recursive, with size |
| `rclone lsd PATH` | top-level directories; `rclone lsd :s3:` lists buckets |
| `rclone lsf -R --format pst PATH` | machine-friendly `path;size;modtime` (add `h --hash MD5` for hashes) |
| `rclone lsjson PATH --recursive` | JSON, for scripts |
| `rclone tree PATH` | tree view |
| `rclone size PATH` | object count and total bytes |

## copy, move, sync, delete

| Command | What it does with destination files |
|---|---|
| `rclone copy SRC DST` | adds new files, replaces changed ones (size/modtime differ), **never deletes**. Files already identical are skipped. |
| `rclone move SRC DST` | copy, then **deletes the source** file after each successful transfer. `--delete-empty-src-dirs` also removes emptied folders. |
| `rclone sync SRC DST` | makes DST identical to SRC: copies new and changed files and **deletes destination files not in SRC** |
| `rclone deletefile PATH/file` | deletes one file |
| `rclone delete PATH [--include '*.pdf']` | deletes files (optionally filtered) and keeps directories |
| `rclone rmdirs PATH` | removes empty directories |
| `rclone purge PATH` | deletes everything under PATH, including the bucket itself |

Useful flags for all of these:

| Flag | Purpose |
|---|---|
| `-v` / `-vv` | log each action / debug detail (retries show at `-vv`) |
| `--dry-run` | report what would be copied or deleted, change nothing |
| `--checksum` | compare by hash, not size + modtime |
| `--backup-dir DIR` | sync/copy: move replaced or deleted files to DIR instead of destroying them |
| `--max-delete N` | abort a sync once N deletes are reached |

## Verification

| Command | What it does |
|---|---|
| `rclone check SRC DST` | compares sizes and hashes; exit code 1 if anything differs |
| `rclone check SRC DST --combined -` | per-file report: `=` same, `*` differ, `+` only in SRC, `-` only in DST |
| `rclone check SRC DST --one-way` | only checks that SRC files exist and match in DST |
| `rclone check SRC DST --download` | compares actual bytes (for backends without a common hash) |
| `rclone cryptcheck SRC cryptremote:` | verifies encrypted copies without decrypting them |

## Buckets and objects (S3)

```bash
rclone mkdir :s3:videos                          # create bucket
rclone copy data/source :s3:videos -v            # upload
rclone copy :s3:videos/pdfs data/downloaded -v   # download
rclone ls :s3:videos                             # list objects
rclone copy :s3:videos :s3:backups -v            # bucket -> bucket: "Copied (server-side copy)"
rclone deletefile :s3:backups/docs/readme.txt    # delete one object
rclone delete :s3:backups --include "*.pdf"      # delete by filter
rclone purge :s3:backups                         # delete all objects + bucket
echo hi | rclone rcat :s3:videos/hi.txt          # upload from stdin
rclone cat :s3:videos/hi.txt                     # print an object
```

## Configuration-free styles

```bash
# 1. connection string (quote values containing ':' or ',')
rclone ls ":s3,provider=Other,endpoint='http://127.0.0.1:9000',access_key_id=$KEY,secret_access_key=$SECRET:videos"

# 2. backend flags
rclone ls :s3:videos --s3-provider Other --s3-endpoint "$EP" --s3-access-key-id "$KEY" --s3-secret-access-key "$SECRET"

# 3. env vars for the unnamed :s3: remote
RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT=$EP RCLONE_S3_ACCESS_KEY_ID=$KEY RCLONE_S3_SECRET_ACCESS_KEY=$SECRET rclone ls :s3:videos

# 4. named remotes from env vars (several endpoints, different keys)
export RCLONE_CONFIG_PROVA_TYPE=s3 RCLONE_CONFIG_PROVA_PROVIDER=Other RCLONE_CONFIG_PROVA_ENDPOINT=$EP_A \
       RCLONE_CONFIG_PROVA_ACCESS_KEY_ID=$KEY_A RCLONE_CONFIG_PROVA_SECRET_ACCESS_KEY=$SECRET_A
export RCLONE_CONFIG_PROVB_TYPE=s3 ...   # same for B
rclone copy prova:videos provb:replica   # different credentials on each side

# prove no config is involved
rclone config file                        # "Configuration is in memory only"
rclone --config /path/to/empty.conf listremotes
```

## Large files and reliability

| Command / flag | Purpose |
|---|---|
| `--s3-upload-cutoff 200M` | files above this size use multipart upload (default 200M) |
| `--s3-chunk-size 64M --s3-upload-concurrency 4` | part size, and parts uploaded in parallel per file |
| `--transfers N` | files transferred in parallel (default 4) |
| `--checkers N` | parallel comparisons when deciding what to transfer (default 8) |
| `--multi-thread-streams N` | ranged parallel download of one large file |
| `--bwlimit 20M` / `--bwlimit "08:00,5M 19:00,off"` | bandwidth cap / timetable |
| `--progress` | live progress in a terminal |
| `--stats 5s --stats-one-line` | periodic stats lines for logs |
| `--use-json-log` | JSON log lines, including a `stats` object, for monitoring |
| `--retries 3 --retries-sleep 5s` | re-run the whole operation for failed files |
| `--low-level-retries 10` | retry individual HTTP requests |
| `--timeout 5m --contimeout 1m` | idle and connect timeouts |
| `rclone backend list-multipart-uploads :s3:bucket` | unfinished multipart uploads (left by crashes) |
| `rclone backend cleanup :s3:bucket -o max-age=24h` | abort old unfinished multipart uploads |

## Bonus

```bash
rclone copy prova:a provb:a                          # provider -> provider, streamed through this host
rclone copy prova:a prova:b --disable copy           # force download + re-upload instead of server-side copy
export RCLONE_CONFIG_VAULT_TYPE=crypt RCLONE_CONFIG_VAULT_REMOTE=prova:vault \
       RCLONE_CONFIG_VAULT_PASSWORD="$(rclone obscure "$PASSPHRASE")"
rclone copy data/source vault:                       # encrypted at rest on the provider
rclone mount prova:bonus data/mnt --vfs-cache-mode writes --daemon   # FUSE mount
fusermount -u data/mnt
systemd-run --user --on-active=2s --setenv=RCLONE_S3_... ./transfer.sh copy SRC DST   # scheduled run
```
