# Shared helpers for the experiment scripts (sourced, not executed).
#
# Each experiment prints every command before running it, so its log in
# results/logs/ reads as "command, then real output".

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/data"
export PATH="$HOME/.local/bin:$PATH"

# Never read or write a persistent rclone.conf: every remote in these
# experiments is configured on the fly. An empty value = in-memory config.
export RCLONE_CONFIG=""

# run from the repo root so logs show short relative paths
cd "$ROOT" || exit 1

# S3 endpoints + credentials come from .env, into the environment only.
# Commands below are written in single quotes so the logs show "$S3_A_..."
# variable names, never the secret values.
if [[ -f .env ]]; then set -a; source .env; set +a; fi

# Use endpoint A as the default ":s3:" backend via RCLONE_S3_* variables.
use_endpoint_a() {
  export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT="$S3_A_ENDPOINT"
  export RCLONE_S3_ACCESS_KEY_ID="$S3_A_ACCESS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$S3_A_SECRET_KEY"
}
clear_s3_env() { unset RCLONE_S3_PROVIDER RCLONE_S3_ENDPOINT RCLONE_S3_ACCESS_KEY_ID RCLONE_S3_SECRET_ACCESS_KEY; }

section() { printf '\n==================== %s ====================\n' "$*"; }
note()    { printf '# %s\n' "$*"; }
# run 'command string': echo it, then run it; never abort the experiment
run()     { printf '\n$ %s\n' "$*"; eval "$*" 2>&1; local rc=$?; ((rc == 0)) || echo "(exit code $rc)"; return 0; }
