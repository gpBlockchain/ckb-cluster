#!/usr/bin/env bash
# Resolver-only regression tests; no network or running nodes required.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=${1:-$PROJECT/ckb-cluster.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ckb-default.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/project with spaces" "$WORK/path" "$WORK/root"
FIXTURE="$WORK/project with spaces"
# Exercise the actual option/config parsing and resolver, stopping before runtime.
awk '/^# Never source configuration/{exit} {print}' "$SCRIPT" > "$FIXTURE/ckb-cluster.sh"
printf '\nneed_ckb\nprintf "RESOLVED=%%s\\n" "$CKB_BIN"\n' >> "$FIXTURE/ckb-cluster.sh"
for dep in jq curl awk lsof realpath dirname date; do
  ln -s "$(command -v "$dep")" "$WORK/path/$dep"
done
cat > "$WORK/path/uname" <<'UNAME'
#!/bin/bash
case "$1" in -m) echo "${TEST_ARCH:-x86_64}";; -s) echo "${TEST_OS:-Darwin}";; esac
UNAME
chmod +x "$WORK/path/uname"
make_binary() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/bash\n[ "$1" = --version ]\n' > "$1"
  chmod +x "$1"
}
run_case() {
  local name=$1 expected=$2 needle=$3 rc=0 output
  shift 3
  output=$(cd /; env -u CKB_BIN PATH="$WORK/path" "$@" /bin/bash "$FIXTURE/ckb-cluster.sh" init --root "$WORK/root" "${ARGS[@]}" 2>&1) || rc=$?
  if [ "$rc" != "$expected" ] || [[ "$output" != *"$needle"* ]]; then
    printf 'FAIL: %s exit=%s expected=%s output=%s\n' "$name" "$rc" "$expected" "$output"
    exit 1
  fi
  printf 'PASS: %s (exit=%s)\n' "$name" "$rc"
}
ARGS=()
LOCAL="$FIXTURE/bin/ckb/v0.209.0/x86_64-apple-darwin/ckb"
make_binary "$LOCAL"
run_case 'download without PATH; external cwd and spaces' 0 "RESOLVED=$LOCAL"
make_binary "$WORK/path/ckb"
run_case 'download preferred to PATH' 0 "RESOLVED=$LOCAL"
make_binary "$WORK/explicit"
run_case 'environment override' 0 "RESOLVED=$WORK/explicit" CKB_BIN="$WORK/explicit"
ARGS=(--ckb "$WORK/explicit")
run_case 'CLI override' 0 "RESOLVED=$WORK/explicit" CKB_BIN=/missing
ARGS=()
printf 'CKB_BIN=%s\n' "$WORK/explicit" > "$WORK/root/cluster.env"
run_case 'saved binary remains pinned' 0 "RESOLVED=$WORK/explicit" CKB_BIN=/missing
printf 'CKB_BIN=/missing\n' > "$WORK/root/cluster.env"
run_case 'missing pinned binary does not fall back' 1 'ckb not found'
rm "$WORK/root/cluster.env"
run_case 'missing explicit binary does not fall back' 1 'ckb not found' CKB_BIN=/missing
make_binary "$FIXTURE/bin/ckb/v0.210.0/x86_64-apple-darwin/ckb"
run_case 'ambiguous downloads fail' 1 'Multiple local CKB binaries'
rm "$FIXTURE/bin/ckb/v0.210.0/x86_64-apple-darwin/ckb"
run_case 'other platform prompts download even with PATH binary' 1 'run ./download-ckb.sh or specify --ckb' TEST_OS=Linux
ARM="$FIXTURE/bin/ckb/v0.209.0/aarch64-apple-darwin/ckb"
make_binary "$ARM"
run_case 'arm64 normalized to aarch64' 0 "RESOLVED=$ARM" TEST_ARCH=arm64
rm "$LOCAL"
PORTABLE="$FIXTURE/bin/ckb/v0.209.0/x86_64-apple-darwin-portable/ckb"
make_binary "$PORTABLE"
run_case 'portable download' 0 "RESOLVED=$PORTABLE"
rm "$PORTABLE"
run_case 'PATH binary is not selected implicitly' 1 'run ./download-ckb.sh or specify --ckb'
ARGS=(--ckb ckb)
run_case 'PATH binary can be selected explicitly' 0 "RESOLVED=$WORK/path/ckb"
ARGS=()
rm "$WORK/path/ckb"
run_case 'no binary produces actionable error' 1 'run ./download-ckb.sh or specify --ckb'
make_binary "$LOCAL"
chmod -x "$LOCAL"
run_case 'non-executable download prompts download' 1 'run ./download-ckb.sh or specify --ckb'
printf '#!/bin/bash\nexit 42\n' > "$LOCAL"
chmod +x "$LOCAL"
run_case 'broken downloaded binary reports error' 1 'Selected CKB failed --version'
printf 'All 16 resolver cases passed.\n'
