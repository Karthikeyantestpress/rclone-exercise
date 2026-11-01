#!/usr/bin/env bash
# Experiment 1: basic operations between two local directories that stand in
# for two storage locations.
#
#   data/source  --copy/sync-->  data/site-a  --sync-->  data/site-b
#
# Usage: experiments/01-local-operations.sh | tee results/logs/01-local-operations.log
source "$(dirname "$0")/lib.sh"

SRC=data/source
A=data/site-a
B=data/site-b
rm -rf "$A" "$B" data/inbox

section "1. Listing"
run "rclone ls $SRC                 # every file, with size (recursive)"
run "rclone lsd $SRC                # directories at the top level"
run "rclone lsf -R --format pst $SRC # path;size;modtime, machine-readable"
run "rclone tree $SRC"
run "rclone size $SRC"

section "2. copy: new files only, never deletes"
run "rclone copy $SRC $A -v"
note "running the SAME copy again: everything matches by size+modtime, nothing is transferred"
run "rclone copy $SRC $A -v"
note "a file that exists only at the destination survives copy"
run "echo 'only at site-a' > $A/extra-at-destination.txt"
run "rclone copy $SRC $A -v"
run "rclone lsf $A"
note "an updated source file is copied again (size/modtime changed)"
run "echo 'second line' >> $SRC/docs/readme.txt"
run "rclone copy $SRC $A -v"

section "3. move: copy, then delete from the source"
run "mkdir -p data/inbox/2026 $A/processed && echo 'uploaded report' > data/inbox/upload-1.txt && echo 'uploaded slide' > data/inbox/2026/upload-2.txt"
run "rclone move data/inbox $A/processed -v"
run "rclone lsf -R data/inbox   # files are gone from the source, the empty 2026/ folder stays"
run "rclone lsf -R $A/processed"
note "--delete-empty-src-dirs also removes the emptied source folders"
run "echo 'late upload' > data/inbox/2026/upload-3.txt"
run "rclone move data/inbox $A/processed -v --delete-empty-src-dirs"
run "rclone lsf -R data/inbox"
note "if the destination folder does NOT exist yet, local->local move just renames the whole directory (no data copied)"

section "4. sync: make the destination identical to the source"
run "rclone sync $SRC $B -v"
run "echo 'stale file' > $B/old-export.csv"
note "--dry-run first: shows what WOULD be deleted, changes nothing"
run "rclone sync $SRC $B --dry-run"
run "rclone sync $SRC $B -v"
run "rclone lsf $B   # old-export.csv is gone"

section "5. Deleting from a destination"
run "rclone deletefile $A/extra-at-destination.txt -v        # one file"
run "rclone delete $A --include '*.txt' --dry-run            # filter preview"
run "rclone delete $A/processed -v                           # all files under a path"
run "rclone rmdirs $A -v                                     # remove now-empty directories"
run "rclone lsf -R $A"

section "6. check: are two locations identical?"
run "rclone check $SRC $B                      # compares sizes + hashes (MD5/SHA1 for local)"
note "corrupt a file WITHOUT changing its size or modtime (like silent bit rot or a bad disk)"
run "printf '%-37s\\n' 'TAMPERED' > $B/docs/notes/2026/todo.txt   # same 38 bytes"
run "touch -r $SRC/docs/notes/2026/todo.txt $B/docs/notes/2026/todo.txt   # same modtime, different content"
run "rclone check $SRC $B"
note "copy compares size+modtime by default, so it MISSES this change:"
run "rclone copy $SRC $B -v --dry-run"
note "--checksum compares hashes instead and catches it"
run "rclone copy $SRC $B -v --checksum"
run "rclone check $SRC $B --combined -   # per-file report: = same, * differ, + only in src, - only in dst"

# restore the edited source file so later experiments start clean
sed -i '$d' "$SRC/docs/readme.txt"
