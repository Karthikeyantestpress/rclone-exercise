#!/usr/bin/env bash
# Generate the sample dataset used by the experiments (into data/, gitignored).
#
#   data/source/
#   ├── docs/readme.txt
#   ├── docs/notes/2026/meeting-notes.txt
#   ├── docs/notes/2026/todo.txt
#   ├── pdfs/invoice-001.pdf
#   ├── pdfs/reports/q3-report.pdf
#   └── videos/lecture-100MB.bin      (random, incompressible)
#   data/big/upload-1GB.bin            (only with --big)
#
# Usage: scripts/make-sample-data.sh [--big]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/data/source"

mkdir -p "$SRC"/{docs/notes/2026,pdfs/reports,videos}

echo "Testpress sample dataset for rclone experiments." > "$SRC/docs/readme.txt"
printf 'Meeting notes\n- migrate video storage\n- verify backups\n' > "$SRC/docs/notes/2026/meeting-notes.txt"
printf 'TODO\n1. rclone check after every sync\n' > "$SRC/docs/notes/2026/todo.txt"

# Small but valid PDFs (one page with a line of text), written without
# extra tools so the dataset is reproducible anywhere python3 exists.
make_pdf() {
  python3 -I - "$1" "$2" <<'EOF'
import sys
path, text = sys.argv[1], sys.argv[2]
stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode()
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
out, offsets = bytearray(b"%PDF-1.4\n"), []
for i, body in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(path, "wb").write(out)
EOF
}
make_pdf "$SRC/pdfs/invoice-001.pdf" "Invoice 001 - Testpress"
make_pdf "$SRC/pdfs/reports/q3-report.pdf" "Q3 Report - TPStreams"

# Random data: compression and dedup can't make the transfer look faster.
[[ -f "$SRC/videos/lecture-100MB.bin" ]] || head -c 100M /dev/urandom > "$SRC/videos/lecture-100MB.bin"

if [[ "${1:-}" == "--big" ]]; then
  mkdir -p "$ROOT/data/big"
  [[ -f "$ROOT/data/big/upload-1GB.bin" ]] || head -c 1G /dev/urandom > "$ROOT/data/big/upload-1GB.bin"
fi

echo "sample data ready:"
du -ah "$ROOT/data" | sort -k2
