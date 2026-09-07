#!/usr/bin/env bash
# Optional project-local macOS build; leaves Homebrew and PATH unchanged.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")" && pwd -P)
if [ "${1:-}" = --help ]; then
  echo 'Usage: ./install-cpulimit.sh [--archive PATH]'
  echo 'Build cpulimit 0.2 with a Mach-timebase correction into bin/cpulimit/ on macOS.'
  echo 'Optional offline archive must match the pinned upstream SHA256.'
  exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo 'Use your Linux package manager, e.g. sudo apt install cpulimit' >&2; exit 1; }
ARCHIVE=''
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --archive ] || { echo 'Use --help for usage' >&2; exit 2; }
  ARCHIVE=$(realpath "$2")
fi
for dep in cc make curl tar patch shasum; do command -v "$dep" >/dev/null || { echo "Install missing build dependency: $dep" >&2; exit 1; }; done
DEST="$PROJECT/bin/cpulimit"
if [ -d "$DEST" ]; then
  (cd "$DEST" && shasum -a 256 -c binary.sha256) >&2
  # Upstream 0.2 prints valid help but exits with status 1.
  "$DEST/cpulimit" --help 2>&1 | grep -q "Usage:" || [ "${PIPESTATUS[1]}" = 0 ]
  printf '%s\n' "$DEST/cpulimit"
  exit 0
fi
mkdir -p "$PROJECT/bin"
WORK=$(mktemp -d "$PROJECT/bin/.cpulimit-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$ARCHIVE" ]; then cp "$ARCHIVE" "$WORK/source.tar.gz"
else
  curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 120 \
    https://github.com/opsengine/cpulimit/archive/refs/tags/v0.2.tar.gz -o "$WORK/source.tar.gz"
fi
SHA=64312f9ac569ddcadb615593cd002c94b76e93a0d4625d3ce1abb49e08e2c2da
[ "$(shasum -a 256 "$WORK/source.tar.gz" | awk '{print $1}')" = "$SHA" ] || { echo 'Upstream archive SHA256 mismatch' >&2; exit 1; }
mkdir "$WORK/source"
tar -xzf "$WORK/source.tar.gz" -C "$WORK/source" --strip-components=1
patch -p1 -d "$WORK/source" -i "$PROJECT/patches/cpulimit-apple-timebase.patch" >&2
# libgen.h fixes the upstream 0.2 basename declaration with modern Clang.
make -C "$WORK/source/src" CC=cc CFLAGS='-Wall -O2 -D_GNU_SOURCE -include libgen.h' >&2
mkdir "$WORK/install"
cp "$WORK/source/src/cpulimit" "$WORK/install/"
cp "$WORK/source/LICENSE" "$WORK/install/"
cp "$WORK/source.tar.gz" "$WORK/install/upstream-v0.2.tar.gz"
cp "$PROJECT/patches/cpulimit-apple-timebase.patch" "$WORK/install/"
printf 'version=0.2\nfix=apple-mach-timebase\nsource_sha256=%s\n' "$SHA" > "$WORK/install/receipt.txt"
(cd "$WORK/install" && shasum -a 256 cpulimit > binary.sha256)
"$WORK/install/cpulimit" --help > "$WORK/help.txt" 2>&1 || true
grep -q "Usage:" "$WORK/help.txt"
# Reserve the destination before publishing; never overwrite another installation.
mkdir "$DEST"
cp -p "$WORK/install/"* "$DEST/"
printf '%s\n' "$DEST/cpulimit"
