#!/usr/bin/env bash
# Listener configuration regression tests. No nodes or network are started.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=${1:-$PROJECT/ckb-cluster.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ckb-bind.XXXXXX")
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
genesis_epoch_length = 10
permanent_difficulty_in_dummy = true
[pow]
func = "Dummy"
SPEC
    printf '[network]\nlisten_addresses = []\nbootnodes = []\n[rpc]\nlisten_address = "127.0.0.1:8114"\n[other]\nlisten_address = "unchanged"\n' > "$dir/ckb.toml";;
  peer-id) echo fixturepeer;;
  list-hashes) echo '{"dev":{"genesis":"0x1234"}}';;
  *) exit 99;;
esac
CKB
chmod +x "$WORK/ckb"
# Exercise real parsing and rebind logic without invoking node launch or RPC.
awk '/^# An atomic directory lock/{exit} {print}' "$SCRIPT" > "$WORK/rebind.sh"
cat >> "$WORK/rebind.sh" <<'HARNESS'
alive() { [ "${TEST_ALIVE:-0}" = 1 ]; }
configure_bindings
HARNESS
count=0
pass() { count=$((count+1)); printf 'PASS: %s\n' "$1"; }
reject() {
  local expected=$1 rc=0 out
  shift
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [[ "$out" = *"$expected"* ]] || { echo "Unexpected result: $rc $out"; exit 1; }
  pass "$expected"
}
assert_bind() {
  local dir=$1 rpc=$2 p2p=$3 id port
  grep -qx "RPC_BIND=$rpc" "$dir/cluster.env"
  grep -qx "P2P_BIND=$p2p" "$dir/cluster.env"
  for id in miner-0 sync-0; do
    port=18114; [ "$id" = miner-0 ] || port=18115
    grep -qx "listen_address = \"$rpc:$port\"" "$dir/nodes/$id/ckb.toml"
    grep -qx "listen_addresses = \[\"/ip4/$p2p/tcp/$((port+101))\"\]" "$dir/nodes/$id/ckb.toml"
    grep -qx 'listen_address = "unchanged"' "$dir/nodes/$id/ckb.toml"
    grep -qx "rpc_url = \"http://127.0.0.1:$port/\"" "$dir/nodes/$id/ckb-miner.toml"
  done
  grep -q '/ip4/127.0.0.1/tcp/18215/p2p/fixturepeer' "$dir/nodes/sync-0/ckb.toml"
}
for rpc in 0.0.0.0 127.0.0.1; do
  for p2p in 0.0.0.0 127.0.0.1; do
    dir="$WORK/$rpc-$p2p"
    bash "$SCRIPT" init --root "$dir" --ckb "$WORK/ckb" --miners 1 --syncs 1 --rpc-bind "$rpc" --p2p-bind "$p2p" >/dev/null
    assert_bind "$dir" "$rpc" "$p2p"
    pass "independent RPC=$rpc P2P=$p2p; internal endpoints stay on loopback"
  done
done
dir="$WORK/default"
bash "$SCRIPT" init --root "$dir" --ckb "$WORK/ckb" --miners 1 --syncs 1 >/dev/null
assert_bind "$dir" 0.0.0.0 0.0.0.0
pass 'new clusters default to all IPv4 interfaces'
for flag in --rpc-bind --p2p-bind; do
  reject 'must be 127.0.0.1 or 0.0.0.0' bash "$SCRIPT" init --root "$WORK/invalid" "$flag" '0.0.0.0"'
  reject "Missing value: $flag" bash "$SCRIPT" init --root "$WORK/invalid" "$flag"
done
before=$(cat "$dir/cluster.env" "$dir/nodes/miner-0/ckb.toml" "$dir/nodes/sync-0/ckb.toml")
reject 'Stop all cluster processes' env TEST_ALIVE=1 bash "$WORK/rebind.sh" up --root "$dir" --rpc-bind 127.0.0.1 --p2p-bind 127.0.0.1
[ "$before" = "$(cat "$dir/cluster.env" "$dir/nodes/miner-0/ckb.toml" "$dir/nodes/sync-0/ckb.toml")" ]
pass 'running rebind leaves config and persisted settings untouched'
env TEST_ALIVE=1 bash "$WORK/rebind.sh" up --root "$dir"
pass 'unchanged settings are allowed while running'
bash "$WORK/rebind.sh" up --root "$dir" --rpc-bind 127.0.0.1 --p2p-bind 127.0.0.1
assert_bind "$dir" 127.0.0.1 127.0.0.1
pass 'stopped cluster rebind updates all nodes and persists settings'
# Missing binding fields use the same all-interface defaults as a new cluster.
sed '/^RPC_BIND=/d; /^P2P_BIND=/d' "$dir/cluster.env" > "$WORK/env"
mv "$WORK/env" "$dir/cluster.env"
bash "$WORK/rebind.sh" up --root "$dir"
assert_bind "$dir" 0.0.0.0 0.0.0.0
pass 'missing binding fields use all-interface defaults'
bash "$WORK/rebind.sh" up --root "$dir" --rpc-bind 127.0.0.1 --p2p-bind 127.0.0.1
# All staged configs must validate before the first node config is replaced.
sed '/^listen_addresses =/d' "$dir/nodes/sync-0/ckb.toml" > "$WORK/bad"
mv "$WORK/bad" "$dir/nodes/sync-0/ckb.toml"
before=$(cat "$dir/cluster.env" "$dir/nodes/miner-0/ckb.toml")
reject 'Invalid binding fields' bash "$WORK/rebind.sh" up --root "$dir" --rpc-bind 0.0.0.0 --p2p-bind 0.0.0.0
[ "$before" = "$(cat "$dir/cluster.env" "$dir/nodes/miner-0/ckb.toml")" ]
pass 'malformed later node leaves earlier node and saved settings untouched'
printf 'All %s binding cases passed.\n' "$count"
