#!/usr/bin/env bash
# Experiment 7 (bonus): cross-provider copies, server-side vs streamed copy,
# tuning flags, encryption with crypt, rclone mount, scheduling, Python.
#
# Usage: experiments/07-bonus.sh | tee results/logs/07-bonus.log
source "$(dirname "$0")/lib.sh"
TIMEFORMAT='elapsed: %Rs'
# two named remotes from env vars: provider A and provider B
export RCLONE_CONFIG_PROVA_TYPE=s3 RCLONE_CONFIG_PROVA_PROVIDER=Other RCLONE_CONFIG_PROVA_ENDPOINT="$S3_A_ENDPOINT" RCLONE_CONFIG_PROVA_ACCESS_KEY_ID="$S3_A_ACCESS_KEY" RCLONE_CONFIG_PROVA_SECRET_ACCESS_KEY="$S3_A_SECRET_KEY"
export RCLONE_CONFIG_PROVB_TYPE=s3 RCLONE_CONFIG_PROVB_PROVIDER=Other RCLONE_CONFIG_PROVB_ENDPOINT="$S3_B_ENDPOINT" RCLONE_CONFIG_PROVB_ACCESS_KEY_ID="$S3_B_ACCESS_KEY" RCLONE_CONFIG_PROVB_SECRET_ACCESS_KEY="$S3_B_SECRET_KEY"
for b in prova:bonus prova:bonus-copy provb:bonus prova:vault; do rclone purge "$b" 2>/dev/null; done
rclone mkdir prova:bonus; rclone mkdir provb:bonus
rclone copy data/big prova:bonus/big --stats 0

section "1. Server-side copy vs download + re-upload"
note "same endpoint: rclone sends CopyObject, the server copies internally, no bytes pass through this machine"
run 'time rclone copy prova:bonus/big prova:bonus-copy/server-side -v --stats 0 2>&1 | grep -E "Copied|Server Side"'
note "--disable copy forces rclone to download and re-upload the same 1GB"
run 'time rclone copy prova:bonus/big prova:bonus-copy/streamed --disable copy -v --stats 0 2>&1 | grep -E "Copied"'
note "different endpoints (provider A -> provider B): server-side copy is impossible, data streams through this machine without touching its disk"
run 'time rclone copy prova:bonus/big provb:bonus/big -v --stats 0 2>&1 | grep -E "Copied"'
run 'rclone check prova:bonus/big provb:bonus/big'

section "2. Tuning: --transfers, --checkers, --multi-thread-streams"
mkdir -p data/small
[[ -f data/small/f-300.txt ]] || for i in $(seq 1 300); do head -c 8K /dev/urandom > data/small/f-$i.txt; done
note "300 x 8KB files: per-file overhead dominates, parallel transfers help most"
run 'time rclone copy data/small prova:bonus/small-t1 --transfers 1 --stats 0'
run 'time rclone copy data/small prova:bonus/small-t16 --transfers 16 --stats 0'
note "re-running over existing files only checks; --checkers sets how many comparisons run in parallel"
run 'time rclone copy data/small prova:bonus/small-t16 --checkers 1 --stats 0'
run 'time rclone copy data/small prova:bonus/small-t16 --checkers 16 --stats 0'
note "one big download: --multi-thread-streams splits it into ranged GETs in parallel"
rm -rf data/dl-1 data/dl-4
run 'time rclone copy prova:bonus/big data/dl-1 --multi-thread-streams 1 --stats 0'
run 'time rclone copy prova:bonus/big data/dl-4 --multi-thread-streams 4 --multi-thread-cutoff 64M --stats 0'

section "3. Client-side encryption with crypt (no config file either)"
note "crypt wraps another remote; the password is passed obscured (obscuring is NOT encryption, it only stops shoulder-surfing)"
run 'export RCLONE_CONFIG_VAULT_TYPE=crypt RCLONE_CONFIG_VAULT_REMOTE=prova:vault RCLONE_CONFIG_VAULT_PASSWORD="$(rclone obscure "demo-passphrase-from-a-secret-store")"'
run 'rclone copy data/source/pdfs vault: -v --stats 0 2>&1 | grep Copied'
run 'rclone ls vault:            # through crypt: real names'
run 'rclone ls prova:vault       # what the storage provider sees: encrypted names and contents'
run 'rclone cat prova:vault/$(rclone lsf prova:vault --files-only | head -1) | head -c 64 | od -c | head -3'
run 'rclone cryptcheck data/source/pdfs vault:   # verify without downloading'

section "4. rclone mount (FUSE) and its limitations"
rm -rf data/mnt; mkdir -p data/mnt
run 'rclone mount prova:bonus data/mnt --vfs-cache-mode writes --daemon --daemon-wait 10s && echo mounted'
run 'ls data/mnt; ls -la data/mnt/big'
run 'echo "written through the mount" > data/mnt/note.txt && rclone cat prova:bonus/note.txt || echo "(not on S3 yet)"'
note "with --vfs-cache-mode writes the file is written to a local cache and uploaded after close (--vfs-write-back, default 5s)"
run 'sleep 7; rclone cat prova:bonus/note.txt'
run 'time md5sum data/mnt/big/upload-1GB.bin   # every read becomes HTTP range requests to the server'
run 'mv data/mnt/note.txt data/mnt/renamed.txt; sleep 2; rclone lsf prova:bonus --files-only   # S3 has no rename: server-side copy + delete'
run 'fusermount -u data/mnt && echo unmounted'
note "limitations: no file locking, no hard links, rename = copy+delete, random writes need --vfs-cache-mode writes/full"
note "(local disk cache), listings are slow on big buckets, changes from other clients appear only after --dir-cache-time."
note "fine for browsing or simple tools; use copy/sync for bulk transfers and pipelines"

section "5. Scheduled sync with a systemd timer (transient, nothing installed)"
run 'systemd-analyze verify examples/systemd/rclone-backup.timer 2>&1 | grep "rclone-backup.timer" || echo "no problems reported for rclone-backup.timer"'
note "run transfer.sh from a transient user timer firing 2s from now, passing credentials via the unit environment"
run 'systemd-run --user --quiet --unit rclone-demo --on-active=2s --timer-property=AccuracySec=100ms \
  --setenv=RCLONE_S3_PROVIDER=Other --setenv=RCLONE_S3_ENDPOINT="$S3_A_ENDPOINT" \
  --setenv=RCLONE_S3_ACCESS_KEY_ID="$S3_A_ACCESS_KEY" --setenv=RCLONE_S3_SECRET_ACCESS_KEY="$S3_A_SECRET_KEY" \
  --setenv=PATH="$PATH" --working-directory="$ROOT" \
  ./transfer.sh --log-dir data/transfer-logs --verify copy data/source/docs :s3:bonus/scheduled && echo "timer scheduled"'
sleep 8
run 'journalctl --user -u rclone-demo --no-pager -o cat | grep -E "START|VERIFIED|OK|FAILED"'
run 'rclone lsf -R prova:bonus/scheduled'

section "6. Calling rclone from Python (Celery-style)"
run 'python3 examples/python/run_rclone.py data/source/pdfs :s3:bonus/python'
note "a failing transfer surfaces as an exception with rclone's exit code:"
run 'S3_A_SECRET_KEY=wrong python3 examples/python/run_rclone.py data/source/pdfs :s3:bonus/python-bad'
