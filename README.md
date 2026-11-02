# File Transfers and Storage Automation with rclone

A reproducible set of experiments, plus a reusable script, for moving files reliably between
local directories and S3-compatible storage with [rclone](https://rclone.org). Everything runs
locally, **without an `rclone.conf`**: every remote is configured on the fly from environment
variables, flags or connection strings.

| Deliverable | File |
|---|---|
| Installation, setup, how to reproduce | this README |
| Reusable transfer script | [`transfer.sh`](transfer.sh) (tests: [`tests/test-transfer.sh`](tests/test-transfer.sh)) |
| Commands with explanations | [`commands.md`](commands.md) |
| Observations and answers to the demo questions | [`results.md`](results.md) |
| Local S3-compatible storage | [`docker-compose.yml`](docker-compose.yml) |
| Raw output of every experiment | [`results/logs/`](results/logs) |

## Architecture

```
                        transfer.sh / experiments/*.sh
                                   │  rclone v1.75.2, RCLONE_CONFIG="" (no config file)
       ┌───────────────────────────┼─────────────────────────────┐
       ▼                           ▼                             ▼
 local directories          S3 endpoint A                  S3 endpoint B
 data/source, data/site-a   127.0.0.1:9000                 127.0.0.1:9100
 data/site-b, ...           key/secret "A"  (from .env)    key/secret "B"  (from .env)
                            buckets: videos, big, site...  buckets: replica, bonus...
```

Endpoints A and B stand in for two storage providers (for example AWS S3 and DigitalOcean
Spaces). They have separate credentials, so the experiments can show cross-provider transfers
and per-operation credentials.

### Why not MinIO?

The exercise suggests MinIO, but MinIO no longer publishes community builds: the
`minio/minio` repository is gone from Docker Hub, and `dl.min.io` returns `410 Gone` for server
binaries. The task allows "another compatible local object storage implementation", so the
endpoints use **`rclone serve s3`**, rclone's built-in S3 server. It implements AWS Signature
v4 authentication, buckets, multipart uploads (including listing and aborting them) and
server-side `CopyObject`. Everything the client side does here, such as on-the-fly remotes,
multipart, retries and server-side copy, works the same against AWS S3, MinIO, Wasabi or
DigitalOcean Spaces with `provider=` set accordingly.

## Repository layout

```
transfer.sh                 reusable copy/sync script (part 7)
transfer.env.example        example --env-file defining two named remotes
docker-compose.yml          two S3 endpoints in Docker
.env.example                endpoint URLs + placeholder credentials (copy to .env)
scripts/
  install-rclone.sh         pinned rclone into ~/.local/bin, checksum-verified, no sudo
  make-sample-data.sh       nested folders, text, PDFs, 100MB file (+1GB with --big)
  s3-servers.sh             start|stop|status the two S3 endpoints without Docker
experiments/
  lib.sh                    shared helpers (echo command, run, never use a config file)
  01-local-operations.sh    ls, copy, move, sync, delete, check on local dirs
  02-s3-operations.sh       buckets, upload, download, list, bucket->bucket, delete
  03-config-free.sh         connection strings, flags, env vars, named env remotes
  04-reliability.sh         1GB multipart, transfers, bwlimit, stats, retries, crash+restart
  05-sync-safety.sh         diverging versions, dry-run, backup-dir, check, sync dangers
  07-bonus.sh               cross-provider, server-side copy, tuning, crypt, mount, timer, Python
tests/test-transfer.sh      15 test cases for transfer.sh
examples/                   systemd timer, crontab, Python subprocess (Celery-style)
results/logs/               recorded output of every script above
```

## Setup

Tested on Ubuntu 22.04 (WSL2). Requires `bash`, `curl`, `python3`, and about 3 GB of free disk.

**1. Install rclone** (pinned version, SHA256-verified, into `~/.local/bin`, no sudo):

```bash
scripts/install-rclone.sh
```

Alternatively, use your distro package or `curl https://rclone.org/install.sh | sudo bash`.

**2. Create local credentials.** `.env` is gitignored; the example only holds placeholders.
This replaces the placeholder secrets with random values:

```bash
cp .env.example .env
```

```bash
sed -i "s/change-me-provider-a/$(openssl rand -hex 16)/; s/change-me-provider-b/$(openssl rand -hex 16)/" .env
```

**3. Start the two S3 endpoints.** Use either option:

```bash
docker compose up -d
```

```bash
scripts/s3-servers.sh start
```

The experiments in `results/logs/` were recorded with `scripts/s3-servers.sh`, because the
recording machine had no Docker permissions. Both options run the same server
(`rclone serve s3` v1.75.2) on the same ports with the same `.env` credentials.

**4. Generate the sample data** (about 1.1 GB in `data/`, gitignored):

```bash
scripts/make-sample-data.sh --big
```

**5. Run the experiments.** Each one prints every command followed by its real output:

```bash
for e in experiments/0*.sh; do $e | tee results/logs/$(basename $e .sh).log; done
```

```bash
tests/test-transfer.sh | tee results/logs/06-transfer-script.log
```

**6. Stop the endpoints:**

```bash
scripts/s3-servers.sh stop
```

Or, if you used Docker:

```bash
docker compose down -v
```

## transfer.sh

```
transfer.sh [options] <copy|sync> <source> <destination>
```

Source and destination can be any rclone path: a local directory, `:s3:bucket/path` (settings
from `RCLONE_S3_*`), a named remote such as `store:bucket` defined by `RCLONE_CONFIG_STORE_*`
variables, or a connection string.

| Option | Purpose |
|---|---|
| `-n, --dry-run` | show what would happen without changing anything |
| `-c, --checksum` | compare by hash instead of size + modtime |
| `-t, --transfers N` | parallel transfers (default 4) |
| `-b, --bwlimit RATE` | bandwidth limit (`10M`, or a timetable like `"08:00,5M 19:00,off"`) |
| `-r, --retries N` | whole-operation retries (default 3; low-level HTTP retries are always 10) |
| `--verify` | run `rclone check` after the transfer (one-way for copy) |
| `--backup-dir PATH` | sync only: move deleted or overwritten files here instead of destroying them |
| `--max-delete N` | sync only: abort after N deletions (default 100) |
| `--allow-empty-source` | sync only: override the empty-source guard |
| `--env-file FILE` | load credentials and remote definitions from a file (for example a mounted secret) |
| `--log-dir DIR` | log directory (default `./logs`, or `$TRANSFER_LOG_DIR`) |

Behaviour:
- **No config file.** `RCLONE_CONFIG=""` is forced. Credentials only come from the environment
  and never appear on the command line or in logs.
- **Progress.** You get a live `--progress` display on a terminal and periodic one-line stats
  when run from cron, systemd or CI.
- **Logs.** Each run writes `transfer-<timestamp>-<pid>-<op>.log` containing
  `START`/`OK`/`FAILED`/`VERIFIED`/`REFUSED` lines plus rclone's INFO log.
- **Exit codes.** `0` ok, `64` usage error, `65` refused for safety (sync from an empty source),
  `66` verification failed, `130` interrupted. Otherwise it returns rclone's own code (`1`
  syntax, `3` directory not found, `5` temporary error, `7` fatal, and so on).

