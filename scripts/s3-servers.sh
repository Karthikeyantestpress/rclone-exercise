#!/usr/bin/env bash
# Run the two local S3 endpoints without Docker (same servers as
# docker-compose.yml): `rclone serve s3` on ports 9000 (A) and 9100 (B),
# storing objects under data/s3-a and data/s3-b.
#
# Usage: scripts/s3-servers.sh start|stop|status
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/data/run"
export PATH="$HOME/.local/bin:$PATH"
export RCLONE_CONFIG=""   # the servers need no rclone.conf either

[[ -f "$ROOT/.env" ]] || { echo "missing .env: cp .env.example .env"; exit 1; }
set -a; source "$ROOT/.env"; set +a

start_one() {  # start_one <name> <endpoint> <access> <secret>
  local name=$1 port=${2##*:}
  if [[ -f "$RUN/$name.pid" ]] && kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
    echo "$name already running"; return
  fi
  mkdir -p "$ROOT/data/$name" "$RUN"
  # Credentials go in via the environment, not --auth-key, so they don't
  # show up in `ps` for other users. CSV quotes keep "key,secret" one entry.
  RCLONE_AUTH_KEY="\"$3,$4\"" nohup rclone serve s3 "$ROOT/data/$name" \
    --addr "127.0.0.1:$port" --etag-hash MD5 -v >"$RUN/$name.log" 2>&1 &
  echo $! > "$RUN/$name.pid"
  echo "$name listening on 127.0.0.1:$port (log: data/run/$name.log)"
}

stop_one() {
  local pid
  pid="$(cat "$RUN/$1.pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && echo "$1 stopped"
  rm -f "$RUN/$1.pid"
}

case "${1:-}" in
  start)
    start_one s3-a "$S3_A_ENDPOINT" "$S3_A_ACCESS_KEY" "$S3_A_SECRET_KEY"
    start_one s3-b "$S3_B_ENDPOINT" "$S3_B_ACCESS_KEY" "$S3_B_SECRET_KEY"
    sleep 1;;
  stop)   stop_one s3-a; stop_one s3-b;;
  status) for n in s3-a s3-b; do
            if [[ -f "$RUN/$n.pid" ]] && kill -0 "$(cat "$RUN/$n.pid")" 2>/dev/null; then echo "$n running"; else echo "$n stopped"; fi
          done;;
  *) echo "usage: $0 start|stop|status"; exit 1;;
esac
