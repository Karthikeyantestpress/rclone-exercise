#!/usr/bin/env bash
# transfer.sh - reusable, config-free file transfers with rclone.
#
# Usage: transfer.sh [options] <copy|sync> <source> <destination>
#
# Source/destination can be anything rclone understands, for example:
#   /srv/media                local path
#   :s3:bucket/path           on-the-fly S3, settings from RCLONE_S3_* env vars
#   store:bucket/path         named remote from RCLONE_CONFIG_STORE_* env vars
#   ":s3,provider=Other,endpoint='http://host:9000':bucket"   connection string
#
# Credentials are never read from an rclone.conf (the config is forced to
# in-memory) and never passed on the command line: they come from the
# environment, optionally loaded with --env-file (e.g. a mounted secret).
#
# Options:
#   -n, --dry-run            show what would happen, change nothing
#   -c, --checksum           compare by hash instead of size+modtime
#   -t, --transfers N        parallel file transfers (default 4)
#   -b, --bwlimit RATE       bandwidth limit, e.g. 10M or "08:00,5M 19:00,off"
#   -r, --retries N          whole-operation retries (default 3)
#       --verify             run `rclone check` after a successful transfer
#       --backup-dir PATH    sync only: move deleted/overwritten files here
#       --max-delete N       sync only: abort after N deletions (default 100)
#       --allow-empty-source sync only: allow syncing from an empty source
#       --env-file FILE      load credentials/remotes from FILE
#       --log-dir DIR        where to write logs (default ./logs)
#   -h, --help
#
# Exit codes:
#   0   success
#   64  usage error (bad arguments)
#   65  refused for safety (sync from an empty source)
#   66  verification failed (--verify found differences)
#   130 interrupted
#   other: rclone's own exit code (1 syntax, 3 dir not found, 4 file not
#   found, 5 temporary error, 6 less serious errors, 7 fatal error, ...)
set -uo pipefail

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; }

DRY_RUN=() CHECKSUM=() TRANSFERS=4 BWLIMIT="" RETRIES=3 VERIFY=0
BACKUP_DIR="" MAX_DELETE=100 ALLOW_EMPTY=0 ENV_FILE="" LOG_DIR="${TRANSFER_LOG_DIR:-./logs}"

while (($#)); do
  case "$1" in
    -n|--dry-run)        DRY_RUN=(--dry-run) ;;
    -c|--checksum)       CHECKSUM=(--checksum) ;;
    -t|--transfers)      TRANSFERS="${2:?}"; shift ;;
    -b|--bwlimit)        BWLIMIT="${2:?}"; shift ;;
    -r|--retries)        RETRIES="${2:?}"; shift ;;
    --verify)            VERIFY=1 ;;
    --backup-dir)        BACKUP_DIR="${2:?}"; shift ;;
    --max-delete)        MAX_DELETE="${2:?}"; shift ;;
    --allow-empty-source) ALLOW_EMPTY=1 ;;
    --env-file)          ENV_FILE="${2:?}"; shift ;;
    --log-dir)           LOG_DIR="${2:?}"; shift ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; break ;;
    -*)                  echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    *)                   break ;;
  esac
  shift
done

(($# == 3)) || { echo "expected: <copy|sync> <source> <destination>" >&2; usage >&2; exit 64; }
OP="$1" SRC="$2" DST="$3"
[[ "$OP" == copy || "$OP" == sync ]] || { echo "operation must be copy or sync, got: $OP" >&2; exit 64; }
[[ -n "$SRC" && -n "$DST" ]] || { echo "source and destination must not be empty" >&2; exit 64; }
[[ "$SRC" != "$DST" ]] || { echo "source and destination are the same" >&2; exit 64; }
if [[ "$OP" == copy && ( -n "$BACKUP_DIR" || $ALLOW_EMPTY == 1 ) ]]; then
  echo "--backup-dir/--allow-empty-source only apply to sync" >&2; exit 64
fi
command -v rclone >/dev/null || { echo "rclone not found in PATH" >&2; exit 64; }

if [[ -n "$ENV_FILE" ]]; then
  [[ -r "$ENV_FILE" ]] || { echo "cannot read env file: $ENV_FILE" >&2; exit 64; }
  set -a; source "$ENV_FILE"; set +a
fi

# Never touch a persistent rclone.conf.
export RCLONE_CONFIG=""

mkdir -p "$LOG_DIR"
# PID suffix: two runs in the same second must not share a log
LOG_FILE="$LOG_DIR/transfer-$(date +%Y%m%d-%H%M%S)-$$-$OP.log"
log() { printf '%s %s\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

trap 'log "INTERRUPTED: $OP $SRC -> $DST"; exit 130' INT TERM

# Safety: an empty or missing source turns sync into "delete everything".
if [[ "$OP" == sync && $ALLOW_EMPTY == 0 ]]; then
  first="$(rclone lsf -R --files-only --max-depth 20 "$SRC" 2>>"$LOG_FILE" | head -n 1)"
  if [[ -z "$first" ]]; then
    log "REFUSED: source $SRC is empty or unreadable; sync would delete the destination (use --allow-empty-source to override)"
    exit 65
  fi
fi

args=(
  "$OP" "$SRC" "$DST"
  --transfers "$TRANSFERS"
  --retries "$RETRIES" --retries-sleep 5s --low-level-retries 10
  --log-file "$LOG_FILE" --log-level INFO
  "${DRY_RUN[@]}" "${CHECKSUM[@]}"
)
[[ -n "$BWLIMIT" ]] && args+=(--bwlimit "$BWLIMIT")
[[ "$OP" == sync ]] && args+=(--max-delete "$MAX_DELETE")
[[ -n "$BACKUP_DIR" ]] && args+=(--backup-dir "$BACKUP_DIR")

# Progress: live display on a terminal, periodic one-line stats otherwise
# (cron, CI, Celery), so logs stay readable.
if [[ -t 1 ]]; then args+=(--progress); else args+=(--stats 10s --stats-one-line --stats-log-level NOTICE); fi

log "START: $OP $SRC -> $DST (transfers=$TRANSFERS retries=$RETRIES${BWLIMIT:+ bwlimit=$BWLIMIT}${DRY_RUN:+ dry-run}) log=$LOG_FILE"
start=$SECONDS
rclone "${args[@]}"
rc=$?

if ((rc != 0)); then
  log "FAILED: $OP $SRC -> $DST exit=$rc after $((SECONDS - start))s (details in $LOG_FILE)"
  grep -E "ERROR|NOTICE: Failed" "$LOG_FILE" | tail -n 3 >&2
  exit "$rc"
fi

if ((VERIFY)) && ((${#DRY_RUN[@]} == 0)); then
  # copy leaves extra destination files alone, so only check one way
  check_args=(check "$SRC" "$DST" --log-file "$LOG_FILE" --log-level INFO)
  [[ "$OP" == copy ]] && check_args+=(--one-way)
  if ! rclone "${check_args[@]}"; then
    log "VERIFY FAILED: $SRC and $DST differ (details in $LOG_FILE)"
    exit 66
  fi
  log "VERIFIED: $SRC matches $DST"
fi

log "OK: $OP $SRC -> $DST in $((SECONDS - start))s"
exit 0