Examples:

```bash
# local -> S3 endpoint A, settings from the environment
set -a; source .env; set +a
RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT=$S3_A_ENDPOINT \
RCLONE_S3_ACCESS_KEY_ID=$S3_A_ACCESS_KEY RCLONE_S3_SECRET_ACCESS_KEY=$S3_A_SECRET_KEY \
  ./transfer.sh --verify copy data/source :s3:videos

# provider A -> provider B with two named remotes from an env file
./transfer.sh --env-file transfer.env.example --verify copy providera:videos providerb:videos

# preview, then mirror with a safety net
./transfer.sh --env-file transfer.env.example --dry-run sync data/source providerb:site
./transfer.sh --env-file transfer.env.example --backup-dir providerb:trash/$(date +%F) sync data/source providerb:site
```

The test suite covers argument validation, local, S3 and cross-endpoint transfers, dry-run,
empty-source refusal, backup-dir, bad credentials and a missing source. **15/15 pass**
([log](results/logs/06-transfer-script.log)).

## Configuration-free execution: what to use in production

| Approach | Example | Secrets visible in `ps`/history? | Several endpoints at once? |
|---|---|---|---|
| Connection string | `":s3,provider=Other,endpoint='…',access_key_id=…,secret_access_key=…:bkt"` | yes | yes |
| Backend flags | `--s3-endpoint … --s3-secret-access-key …` | yes | no |
| `RCLONE_S3_*` env vars | `RCLONE_S3_SECRET_ACCESS_KEY=… rclone ls :s3:bkt` | no | no (one `:s3:` config) |
| **Named remotes in env** | `RCLONE_CONFIG_STORE_TYPE=s3 … rclone ls store:bkt` | no | **yes** |

**Recommendation: named remotes defined with `RCLONE_CONFIG_<NAME>_*` environment
variables**, injected at runtime from a secrets manager (Vault, AWS Secrets Manager, Kubernetes
Secrets, systemd `EnvironmentFile` with mode 600). This approach:
- keeps secrets out of argv, shell history, logs and git
- allows several providers with different credentials in one command
- leaves nothing on disk for another process or a backup to leak
- makes each worker's credentials scoped and easy to rotate

Better still, on AWS use IAM roles (`env_auth=true`) so there are no static keys at all. For
Celery workers, pass the variables through `subprocess.run(..., env=...)` (see
[`examples/python/run_rclone.py`](examples/python/run_rclone.py)).

## Security notes

- `.env` is gitignored and `chmod 600`. Only placeholders are committed. Every log in
  `results/logs/` was checked to make sure it contains none of the generated secrets.
- The experiment scripts write commands in single quotes, so logs show `$S3_A_SECRET_KEY`, never the value.
- The S3 servers receive their keys through `RCLONE_AUTH_KEY`, not `--auth-key`, so the keys are not visible in `ps`.
- `rclone obscure` (used for the crypt password) is reversible obfuscation, not encryption.
  Protect the real password the same way as any other secret.

## Cleanup

```bash
scripts/s3-servers.sh stop && rm -rf data logs
```
