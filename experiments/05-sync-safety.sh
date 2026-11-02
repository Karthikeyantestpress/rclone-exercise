#!/usr/bin/env bash
# Experiment 5: source and destination hold different versions of files.
# Preview with --dry-run, sync, keep what sync would destroy, verify with check,
# and show how sync goes wrong.
#
# Usage: experiments/05-sync-safety.sh | tee results/logs/05-sync-safety.log
source "$(dirname "$0")/lib.sh"
use_endpoint_a
SRC=data/sync-src
DST=:s3:site
rm -rf "$SRC" data/empty-dir
rclone purge "$DST" 2>/dev/null; rclone purge :s3:site-trash 2>/dev/null

section "0. Starting point: destination has version 1"
mkdir -p "$SRC"/{pages,assets}
echo "home v1"    > "$SRC/pages/index.html"
echo "about v1"   > "$SRC/pages/about.html"
echo "pricing v1" > "$SRC/pages/pricing.html"
echo "logo v1"    > "$SRC/assets/logo.svg"
run 'rclone sync data/sync-src :s3:site -v --stats 0'
note "someone uploads a file straight to the destination (not in the source)"
run 'echo "manual upload" | rclone rcat :s3:site/assets/hand-uploaded.pdf'

section "1. Source moves on to version 2"
run 'echo "home v2 - new hero section" > data/sync-src/pages/index.html          # modified'
run 'rm data/sync-src/pages/pricing.html                                         # deleted'
run 'mv data/sync-src/pages/about.html data/sync-src/pages/about-us.html         # renamed'
run 'echo "careers v1" > data/sync-src/pages/careers.html                        # new'
run 'rclone tree data/sync-src'

section "2. What differs? (read-only)"
run 'rclone check data/sync-src :s3:site --combined - 2>/dev/null   # = same  * differ  + only src  - only dst'

section "3. --dry-run: what would sync do?"
run 'rclone sync data/sync-src :s3:site --dry-run 2>&1 | grep -E "Skipped|Deleted:|Transferred:"'
note "sync would DELETE pricing.html, about.html (renames look like delete + new) AND hand-uploaded.pdf"

section "4. Sync, keeping everything it replaces or deletes"
note "--backup-dir moves deleted/overwritten objects aside instead of destroying them (server-side, no re-upload)"
run 'rclone sync data/sync-src :s3:site --backup-dir :s3:site-trash/$(date +%F) -v --stats 0'
run 'rclone tree :s3:site'
run 'rclone tree :s3:site-trash     # nothing lost: old versions + the manual upload are recoverable'
run 'rclone cat :s3:site-trash/$(date +%F)/pages/index.html   # the v1 page'

section "5. Verify"
run 'rclone check data/sync-src :s3:site'
note "--download compares actual bytes (for backends without a usable hash)"
run 'rclone check data/sync-src :s3:site --download'

section "6. Why sync is dangerous"
note "mistake 1: an empty or wrong source (failed mount, typo, unset variable) = delete everything at the destination"
run 'mkdir -p data/empty-dir'
run 'rclone sync data/empty-dir :s3:site --dry-run 2>&1 | grep -E "Skipped delete|Deleted:"'
note "guard rail: --max-delete aborts once more than N deletes would happen"
run 'rclone sync data/empty-dir :s3:site --max-delete 2 -v --stats 0 2>&1 | grep -E "Deleted|ERROR|NOTICE|error" | head -6'
run 'rclone ls :s3:site'
note "the abort stopped further deletes, but up to N files may already be gone; --dry-run first is the real protection"
run 'rclone sync data/sync-src :s3:site -v --stats 0   # restore'
note "mistake 2: swapped arguments make the DESTINATION the truth and wipe the source's new work:"
run 'echo "blog draft, not uploaded yet" > data/sync-src/pages/blog.html'
run 'rclone sync :s3:site data/sync-src --dry-run 2>&1 | grep -E "Skipped|Deleted:"'
note "the brand-new local draft would be deleted from the SOURCE. copy would never do this."
note "mistake 3: --delete-excluded with a filter deletes every destination file the filter excludes"

section "7. Safe habits"
note "use copy unless deletions are really wanted; always --dry-run a new sync first"
note "--backup-dir (or bucket versioning) so a bad sync is recoverable; --max-delete as a tripwire"
note "in scripts, refuse to sync from an empty source and quote paths so an unset variable can't become '/'"
