#!/usr/bin/env bash
# Optional dependency and CPU setting tests. No mining or processes started.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=${1:-$PROJECT/ckb-cluster.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ckb-cpu.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/path" "$WORK/root/nodes/miner-0"
for dep in jq curl awk lsof realpath dirname date cat; do
  ln -s "$(command -v "$dep")" "$WORK/path/$dep"
done
awk '/^# An atomic directory lock/{exit} {print}' "$SCRIPT" > "$WORK/check.sh"
cat >> "$WORK/check.sh" <<'HARNESS'
alive() { [ "${RUNNING:-0}" = 1 ]; }
prepare_miner_cpu
printf 'requested=%s effective=%s\n' "$MINER_CPU" "$CPU_EFFECTIVE"
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
check 'default does not require cpulimit' 0 'requested=0 effective=0'
ARGS=(--miner-cpu 20)
check 'missing cpulimit falls back to unlimited' 0 'requested=20 effective=0'
check 'missing dependency gives explicit installation warning' 0 'CPU limiting is DISABLED'
check 'macOS installation hint' 0 './install-cpulimit.sh'
check 'Debian installation hint' 0 'sudo apt install cpulimit'
for value in -1 101 1.5 abc 01; do
  ARGS=(--miner-cpu "$value")
  check "invalid value $value" 1 '--miner-cpu must be an integer from 0 to 100'
done
ARGS=(--miner-cpu)
check 'missing option value' 1 'Missing value: --miner-cpu'
printf '#!/bin/bash\nexit 0\n' > "$WORK/path/cpulimit"
chmod +x "$WORK/path/cpulimit"
for value in 0 1 20 100; do
  ARGS=(--miner-cpu "$value")
  check "installed cpulimit, setting $value" 0 "requested=$value effective=$value"
done
printf 'MINER_CPU=20\n' > "$WORK/root/cluster.env"
ARGS=()
check 'saved limit is reused' 0 'requested=20 effective=20'
printf 'miner-0\tminer\t18114\t18215\tpeer\n' > "$WORK/root/cluster.state"
printf '20\n' > "$WORK/root/nodes/miner-0/miner.cpu-limit"
check 'matching active limit allowed' 0 'effective=20' RUNNING=1
ARGS=(--miner-cpu 30)
check 'changing active limit requires pause' 1 'Pause all miners' RUNNING=1
ARGS=(--miner-cpu 0)
check 'disabling active limit requires pause' 1 'Pause all miners' RUNNING=1
check 'disabled when stopped' 0 'effective=0'
# Simulate the specifically incompatible Homebrew build, then a local fixed build.
mkdir -p "$WORK/Cellar/cpulimit/0.2/bin" "$WORK/bin/cpulimit"
mv "$WORK/path/cpulimit" "$WORK/Cellar/cpulimit/0.2/bin/cpulimit"
ln -s "$WORK/Cellar/cpulimit/0.2/bin/cpulimit" "$WORK/path/cpulimit"
printf '#!/bin/bash\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n' > "$WORK/path/uname"
chmod +x "$WORK/path/uname"
ARGS=(--miner-cpu 20)
check 'known-incompatible stock build disables limiting' 0 'requested=20 effective=0'
check 'stock build gives repair hint' 0 'Run ./install-cpulimit.sh'
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/cpulimit/cpulimit"
chmod +x "$WORK/bin/cpulimit/cpulimit"
check 'local corrected build preferred to stock PATH build' 0 'requested=20 effective=20'
printf 'All %s CPU option cases passed.\n' "$count"
