#!/usr/bin/env bash
# Config/dispatch regression tests. Fake CKB; no nodes, mining, or network.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=${1:-$PROJECT/ckb-cluster.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ckb-pow.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
# Config-only fixtures must not inspect ports belonging to real local clusters.
mkdir "$WORK/path"
printf '#!/bin/bash\nexit 1\n' > "$WORK/path/lsof"
chmod +x "$WORK/path/lsof"
export PATH="$WORK/path:$PATH"
cat > "$WORK/ckb" <<'CKB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  --version) echo 'ckb fixture';;
  init)
    shift
    while [ $# -gt 0 ]; do
      if [ "$1" = -C ]; then dir=$2; fi
      shift
    done
    mkdir -p "$dir/specs"
    cat > "$dir/specs/dev.toml" <<'SPEC'
[genesis]
timestamp = 0
compact_target = 0x20010000
[params]
initial_primary_epoch_reward = 100000000
cellbase_maturity = 0
epoch_duration_target = 80
genesis_epoch_length = 10
permanent_difficulty_in_dummy = true
[params.hardfork]
ckb2023 = 0
[pow]
func = "Dummy"
SPEC
    printf '[network]\nlisten_addresses = []\nbootnodes = []\n' > "$dir/ckb.toml";;
  peer-id) echo fixturepeer;;
  list-hashes) echo '{"dev":{"genesis":"0x1234"}}';;
  *) exit 99;;
esac
CKB
chmod +x "$WORK/ckb"
count=0
check() { count=$((count+1)); printf 'PASS: %s\n' "$1"; }
reject() {
  local needle=$1 rc=0 out
  shift
  out=$(bash "$SCRIPT" "$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [[ "$out" = *"$needle"* ]] || { echo "Unexpected result: $rc $out"; exit 1; }
  check "$needle"
}
reject 'Invalid PoW algorithm' init --root "$WORK/invalid" --pow bad
reject 'Missing value: --pow' init --root "$WORK/invalid" --pow
for pow in dummy eaglesong; do
  for mode in solo staggered race ondemand; do
    dir="$WORK/$pow-$mode"
    bash "$SCRIPT" init --root "$dir" --ckb "$WORK/ckb" --pow "$pow" --mode "$mode" --miners 1 --syncs 1 >/dev/null
    grep -qx "POW_ALGO=$pow" "$dir/cluster.env"
    grep -qx "MINING_MODE=$mode" "$dir/cluster.env"
    cmp "$dir/shared/spec.toml" "$dir/nodes/sync-0/specs/dev.toml"
    if [ "$pow" = dummy ]; then
      grep -qx 'func = "Dummy"' "$dir/shared/spec.toml"
      grep -qx 'compact_target = 0x20010000' "$dir/shared/spec.toml"
      grep -qx 'permanent_difficulty_in_dummy = true' "$dir/shared/spec.toml"
      grep -qx 'genesis_epoch_length = 1000' "$dir/shared/spec.toml"
      grep -qx 'epoch_duration_target = 80' "$dir/shared/spec.toml"
      grep -qx 'cellbase_maturity = 0' "$dir/shared/spec.toml"
      grep -qx '\[params.hardfork\]' "$dir/shared/spec.toml"
      grep -qx 'ckb2023 = 0' "$dir/shared/spec.toml"
      grep -qx 'worker_type = "Dummy"' "$dir/nodes/miner-0/ckb-miner.toml"
      grep -qx 'value = 8000' "$dir/nodes/miner-0/ckb-miner.toml"
    else
      grep -qx 'func = "Eaglesong"' "$dir/shared/spec.toml"
      # Keep exactly the two epoch overrides, with no nested tables.
      awk '
        /^\[/ {section=$0; if ($0=="[params]") found++}
        section=="[params]" && $0=="epoch_duration_target = 14400" {duration++; next}
        section=="[params]" && $0=="genesis_epoch_length = 1000" {epoch_length_count++; next}
        section=="[params]" && $0!="[params]" && $0!~/^[[:space:]]*$/ {exit 1}
        /^\[params\./ {exit 1}
        END {if (found!=1 || duration!=1 || epoch_length_count!=1) exit 1}
      ' "$dir/shared/spec.toml"
      ! grep -Eq '^(cellbase_maturity|initial_primary_epoch_reward|permanent_difficulty_in_dummy|ckb2023)[[:space:]]*=' "$dir/shared/spec.toml"
      grep -qx 'compact_target = 0x1e015555' "$dir/shared/spec.toml"
      grep -qx 'worker_type = "EaglesongSimple"' "$dir/nodes/miner-0/ckb-miner.toml"
      grep -qx 'threads = 1' "$dir/nodes/miner-0/ckb-miner.toml"
      ! grep -Eq '^(delay_type|value) =' "$dir/nodes/miner-0/ckb-miner.toml"
    fi
    bash "$SCRIPT" init --root "$dir" >/dev/null
    check "$pow / $mode config generation and persistence"
  done
done
for pair in Dummy:dummy Eaglesong:eaglesong; do
  alias=${pair%:*}; canonical=${pair#*:}
  dir="$WORK/$canonical-solo"
  bash "$SCRIPT" init --root "$dir" --pow "$alias" >/dev/null
  grep -qx "POW_ALGO=$canonical" "$dir/cluster.env"
  check "$alias accepted on initialized $canonical cluster"
done
reject 'PoW is immutable' init --root "$WORK/dummy-solo" --pow eaglesong
# Legacy cluster configs with no POW_ALGO remain Dummy.
sed '/^POW_ALGO=/d' "$WORK/dummy-solo/cluster.env" > "$WORK/env"
mv "$WORK/env" "$WORK/dummy-solo/cluster.env"
bash "$SCRIPT" init --root "$WORK/dummy-solo" >/dev/null
check 'legacy config defaults to Dummy'
# Editing the saved setting must not change a chain consensus algorithm.
sed 's/POW_ALGO=eaglesong/POW_ALGO=dummy/' "$WORK/eaglesong-solo/cluster.env" > "$WORK/env"
mv "$WORK/env" "$WORK/eaglesong-solo/cluster.env"
for cmd in init up resume-mining mine add-node; do
  reject 'PoW differs from the saved chain spec' "$cmd" --root "$WORK/eaglesong-solo"
done
# Shutdown remains available even when someone has edited the saved setting.
bash "$SCRIPT" down --root "$WORK/eaglesong-solo" >/dev/null
check 'shutdown remains available on PoW mismatch'
printf 'All %s PoW cases passed.\n' "$count"
