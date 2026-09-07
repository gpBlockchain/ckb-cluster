#!/usr/bin/env bash
# Pacing option/dependency regressions; no running nodes or network.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ckb-pacing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/path" "$WORK/root/nodes/miner-0"
for dep in jq curl awk lsof realpath dirname date cat; do
  ln -s "$(command -v "$dep")" "$WORK/path/$dep"
done
awk '/^# An atomic directory lock/{exit} {print}' "$PROJECT/ckb-cluster.sh" > "$WORK/check.sh"
cat >> "$WORK/check.sh" <<'HARNESS'
alive() { [ "${RUNNING:-0}" = 1 ]; }
prepare_miner_cpu
printf 'pacing_ms=%s\n' "$(pacing_ms)"
save_env
HARNESS
count=0
check() {
  local name=$1 expected=$2 needle=$3 output rc=0
  shift 3
  output=$(env PATH="$WORK/path" "$@" /bin/bash "$WORK/check.sh" up --root "$WORK/root" "${ARGS[@]}" 2>&1) || rc=$?
  [ "$rc" = "$expected" ] && [[ "$output" = *"$needle"* ]] || { echo "FAIL: $name: $rc $output"; exit 1; }
  count=$((count+1)); printf 'PASS: %s\n' "$name"
}
ARGS=()
check 'Dummy does not require Python' 0 'pacing_ms=0'
ARGS=(--pow eaglesong)
check 'Eaglesong defaults to pacing and requires Python' 1 'requires Python 3.8+'
ARGS=(--pow eaglesong --eaglesong-pacing off)
check 'natural Eaglesong needs no Python' 0 'pacing_ms=0'
for mode in invalid 1 true; do
  ARGS=(--eaglesong-pacing "$mode")
  check "invalid pacing $mode" 1 '--eaglesong-pacing must be on or off'
done
ARGS=(--eaglesong-pacing)
check 'missing pacing value' 1 'Missing value: --eaglesong-pacing'
printf '#!/bin/bash\necho /fixture/python3\n' > "$WORK/path/python3"
chmod +x "$WORK/path/python3"
ARGS=(--pow eaglesong --eaglesong-pacing on)
check 'default paced interval' 0 'pacing_ms=8000'
ARGS=(--interval-ms 250)
check 'custom subsecond interval' 0 'pacing_ms=250'
ARGS=()
check 'saved pacing and interval reused' 0 'pacing_ms=250'
printf 'miner-0\tminer\t18114\t18215\tpeer\n' > "$WORK/root/cluster.state"
check 'old running direct miner requires pause before pacing' 1 'Pause all miners before changing Eaglesong pacing' RUNNING=1
printf '250\n' > "$WORK/root/nodes/miner-0/miner.pacing-ms"
check 'matching running pacing allowed' 0 'pacing_ms=250' RUNNING=1
ARGS=(--eaglesong-pacing off)
check 'changing active pacing rejected' 1 'Pause all miners before changing Eaglesong pacing' RUNNING=1
check 'changing stopped pacing allowed' 0 'pacing_ms=0'
printf 'All %s pacing option cases passed.\n' "$count"
