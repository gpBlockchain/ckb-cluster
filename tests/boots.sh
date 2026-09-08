#!/usr/bin/env bash
# Boot-role configuration and lifecycle regression tests; no live nodes/network.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=${1:-$PROJECT/ckb-cluster.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ckb-boots.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/path"
printf '#!/bin/bash\nexit 1\n' > "$WORK/path/lsof"
chmod +x "$WORK/path/lsof"
export PATH="$WORK/path:$PATH"
cat > "$WORK/ckb" <<'CKB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  --version) echo 'ckb boot fixture';;
  init)
    shift
    while [ $# -gt 0 ]; do
      if [ "$1" = -C ]; then dir=$2; fi
      shift
    done
    mkdir -p "$dir/specs"
    printf '[genesis]\ntimestamp = 0\n[params]\ngenesis_epoch_length = 10\n[pow]\nfunc = "Dummy"\n' > "$dir/specs/dev.toml"
    printf '[network]\nlisten_addresses = []\nbootnode_mode = false\nbootnodes = []\n[rpc]\nlisten_address = "127.0.0.1:8114"\n[block_assembler]\ncode_hash = "fixture"\n[other]\nvalue = 42\n' > "$dir/ckb.toml";;
  peer-id)
    # Unique deterministic identity for each role and index.
    for arg in "$@"; do secret=$arg; done
    printf '%s\n' "$secret" | awk -F/ '{gsub(/-/,"",$(NF-3)); print "peer" $(NF-3)}';;
  list-hashes) echo '{"dev":{"genesis":"0x1234"}}';;
  *) exit 99;;
