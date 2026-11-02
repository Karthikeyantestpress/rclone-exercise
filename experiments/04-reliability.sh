#!/usr/bin/env bash
# Experiment 4: large files, concurrency, bandwidth, progress, retries,
# and an interrupted transfer that is restarted.
#
# Requires: scripts/make-sample-data.sh --big, scripts/s3-servers.sh start
# Usage: experiments/04-reliability.sh | tee results/logs/04-reliability.log
source "$(dirname "$0")/lib.sh"
use_endpoint_a
TIMEFORMAT='elapsed: %Rs'

# Six 25MB files plus the 1GB file (hard link, no extra disk space)
REL=data/reliability
mkdir -p "$REL"
for i in 1 2 3 4 5 6; do [[ -f $REL/part-$i-25MB.bin ]] || head -c 25M /dev/urandom > $REL/part-$i-25MB.bin; done
[[ -f $REL/upload-1GB.bin ]] || ln data/big/upload-1GB.bin $REL/upload-1GB.bin
rclone purge :s3:big 2>/dev/null; rclone mkdir :s3:big

restart_a() { scripts/s3-servers.sh start >/dev/null; }
# SIGKILL: an abrupt crash. (SIGTERM lets the server finish in-flight uploads first.)
kill_a()    { kill -9 "$(cat data/run/s3-a.pid)"; rm -f data/run/s3-a.pid; }

section "1. Upload a 1GB file (multipart)"
note "files above --s3-upload-cutoff (200M default) go up as multipart: chunks uploaded in parallel"
run 'time rclone copy data/big/upload-1GB.bin :s3:big/single/ --s3-chunk-size 64M --s3-upload-concurrency 4 --stats 5s --stats-one-line -v'
run 'rclone ls :s3:big/single'
note "multipart ETags are not plain MD5s; rclone stores the MD5 as object metadata, so check still verifies content"
run 'rclone check data/big :s3:big/single'

section "2. Concurrent transfers (--transfers)"
note "6 x 25MB files, one at a time vs. all six in parallel"
run 'time rclone copy data/reliability :s3:big/t1 --exclude upload-1GB.bin --transfers 1 --stats-one-line --stats 0'
run 'time rclone copy data/reliability :s3:big/t6 --exclude upload-1GB.bin --transfers 6 --stats-one-line --stats 0'
note "with network latency per request (real S3), more transfers hide latency; on loopback the disk/CPU dominate"

section "3. Bandwidth limit (--bwlimit)"
run 'time rclone copy data/source/videos/lecture-100MB.bin :s3:big/bw/ --bwlimit 20M --stats 2s --stats-one-line -v'
note "100MB at 20MiB/s should take ~5s. --bwlimit also takes a timetable, e.g. \"08:00,5M 19:00,off\""

section "4. Progress and statistics"
note "--progress redraws one live block in a terminal; for logs use periodic stats lines:"
run 'rclone copy data/reliability :s3:big/stats --exclude upload-1GB.bin --transfers 2 --bwlimit 50M --stats 1s -v 2>&1 | grep -E "Transferred:|Elapsed|ETA" | head -12'
note "machine-readable stats for monitoring:"
run 'rclone copy data/source/docs :s3:big/json --use-json-log --stats 1s -v 2>&1 | grep -m1 "\"stats\"" | cut -c1-300'

section "5. Retries while the server goes away"
note "server A is killed (SIGKILL) 3s into a 100MB upload and restarted 6s later; -vv shows the retry messages"
note "--low-level-retries retries individual HTTP requests; --retries re-runs the whole sync for files that still failed"
run '( sleep 3; kill_a; echo ">>> $(date +%T) server A killed"; sleep 6; restart_a; echo ">>> $(date +%T) server A restarted" ) &
rclone copy data/source/videos/lecture-100MB.bin :s3:big/retry/ --bwlimit 10M --retries 5 --retries-sleep 3s --low-level-retries 3 --timeout 5s --contimeout 2s -vv --stats 0 2>&1 | grep -E "low level retry|Attempt|Failed to copy|Copied" | cut -c1-170
wait'
run 'rclone check data/source/videos :s3:big/retry'

section "6. Interrupted transfer, then restart"
note "simulate a crash: SIGKILL rclone 15s into uploading 6x25MB + 1GB (no chance to clean up)"
run 'timeout -s KILL 15 rclone copy data/reliability :s3:big/resume --transfers 2 --bwlimit 40M -v --stats 0 2>&1 | grep -E "Copied|ERROR"'
run 'rclone ls :s3:big/resume   # what made it before the crash'
note "the half-uploaded 1GB file is not visible as an object, but its parts sit on the server as an unfinished multipart upload"
run 'rclone backend list-multipart-uploads :s3:big'
note "restart the same command: finished files are skipped (only checked), unfinished ones transferred"
run 'time rclone copy data/reliability :s3:big/resume --transfers 2 -v --stats 0 2>&1 | grep -E "Copied|ERROR|nothing to transfer"'
run 'rclone check data/reliability :s3:big/resume'
note "abandoned multipart parts cost storage on real S3: clean them up (or use a bucket lifecycle rule)"
run 'rclone backend cleanup :s3:big -o max-age=0s'
run 'rclone backend list-multipart-uploads :s3:big'

section "7. Local destination: .partial files"
note "for local/SFTP destinations rclone writes to <name>.<random>.partial and renames on success"
rm -rf data/local-resume
run 'timeout -s KILL 2 rclone copy data/big data/local-resume --bwlimit 100M -v --stats 0; ls -la data/local-resume'
run 'rclone copy data/big data/local-resume -v --stats 0 2>&1 | grep -E "Copied|nothing"; ls -la data/local-resume'
