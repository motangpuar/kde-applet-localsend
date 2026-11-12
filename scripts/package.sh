#!/usr/bin/env bash
# Build the distributable plasmoid archive. Single source of truth for packaging:
# `make package`, CI and the release workflow all call this script, so a locally
# verified build is exactly what ships.
#
# The archive is what a user installs with
#   kpackagetool6 --type Plasma/Applet --install io.github.localsend.plasmoid-<version>.plasmoid
# and it contains the guarded Python backend, so nothing is fetched at install time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/plasmoid/io.github.localsend.plasmoid"
OUT_DIR="${OUT_DIR:-$HERE/build}"
VERSION=""
SELECTED_PYTHON="${PYTHON:-python3}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '%s\n' "package.sh: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: scripts/package.sh [--version X.Y.Z] [--out DIR]

  --version  stamp this version into the archive's metadata.json (release builds);
             defaults to the version already in the source metadata.json
  --out      output directory (default: ./build)

prints the archive path and its sha256 on stdout, one per line.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --out)     OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         die "unknown argument: $1" ;;
    esac
done

[ -f "$SRC/metadata.json" ] || die "missing $SRC/metadata.json"
command -v zip >/dev/null 2>&1 || die "zip is required"
[ -x "$SELECTED_PYTHON" ] || command -v "$SELECTED_PYTHON" >/dev/null 2>&1 \
    || die "python3 is required to validate the archive"

PLASMOID_ID="$(basename "$SRC")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "1/4 staging $PLASMOID_ID"
mkdir -p "$OUT_DIR"
# The archive is written from inside the staging dir, so the output path must be absolute.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
STAGE="$WORK/$PLASMOID_ID"
mkdir -p "$STAGE"
cp -a "$SRC/." "$STAGE/"

# The backend payload is gitignored on purpose: stage it from the canonical sources
# so a fresh clone (and every CI run) produces a complete, runnable package.
BACKEND="$STAGE/contents/backend"
[ -d "$BACKEND" ] || die "missing contents/backend"
install -m755 "$HERE/python/localsendd" "$BACKEND/localsendd"
install -m755 "$HERE/python/localsendctl" "$BACKEND/localsendctl"
chmod 755 "$BACKEND/manage.sh"
find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$STAGE" -name '*.py[co]' -delete

say "2/4 validating metadata"
VERSION="$("$SELECTED_PYTHON" - "$STAGE/metadata.json" "$PLASMOID_ID" "$VERSION" <<'PY'
import json, re, sys
from pathlib import Path

path, expected_id, override = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
meta = json.loads(path.read_text())
plugin = meta.get("KPlugin") or {}
if plugin.get("Id") != expected_id:
    sys.exit(f"metadata Id {plugin.get('Id')!r} != directory name {expected_id!r}")
version = override or plugin.get("Version")
if not version:
    sys.exit("metadata.json has no KPlugin.Version and --version was not given")
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    sys.exit(f"version {version!r} is not MAJOR.MINOR.PATCH")
if override:
    plugin["Version"] = version
    path.write_text(json.dumps(meta, indent=2) + "\n")
for key, value in list(plugin.items()) + list(meta.items()):
    if isinstance(value, str) and "{" in value:
        sys.exit(f"unexpanded placeholder in metadata.json: {value!r}")
print(version)
PY
)"

say "3/4 building the archive (${PLASMOID_ID} ${VERSION})"
ARCHIVE="$OUT_DIR/${PLASMOID_ID}-${VERSION}.plasmoid"
rm -f "$ARCHIVE"
( cd "$STAGE" && zip -rq -X "$ARCHIVE" metadata.json contents )

say "4/4 verifying the archive"
"$SELECTED_PYTHON" - "$ARCHIVE" "$PLASMOID_ID" "$VERSION" <<'PY'
import json, sys, zipfile
from pathlib import Path

archive, expected_id, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
required = {
    "metadata.json",
    "contents/ui/main.qml",
    "contents/ui/FullRepresentation.qml",
    "contents/ui/CompactRepresentation.qml",
    "contents/config/main.xml",
    "contents/backend/manage.sh",
    "contents/backend/localsendd",
    "contents/backend/localsendctl",
    "contents/icons/" + expected_id + ".svg",
    "contents/icons/" + expected_id + "-symbolic.svg",
}
with zipfile.ZipFile(archive) as zf:
    names = {n for n in zf.namelist() if not n.endswith("/")}
    missing = sorted(required - names)
    if missing:
        sys.exit(f"archive is missing: {', '.join(missing)}")
    leaked = sorted(n for n in names if "__pycache__" in n or n.endswith(".pyc"))
    if leaked:
        sys.exit(f"archive carries build noise: {', '.join(leaked)}")
    if any(n.startswith("/") or ".." in Path(n).parts for n in names):
        sys.exit("archive contains unsafe paths")
    meta = json.loads(zf.read("metadata.json"))
    if meta["KPlugin"]["Id"] != expected_id:
        sys.exit("archive metadata Id does not match the file name")
    if meta["KPlugin"]["Version"] != version:
        sys.exit("archive metadata version does not match the stamped version")
    for name in ("contents/backend/localsendd", "contents/backend/localsendctl",
                 "contents/backend/manage.sh"):
        mode = zf.getinfo(name).external_attr >> 16
        if not mode & 0o111:
            sys.exit(f"{name} is not executable inside the archive (mode {mode:o})")
print(f"ok: {len(names)} files, id {expected_id} {version}")
PY

printf '%s\n' "$ARCHIVE"
sha256sum "$ARCHIVE" | awk '{print $1}'
