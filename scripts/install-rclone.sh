#!/usr/bin/env bash
# Install a pinned rclone version into ~/.local/bin without sudo.
# The download is verified against the official SHA256SUMS before use.
#
# Usage: scripts/install-rclone.sh [version]     (default: v1.75.2)
set -euo pipefail

VERSION="${1:-v1.75.2}"
DEST="${DEST:-$HOME/.local/bin}"
NAME="rclone-$VERSION-linux-amd64"
BASE="https://downloads.rclone.org/$VERSION"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/$NAME.zip" "$BASE/$NAME.zip"
curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"
(cd "$TMP" && grep " $NAME.zip\$" SHA256SUMS | sha256sum -c -)

# unzip is often missing on minimal systems; python3 is not
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$TMP/$NAME.zip" "$TMP"

mkdir -p "$DEST"
install -m 0755 "$TMP/$NAME/rclone" "$DEST/rclone"
"$DEST/rclone" version | head -1
case ":$PATH:" in *":$DEST:"*) ;; *) echo "add $DEST to your PATH";; esac
