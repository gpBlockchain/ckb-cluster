#!/usr/bin/env bash
# Download an official CKB release without changing PATH or running clusters.
set -euo pipefail
umask 022
PROJECT_DIR=$(cd "$(dirname "$0")" && pwd -P)
VERSION=latest OUT="$PROJECT_DIR/bin/ckb" PORTABLE='' PRINT_URL=0 EXPECTED_SHA=''
ARCH=$(uname -m)
usage() {
  cat <<'EOF'
Usage: ./download-ckb.sh [VERSION|latest] [OPTIONS]
  --version VERSION   e.g. v0.209.0 or 0.209.0; default: latest stable release
  --output-dir DIR    default: PROJECT/bin/ckb
  --arch ARCH         x86_64 or aarch64 (arm64 accepted); default: uname -m
  --portable          use the portable CPU build when available
  --sha256 HASH       expected archive checksum (needed for old assets without a digest)
  --print-url         resolve version/platform and print URL; do not download
  -h, --help

Examples:
  ./download-ckb.sh
  ./download-ckb.sh v0.209.0
  ./download-ckb.sh --version 0.209.0 --portable

Requires Bash, curl, jq, shasum (or sha256sum), unzip (macOS) / tar (Linux).
Installs only ckb into VERSION/PLATFORM/ckb; existing versions are not overwritten.
Stdout contains the installed absolute binary path; progress goes to stderr.
EOF
}
die() { echo "ERROR: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --portable) PORTABLE=-portable; shift;;
    --print-url) PRINT_URL=1; shift;;
    --version|--output-dir|--arch|--sha256)
      [ $# -ge 2 ] || die "Missing value: $1"
      case "$1" in --version) VERSION=$2;; --output-dir) OUT=$2;; --arch) ARCH=$2;; --sha256) EXPECTED_SHA=$2;; esac
      shift 2;;
    latest|v[0-9]*|[0-9]*) VERSION=$1; shift;;
    *) die "Unknown argument: $1";;
  esac
done
case "$ARCH" in arm64|aarch64) ARCH=aarch64;; x86_64|amd64) ARCH=x86_64;; *) die "Unsupported architecture: $ARCH";; esac
case "$(uname -s)" in
  Darwin) TARGET="$ARCH-apple-darwin$PORTABLE"; EXT=zip;;
  Linux) TARGET="$ARCH-unknown-linux-gnu$PORTABLE"; EXT=tar.gz;;
  *) die 'Supported systems: macOS and Linux';;
