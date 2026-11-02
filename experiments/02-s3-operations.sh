#!/usr/bin/env bash
# Experiment 2: bucket and object operations on the local S3 endpoint A.
#
# No rclone.conf: ":s3:" is an on-the-fly remote whose settings come from
# RCLONE_S3_* environment variables (set by use_endpoint_a from .env).
# Experiment 3 covers the other config-free styles in detail.
#
# Requires: scripts/s3-servers.sh start   (or docker compose up -d)
# Usage: experiments/02-s3-operations.sh | tee results/logs/02-s3-operations.log
source "$(dirname "$0")/lib.sh"
use_endpoint_a
rclone purge :s3:videos 2>/dev/null; rclone purge :s3:backups 2>/dev/null; rm -rf data/downloaded

section "0. Which config is in use?"
run 'rclone config file                    # RCLONE_CONFIG="" -> no file at all'
run 'env | grep ^RCLONE_S3_ | sed "s/=.*/=<set>/"   # settings come from the environment'

section "1. Create buckets"
run 'rclone mkdir :s3:videos'
run 'rclone mkdir :s3:backups'
run 'rclone lsd :s3:                       # list buckets'

section "2. Upload"
run 'rclone copy data/source :s3:videos -v --stats-one-line'

section "3. List objects"
run 'rclone ls :s3:videos'
run 'rclone lsf -R --format "pth" --hash MD5 :s3:videos   # path;modtime;MD5'
run 'rclone tree :s3:videos'
run 'rclone size :s3:videos'
note "S3 has no real folders: docs/notes/ is just a common prefix of object keys"
run 'rclone lsjson :s3:videos/docs --recursive | head -12'

section "4. Download"
run 'rclone copy :s3:videos/pdfs data/downloaded/pdfs -v'
run 'rclone copy :s3:videos/videos/lecture-100MB.bin data/downloaded/ -v --stats-one-line'
run 'rclone check data/source/pdfs data/downloaded/pdfs'
run 'cmp data/source/videos/lecture-100MB.bin data/downloaded/lecture-100MB.bin && echo "100MB file: byte-identical"'

section "5. Copy between two buckets (same endpoint)"
note "both buckets live on the same server, so rclone asks the server to copy (no data through this machine)"
run 'rclone copy :s3:videos :s3:backups -v'
run 'rclone check :s3:videos :s3:backups'
note "upload integrity: local file MD5 vs object ETag (MD5) on the server"
run 'rclone check data/source :s3:videos'

section "6. Delete objects"
run 'rclone deletefile :s3:backups/docs/readme.txt -v              # one object'
run 'rclone delete :s3:backups --include "*.pdf" -v                # by filter'
run 'rclone lsf -R :s3:backups'
run 'rclone purge :s3:backups -v                                   # all objects + the bucket'
run 'rclone lsd :s3:'
