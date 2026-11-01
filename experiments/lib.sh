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

section() { printf '\n==================== %s ====================\n' "$*"; }
note()    { printf '# %s\n' "$*"; }
# run 'command string': echo it, then run it; never abort the experiment
run()     { printf '\n$ %s\n' "$*"; eval "$*" 2>&1; local rc=$?; ((rc == 0)) || echo "(exit code $rc)"; return 0; }