esac
CKB
chmod +x "$WORK/ckb"
# Keep real dispatch/configuration; replace only process and RPC side effects.
awk '/^# An atomic directory lock/ {exit} {print}' "$SCRIPT" > "$WORK/functions.sh"
cat > "$WORK/mock.sh" <<'MOCK'
alive() { [[ "$1" = */node.pid ]]; }
launch() { printf '%s %s\n' "$ID" "$1" >> "$ROOT/launches"; }
stop_pid() { printf '%s\n' "$1" >> "$ROOT/stops"; }
wait_rpc() { :; }
wait_views() { :; }
rpc() { printf '%s %s %s\n' "$1" "$2" "${3:-[]}" >> "$ROOT/rpc-calls"; }
status() { printf 'miners=%s syncs=%s boots=%s\n' "$MINERS" "$SYNCS" "$BOOTS"; }
MOCK
awk -v mock="$WORK/mock.sh" '/^# An atomic directory lock/ {while ((getline line < mock)>0) print line; close(mock)} {print}' "$SCRIPT" > "$WORK/runtime.sh"
count=0
pass() { count=$((count+1)); printf 'PASS: %s\n' "$1"; }
reject() {
  local needle=$1 rc=0 out
  shift
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [[ "$out" = *"$needle"* ]] || { echo "Unexpected: $rc $out"; exit 1; }
  pass "$needle"
}
init() { bash "$SCRIPT" init --root "$1" --ckb "$WORK/ckb" --miners 1 --syncs 1 "${@:2}" >/dev/null; }
assert_topology() {
  local root=$1 id role rp pp peer hubs expected actual
  hubs=$(awk '$2=="boot" {printf "%s ",$1}' "$root/cluster.state")
  [ -n "$hubs" ] || hubs=miner-0
  while read -r id role rp pp peer; do
    expected=$(awk -v hubs="$hubs" -v id="$id" '
      BEGIN {n=split(hubs,a," ");printf "[";sep=""}
      {for(i=1;i<=n;i++) if($1==a[i] && $1!=id) {printf "%s\"/ip4/127.0.0.1/tcp/%s/p2p/%s\"",sep,$4,$5;sep=","}}
      END {print "]"}' "$root/cluster.state")
    for key in bootnodes whitelist_peers; do
      actual=$(awk -v key="$key" '$1==key {sub(/^[^=]*= /, "");print}' "$root/nodes/$id/ckb.toml")
      [ "$actual" = "$expected" ]
    done
    mode=false; [ "$role" != boot ] || mode=true
    [ "$(grep -c '^bootnode_mode =' "$root/nodes/$id/ckb.toml")" -eq 1 ]
    grep -qx "bootnode_mode = $mode" "$root/nodes/$id/ckb.toml"
    cmp "$root/shared/spec.toml" "$root/nodes/$id/specs/dev.toml"
    grep -qx "listen_address = \"0.0.0.0:$rp\"" "$root/nodes/$id/ckb.toml"
    grep -qx 'value = 42' "$root/nodes/$id/ckb.toml"
    if [ "$role" = miner ]; then grep -qx '\[block_assembler\]' "$root/nodes/$id/ckb.toml"
    else ! grep -q '\[block_assembler\]' "$root/nodes/$id/ckb.toml"; fi
  done < "$root/cluster.state"
}
for boots in 0 1 2; do
  root="$WORK/boots-$boots"
  init "$root" --boots "$boots"
  grep -qx "BOOTS=$boots" "$root/cluster.env"
  [ "$(wc -l < "$root/cluster.state")" -eq "$((boots+2))" ]
  [ "$(cut -f5 "$root/cluster.state" | sort -u | wc -l)" -eq "$((boots+2))" ]
  assert_topology "$root"
  pass "$boots boot nodes: counts, peer lists without self, shared genesis, non-mining roles"
done
root="$WORK/boots-2"
awk '$1=="miner-0" {if($3!=18114)exit 1} $1=="sync-0" {if($3!=18115)exit 1} $1=="boot-0" {if($3!=18116)exit 1} $1=="boot-1" {if($3!=18117)exit 1}' "$root/cluster.state"
pass 'existing port order preserved; boot ports appended'
for value in -1 1.5 foo 01 1000000000; do
  reject 'BOOTS must be a nonnegative integer' bash "$SCRIPT" init --root "$WORK/invalid" --boots "$value"
done
reject 'Missing value: --boots' bash "$SCRIPT" init --boots
reject 'Use 1..64 nodes' bash "$SCRIPT" init --root "$WORK/invalid" --miners 1 --syncs 0 --boots 64
reject 'Use 1..64 nodes' bash "$SCRIPT" init --root "$WORK/invalid" --miners 0 --syncs 0 --boots 1
reject 'Duplicate port' bash "$SCRIPT" init --root "$WORK/collision" --ckb "$WORK/ckb" --miners 1 --syncs 0 --boots 2 --rpc-base 18114 --p2p-base 18116
reject 'Invalid port' bash "$SCRIPT" init --root "$WORK/overflow" --ckb "$WORK/ckb" --miners 1 --syncs 0 --boots 1 --p2p-base 65535
reject 'topology/ports require re-init' bash "$SCRIPT" up --root "$root" --boots 3
# Old configs omit BOOTS; adding the first boot node switches the hub topology.
root="$WORK/boots-0"
sed '/^BOOTS=/d' "$root/cluster.env" > "$WORK/env"; mv "$WORK/env" "$root/cluster.env"
for role in boot boot sync miner; do
  bash "$WORK/runtime.sh" add-node --root "$root" --role "$role" > "$WORK/status"
  assert_topology "$root"
done
grep -qx 'miners=2 syncs=2 boots=2' "$WORK/status"
! grep -Eq '^(boot|sync)-[0-9]+ miner$' "$root/launches"
grep -qx 'miner-0 miner' "$root/launches"
grep -qx 'BOOTS=2' "$root/cluster.env"
grep -qx 'boot-0 node' "$root/launches"
grep -Fq 'miner-0 add_node ["peerboot0","/ip4/127.0.0.1/tcp/18217"]' "$root/rpc-calls"
pass 'legacy config: add boot twice, sync and miner; persisted counts, live peer wiring, miners only'
: > "$root/stops"
bash "$WORK/runtime.sh" down --root "$root" --node boot-0 >/dev/null
[ "$(wc -l < "$root/stops")" -eq 2 ]
grep -qx "$root/nodes/boot-0/node.pid" "$root/stops"
reject 'Select a miner' bash "$WORK/runtime.sh" pause-mining --root "$root" --node boot-0
pass 'boot node supports targeted stop and rejects mining selection'
# Exercise the actual status summary with offline RPC/process probes.
cat "$WORK/functions.sh" > "$WORK/status.sh"
cat >> "$WORK/status.sh" <<'STATUS'
alive() { return 1; }
rpc() { return 1; }
status
STATUS
bash "$WORK/status.sh" status --root "$root" > "$WORK/status" || :
grep -q 'miners=2 syncs=2 boots=2 ' "$WORK/status"
grep -q '^boot-0 .*OFFLINE' "$WORK/status"
pass 'actual status includes boot count and node entries'
printf 'All %s boot-node cases passed.\n' "$count"