esac
for dep in curl jq; do command -v "$dep" >/dev/null || die "Missing dependency: $dep"; done
if [ "$VERSION" = latest ]; then ENDPOINT=latest
else
  VERSION=v${VERSION#v}
  [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die 'Invalid version format'
  ENDPOINT="tags/$VERSION"
fi
fetch() {
  curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error \
    --connect-timeout 15 --max-time 300 --retry 2 "$@"
}
META=$(fetch "https://api.github.com/repos/nervosnetwork/ckb/releases/$ENDPOINT")
TAG=$(printf '%s' "$META" | jq -er '.tag_name')
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die 'Unexpected release tag'
if [ "$VERSION" = latest ]; then
  printf '%s' "$META" | jq -e '.draft==false and .prerelease==false' >/dev/null || die 'Expected stable release'
else [ "$TAG" = "$VERSION" ] || die 'Release tag mismatch'; fi
NAME="ckb_${TAG}_${TARGET}.$EXT"
ASSET=$(printf '%s' "$META" | jq -ce --arg name "$NAME" '[.assets[] | select(.name==$name)] | if length==1 then .[0] else error("No unique matching release asset: "+$name) end')
URL=$(printf '%s' "$ASSET" | jq -er '.browser_download_url')
[ "$URL" = "https://github.com/nervosnetwork/ckb/releases/download/$TAG/$NAME" ] || die 'Unexpected asset URL'
echo "Release: $TAG | Platform: $TARGET" >&2
if [ "$PRINT_URL" = 1 ]; then printf '%s\n' "$URL"; exit 0; fi
DIGEST=$(printf '%s' "$ASSET" | jq -r '.digest // ""')
if [ -z "$EXPECTED_SHA" ]; then EXPECTED_SHA=${DIGEST#sha256:}; fi
[[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || die 'This asset has no SHA256 digest; supply --sha256 from a trusted checksum source'
EXPECTED_SHA=$(printf '%s' "$EXPECTED_SHA" | tr 'A-F' 'a-f')
if command -v shasum >/dev/null; then HASH=(shasum -a 256)
elif command -v sha256sum >/dev/null; then HASH=(sha256sum)
else die 'Install shasum or sha256sum'; fi
if [ "$EXT" = zip ]; then command -v unzip >/dev/null || die 'Install unzip'
else command -v tar >/dev/null || die 'Install tar'; fi
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
DEST="$OUT/$TAG/$TARGET"
if [ -e "$DEST" ]; then
  [ -f "$DEST/receipt.json" ] && [ -x "$DEST/ckb" ] || die "Incomplete existing installation: $DEST"
  jq -e --arg sha "$EXPECTED_SHA" --arg url "$URL" '.archive_sha256==$sha and .url==$url' "$DEST/receipt.json" >/dev/null || die 'Existing installation has a different receipt'
  ACTUAL=$("${HASH[@]}" "$DEST/ckb" | awk '{print $1}')
  [ "$ACTUAL" = "$(jq -er '.binary_sha256' "$DEST/receipt.json")" ] || die 'Existing binary checksum changed'
  echo 'Verified existing download; no overwrite.' >&2
  printf '%s\n' "$DEST/ckb"; exit 0
fi
WORK=$(mktemp -d "$OUT/.download.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Downloading $NAME" >&2
fetch "$URL" -o "$WORK/archive.$EXT"
ACTUAL=$("${HASH[@]}" "$WORK/archive.$EXT" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED_SHA" ] || die "SHA256 mismatch: expected=$EXPECTED_SHA actual=$ACTUAL"
# Extract only the expected regular binary, not arbitrary archive paths/links.
MEMBER="ckb_${TAG}_${TARGET}/ckb"
mkdir "$WORK/install"
if [ "$EXT" = zip ]; then
  [ "$(unzip -Z1 "$WORK/archive.$EXT" | grep -Fxc "$MEMBER")" -eq 1 ] || die 'Missing or duplicate ckb archive member'
  unzip -p "$WORK/archive.$EXT" "$MEMBER" > "$WORK/install/ckb"
else
  [ "$(tar -tzf "$WORK/archive.$EXT" | grep -Fxc "$MEMBER")" -eq 1 ] || die 'Missing or duplicate ckb archive member'
  tar -xOzf "$WORK/archive.$EXT" "$MEMBER" > "$WORK/install/ckb"
fi
[ -s "$WORK/install/ckb" ] || die 'Empty ckb executable'
chmod 755 "$WORK/install/ckb"
BINARY_SHA=$("${HASH[@]}" "$WORK/install/ckb" | awk '{print $1}')
jq -n --arg tag "$TAG" --arg target "$TARGET" --arg url "$URL" --arg sha "$ACTUAL" --arg binary "$BINARY_SHA" \
  '{tag:$tag,target:$target,url:$url,archive_sha256:$sha,binary_sha256:$binary}' > "$WORK/install/receipt.json"
mkdir -p "$OUT/$TAG"
# Reserve destination atomically; never overwrite an existing version.
mkdir "$DEST" || die "Another download created $DEST; retry"
mv "$WORK/install/ckb" "$WORK/install/receipt.json" "$DEST/"
echo "SHA256 verified: $ACTUAL" >&2
printf '%s\n' "$DEST/ckb"
