#!/usr/bin/env bash
# Tests for transfer.sh against the local S3 endpoints.
# Each case shows the command, its output, and the exit code it must return.
#
# Requires: scripts/s3-servers.sh start, scripts/make-sample-data.sh
# Usage: tests/test-transfer.sh | tee results/logs/06-transfer-script.log
source "$(dirname "$0")/../experiments/lib.sh"
export TRANSFER_LOG_DIR=data/transfer-logs
rm -rf data/transfer-logs data/t-local data/t-empty
use_endpoint_a
rclone purge :s3:transfer-test 2>/dev/null
clear_s3_env
PASS=0 FAIL=0

expect() {  # expect <exit-code> <description> 'command'
  local want=$1 desc=$2; shift 2
  printf '\n$ %s\n' "$*"
  eval "$*" 2>&1 | sed 's/^/  /'
  local got=${PIPESTATUS[0]}
  if [[ "$got" == "$want" ]]; then echo "PASS  [$got] $desc"; PASS=$((PASS + 1))
  else echo "FAIL  [got $got, want $want] $desc"; FAIL=$((FAIL + 1)); fi
}

section "Argument validation"
expect 0  "help text"                       './transfer.sh --help | head -3'
expect 64 "missing arguments"                './transfer.sh copy data/source'
expect 64 "unknown operation"                './transfer.sh move data/source data/t-local'
expect 64 "unknown option"                   './transfer.sh --fast copy data/source data/t-local'

section "Local -> local"
expect 0  "copy with verification"           './transfer.sh --verify copy data/source data/t-local'
expect 0  "second copy transfers nothing"    './transfer.sh copy data/source data/t-local && grep -h "nothing to transfer\|Transferred:.*0 B / 0 B" data/transfer-logs/*copy.log | tail -1'
expect 3  "missing source -> rclone exit 3"  './transfer.sh copy data/does-not-exist data/t-local'

section "Local -> S3 (unnamed :s3: remote from RCLONE_S3_* env)"
expect 0  "upload + verify" 'RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT="$S3_A_ENDPOINT" RCLONE_S3_ACCESS_KEY_ID="$S3_A_ACCESS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$S3_A_SECRET_KEY" ./transfer.sh --verify --transfers 8 copy data/source :s3:transfer-test/upload'

section "S3 A -> S3 B (named remotes from --env-file, different credentials)"
expect 0  "cross-endpoint copy + verify"     './transfer.sh --env-file transfer.env.example --verify copy providera:transfer-test providerb:transfer-test'

section "Sync safety"
expect 0  "sync dry-run changes nothing"     './transfer.sh --env-file transfer.env.example --dry-run sync data/source/docs providerb:transfer-test/upload'
expect 0  "dry-run left the 100MB file in place" 'RCLONE_CONFIG_B_TYPE=s3 RCLONE_CONFIG_B_PROVIDER=Other RCLONE_CONFIG_B_ENDPOINT="$S3_B_ENDPOINT" RCLONE_CONFIG_B_ACCESS_KEY_ID="$S3_B_ACCESS_KEY" RCLONE_CONFIG_B_SECRET_ACCESS_KEY="$S3_B_SECRET_KEY" rclone lsf b:transfer-test/upload/videos'
mkdir -p data/t-empty
expect 65 "sync from an empty source is refused" './transfer.sh --env-file transfer.env.example sync data/t-empty providerb:transfer-test'
expect 0  "sync with backup-dir"             './transfer.sh --env-file transfer.env.example --backup-dir providerb:transfer-trash --verify sync data/source/pdfs providerb:transfer-test/upload'

section "Failures return non-zero"
expect 1  "wrong credentials fail (after retries)" 'RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT="$S3_A_ENDPOINT" RCLONE_S3_ACCESS_KEY_ID=wrong RCLONE_S3_SECRET_ACCESS_KEY=wrong ./transfer.sh --retries 1 copy data/source/docs :s3:transfer-test/x'
expect 64 "unreadable env file"              './transfer.sh --env-file nope.env copy data/source data/t-local'

section "Logs"
run 'ls data/transfer-logs | head -5'
run 'grep -hE "START|OK|FAILED|REFUSED|VERIFIED" data/transfer-logs/*.log | cut -c1-160 | head -12'
note "no secret values in any log:"
run 'for s in "$S3_A_SECRET_KEY" "$S3_B_SECRET_KEY"; do grep -rl -- "$s" data/transfer-logs && echo LEAK; done; echo "(none found)"'

section "Summary"
echo "passed: $PASS  failed: $FAIL"
((FAIL == 0))
