#!/usr/bin/env bash
# Single-host CKB Devnet. Bash 3.2+, jq, curl, awk, lsof, local ckb.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: ./ckb-cluster.sh COMMAND [OPTIONS]
Commands:
  init | up | status | add-node --role miner|sync
  down [--node ID|all]  stop selected node(s) and their miners; retain data
  pause-mining [--node miner-N|all] | resume-mining
  mine [--node miner-N] [--blocks 1] [--timeout 60]  (ondemand only)
  logs --node ID [--follow] | snapshot | export
  clean --force        stop ALL nodes, then delete only the cluster root
Options:
  --root DIR             Default: tmp under this script's directory
  --ckb PATH             Default: local download (CKB_BIN override supported)
  --miners N --syncs M    Default: 2 + 2; set during init
  --mode MODE            solo (default), staggered, race, ondemand
  --miner-cpu N          0 (default): unlimited; 1..100: percent of one CPU core
                        Optional cpulimit; missing tool warns and runs unlimited.
  --pow ALGORITHM        dummy (default) or eaglesong; Dummy/Eaglesong also accepted
                        Immutable per cluster
  --interval-ms N        Default: 8000; Dummy delay / staggered startup spacing
  --timeout N            Default: 60 seconds; mine or Eaglesong startup
  --rpc-base N --p2p-base N  Default: 18114 / 18215
  --rpc-bind ADDRESS     0.0.0.0 (default) or 127.0.0.1
  --p2p-bind ADDRESS     0.0.0.0 (default) or 127.0.0.1
                        Stop all cluster processes before changing bindings.
Configuration: edit cluster.env while stopped (plain KEY=value, not shell).
Dummy uses Constant delays; Eaglesong uses one CPU thread per miner.
Eaglesong/race have no interval guarantee; staggered is only heuristic.
mine watches main-chain height, may overshoot; nonce --limit is NOT height +K.
EOF
}
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
CMD=${1:-help}; [ $# -eq 0 ] || shift
case "$CMD" in help|-h|--help) usage; exit 0;; esac
case "$CMD" in init|up|down|status|add-node|pause-mining|resume-mining|mine|logs|snapshot|export|clean) ;; *) die "Unknown command: $CMD";; esac
PROJECT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=${CLUSTER_ROOT:-$PROJECT_DIR/tmp}
MINERS=2 SYNCS=2 RPC_BASE=18114 P2P_BASE=18215 BLOCK_INTERVAL_MS=8000 MINING_MODE=solo
MINER_CPU=0 CPU_EFFECTIVE=0 CPU_PREPARED=0 CPULIMIT_BIN=''
POW_ALGO=dummy
RPC_BIND=0.0.0.0 P2P_BIND=0.0.0.0
CKB_BIN=${CKB_BIN:-}
LOCK_ARG=0x0000000000000000000000000000000000000000
GENESIS_MESSAGE=ckb-cluster-dev
NODE=all ROLE=sync BLOCKS=1 TIMEOUT=60 FORCE=0 FOLLOW=0
OVERRIDES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift; continue;;
    --follow) FOLLOW=1; shift; continue;;
    --help|-h) usage; exit 0;;
  esac
  [ $# -ge 2 ] || die "Missing value: $1"
  case "$1" in
    --root) ROOT=$2;; --ckb) OVERRIDES+=(CKB_BIN "$2");;
    --miners) OVERRIDES+=(MINERS "$2");; --syncs) OVERRIDES+=(SYNCS "$2");;
    --rpc-base) OVERRIDES+=(RPC_BASE "$2");; --p2p-base) OVERRIDES+=(P2P_BASE "$2");;
    --interval-ms) OVERRIDES+=(BLOCK_INTERVAL_MS "$2");; --mode) OVERRIDES+=(MINING_MODE "$2");;
    --rpc-bind) OVERRIDES+=(RPC_BIND "$2");; --p2p-bind) OVERRIDES+=(P2P_BIND "$2");;
    --miner-cpu) OVERRIDES+=(MINER_CPU "$2");;
    --pow)
      value=$2
      case "$value" in Dummy) value=dummy;; Eaglesong) value=eaglesong;; esac
      OVERRIDES+=(POW_ALGO "$value");;
    --node) NODE=$2;; --role) ROLE=$2;; --blocks) BLOCKS=$2;; --timeout) TIMEOUT=$2;;
    *) die "Unknown option: $1";;
  esac
  shift 2
done
for dep in jq curl awk lsof realpath; do command -v "$dep" >/dev/null || die "Missing dependency: $dep"; done
ROOT=$(realpath "$ROOT")
case "$ROOT" in /|"$HOME"|"$PROJECT_DIR"|*$'\n'*|*$'\r'*|*$'\t'*) die 'Choose a dedicated cluster subdirectory';; esac
case "$PROJECT_DIR/" in "$ROOT/"*) die 'Root must not contain the project';; esac
KEYS='MINERS SYNCS RPC_BASE P2P_BASE BLOCK_INTERVAL_MS MINING_MODE POW_ALGO RPC_BIND P2P_BIND MINER_CPU CKB_BIN LOCK_ARG GENESIS_MESSAGE'
if [ -f "$ROOT/cluster.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|'#'*) continue;; esac
    case " $KEYS " in *" $key "*) printf -v "$key" '%s' "$value";; *) die "Unknown config key: $key";; esac
  done < "$ROOT/cluster.env"
fi
for ((i=0; i<${#OVERRIDES[@]}; i+=2)); do
  key=${OVERRIDES[i]}; value=${OVERRIDES[i+1]}
  if [ -f "$ROOT/.ready" ]; then
    if [ "$key" = POW_ALGO ] && [ "$POW_ALGO" != "$value" ]; then
      die 'PoW is immutable for an initialized cluster; use a new --root'
    fi
    if [ "${!key}" != "$value" ]; then
      case "$key" in
        MINER_CPU) case "$CMD" in up|resume-mining|mine) ;; *) die 'Change --miner-cpu with up, resume-mining, or mine after pausing miners';; esac;;
        RPC_BIND|P2P_BIND) [ "$CMD" = up ] || die 'Change bindings with up after stopping all cluster processes';;
        *) die 'Existing cluster: edit cluster.env while stopped; topology/ports require re-init';;
      esac
    fi
  fi
  printf -v "$key" '%s' "$value"
done
for key in MINERS SYNCS RPC_BASE P2P_BASE BLOCK_INTERVAL_MS BLOCKS TIMEOUT; do
  value=${!key}
  [[ "$value" =~ ^(0|[1-9][0-9]{0,8})$ ]] || die "$key must be a nonnegative integer"
done
[ "$MINERS" -ge 1 ] && [ "$((MINERS+SYNCS))" -le 64 ] || die 'Use 1..64 nodes, at least one miner'
[ "$BLOCK_INTERVAL_MS" -gt 0 ] && [ "$BLOCKS" -gt 0 ] && [ "$TIMEOUT" -gt 0 ] || die 'Interval/blocks/timeout must be positive'
case "$MINING_MODE" in solo|staggered|race|ondemand) ;; *) die 'Invalid mining mode';; esac
case "$POW_ALGO" in dummy|eaglesong) ;; *) die 'Invalid PoW algorithm; use --pow dummy|eaglesong';; esac
for key in RPC_BIND P2P_BIND; do
  case "${!key}" in 127.0.0.1|0.0.0.0) ;; *) die "$key must be 127.0.0.1 or 0.0.0.0";; esac
done
[[ "$MINER_CPU" =~ ^(0|[1-9]|[1-9][0-9]|100)$ ]] || die '--miner-cpu must be an integer from 0 to 100'
case "$ROLE" in miner|sync) ;; *) die 'Invalid role';; esac
[[ "$NODE" =~ ^(all|miner-[0-9]+|sync-[0-9]+)$ ]] || die 'Invalid node ID'
[[ "$LOCK_ARG" =~ ^0x[0-9a-fA-F]{40}$ ]] || die 'LOCK_ARG must be 20 bytes'

save_env() { for key in $KEYS; do printf '%s=%s\n' "$key" "${!key}"; done > "$ROOT/cluster.env"; }
need_ckb() {
  # Resolve defaults only when neither the environment, saved config nor --ckb
  # selected a binary. Never silently replace a pinned or explicit binary.
  if [ -z "$CKB_BIN" ]; then
    local arch target candidate
    local candidates=()
    arch=$(uname -m)
    case "$arch" in arm64|aarch64) arch=aarch64;; amd64) arch=x86_64;; esac
    case "$(uname -s)" in
      Darwin) target="$arch-apple-darwin";;
      Linux) target="$arch-unknown-linux-gnu";;
      *) target=unsupported;;
    esac
    for candidate in "$PROJECT_DIR"/bin/ckb/*/"$target"/ckb "$PROJECT_DIR"/bin/ckb/*/"$target-portable"/ckb; do
      [ ! -x "$candidate" ] || [ ! -f "$candidate" ] || candidates+=("$candidate")
    done
    case "${#candidates[@]}" in
      0) die 'No downloaded CKB for this platform; run ./download-ckb.sh or specify --ckb /absolute/path/to/ckb';;
      1) CKB_BIN=${candidates[0]};;
      *) printf 'Downloaded CKB candidates:\n' >&2
         printf '  %s\n' "${candidates[@]}" >&2
         die 'Multiple local CKB binaries; select one with --ckb';;
    esac
  fi
  CKB_BIN=$(command -v "$CKB_BIN") || die 'ckb not found; run bash download-ckb.sh or set --ckb'
  CKB_BIN=$(realpath "$CKB_BIN")
  "$CKB_BIN" --version >/dev/null || die "Selected CKB failed --version: $CKB_BIN; download it again or specify --ckb /absolute/path/to/ckb"
}
# Never source configuration or state; state is TSV: id role rpc p2p peer_id.
rows() { cat "$ROOT/cluster.state"; }
lookup() {
  local row
  row=$(awk -v id="$1" '$1==id {print; exit}' "$ROOT/cluster.state")
  [ -n "$row" ] || die "Unknown node: $1"
  read -r ID R RP PP PEER <<< "$row"
  DIR="$ROOT/nodes/$ID"
}
identity() { ps -p "$1" -o lstart= 2>/dev/null; }
alive() {
  local pid sig command sub label expected current kind
  sub=run; [ "$(basename "$1")" != miner.pid ] || sub=miner
  # launchd can restart a job after its original PID exits. Refresh only after
  # checking both the deterministic job label and the exact node-directory suffix.
  if [ -f "$1.launchd" ]; then
    read -r label < "$1.launchd"
    kind=$(basename "$1" .pid)
    expected="local.ckb-cluster.$(printf '%s' "$(dirname "$1")/$kind" | cksum | awk '{print $1}')"
    [ "$label" = "$expected" ] || return 1
    current=$(launchctl list "$label" 2>/dev/null | awk '$1=="\"PID\"" {gsub(/;/,"",$3);print $3}') || current=''
    if [[ "$current" =~ ^[0-9]+$ ]]; then
      command=$(ps -p "$current" -o command= 2>/dev/null) || command=''
      case "$command" in *" $sub -C $(dirname "$1")"|*" $PROJECT_DIR/miner-runner.sh run "*" --node-dir $(dirname "$1")")
        sig=$(identity "$current") || return 1
        { echo "$current"; printf '%s\n' "$sig"; } > "$1";;
      esac
    fi
  fi
  [ -f "$1" ] || return 1
  { read -r pid; IFS= read -r sig; } < "$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
  kill -0 "$pid" 2>/dev/null && [ -n "$sig" ] && [ "$(identity "$pid")" = "$sig" ] || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$command" in *" $sub -C $(dirname "$1")"|*" $PROJECT_DIR/miner-runner.sh run "*" --node-dir $(dirname "$1")") return 0;; *) return 1;; esac
}
stop_pid() {
  local file=$1 pid n
  alive "$file" || true  # refresh a restarted launchd job before removing it
  if [ -f "$file.launchd" ]; then
    local label expected kind
    read -r label < "$file.launchd"
    kind=$(basename "$file" .pid)
    expected="local.ckb-cluster.$(printf '%s' "$(dirname "$file")/$kind" | cksum | awk '{print $1}')"
    [ "$label" = "$expected" ] || die "Unexpected launchd label: $label"
    if launchctl list "$label" >/dev/null 2>&1; then
      launchctl remove "$label" || die "Failed to remove launchd job: $label"
    fi
    rm -f "$file.launchd"
  fi
  if alive "$file"; then
    read -r pid < "$file"
    # launchd may finish shutdown between the identity check and kill.
    if ! kill -TERM "$pid" 2>/dev/null; then
      if alive "$file"; then die "Failed to stop process $pid; data retained"; fi
    fi
    for ((n=0;n<100;n++)); do alive "$file" || break; sleep 0.1; done
    if alive "$file"; then
      if ! kill -KILL "$pid" 2>/dev/null; then
        if alive "$file"; then die "Failed to kill process $pid; data retained"; fi
      fi
      for ((n=0;n<30;n++)); do alive "$file" || break; sleep 0.1; done
      if alive "$file"; then die "Process $pid still alive; data retained"; fi
    fi
  fi
  if [ "$(basename "$file")" = miner.pid ]; then
    /bin/bash "$PROJECT_DIR/miner-runner.sh" cleanup "$(dirname "$file")"
    rm -f "$(dirname "$file")/miner.cpu-limit"
  fi
  rm -f "$file"
}
prepare_miner_cpu() {
  [ "$CPU_PREPARED" = 0 ] || return 0
  CPU_EFFECTIVE=0
  if [ "$MINER_CPU" -gt 0 ]; then
    if [ -x "$PROJECT_DIR/bin/cpulimit/cpulimit" ]; then
      CPULIMIT_BIN="$PROJECT_DIR/bin/cpulimit/cpulimit"
    else
      CPULIMIT_BIN=$(command -v cpulimit || true)
    fi
    if [ -n "$CPULIMIT_BIN" ]; then
      CPULIMIT_BIN=$(realpath "$CPULIMIT_BIN")
      CPU_EFFECTIVE=$MINER_CPU
      case "$CPULIMIT_BIN" in
        */Cellar/cpulimit/0.2/*)
          if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
            log 'WARN: stock Homebrew cpulimit 0.2 miscounts CPU time on Apple Silicon; CPU limiting is DISABLED. Run ./install-cpulimit.sh for the project-local corrected build'
            CPU_EFFECTIVE=0
          fi;;
      esac
    else
      log 'WARN: cpulimit is not installed; CPU limiting is DISABLED (miners will run unlimited). Install: ./install-cpulimit.sh (macOS), or sudo apt install cpulimit (Debian/Ubuntu)'
    fi
  fi
  local id r rp pp peer active
  if [ -f "$ROOT/cluster.state" ]; then
    while read -r id r rp pp peer; do
      [ "$r" = miner ] || continue
      if alive "$ROOT/nodes/$id/miner.pid"; then
        active=0
        [ ! -f "$ROOT/nodes/$id/miner.cpu-limit" ] || read -r active < "$ROOT/nodes/$id/miner.cpu-limit"
        [ "$active" = "$CPU_EFFECTIVE" ] || die 'Pause all miners before changing the effective CPU limit'
      fi
    done < "$ROOT/cluster.state"
  fi
  CPU_PREPARED=1
}
launch() {
  local kind=$1 sub=$2 pid label n
  alive "$DIR/$kind.pid" && return 0
  local command=("$CKB_BIN" "$sub" -C "$DIR")
  if [ "$kind" = miner ]; then
    /bin/bash "$PROJECT_DIR/miner-runner.sh" cleanup "$DIR"
    printf '%s\n' "$CPU_EFFECTIVE" > "$DIR/miner.cpu-limit"
    if [ "$CPU_EFFECTIVE" -gt 0 ]; then
      command=(/bin/bash "$PROJECT_DIR/miner-runner.sh" run "$CPU_EFFECTIVE" "$CPULIMIT_BIN" "$CKB_BIN" --node-dir "$DIR")
    fi
  fi
  if [ "$(uname -s)" = Darwin ]; then
    # launchd keeps jobs independent of the invoking terminal/tool session.
    label="local.ckb-cluster.$(printf '%s' "$DIR/$kind" | cksum | awk '{print $1}')"
    launchctl remove "$label" 2>/dev/null || true
    echo "$label" > "$DIR/$kind.pid.launchd"
    launchctl submit -l "$label" -o "$DIR/logs/$kind.log" -e "$DIR/logs/$kind.log" -- "${command[@]}"
    pid=''
    for ((n=0;n<50;n++)); do
      pid=$(launchctl list "$label" 2>/dev/null | awk '$1=="\"PID\"" {gsub(/;/,"",$3);print $3}')
      [ -z "$pid" ] || break
      sleep 0.1
    done
    [ -n "$pid" ] || die "$ID $kind launchd startup failed"
  else
    nohup "${command[@]}" >> "$DIR/logs/$kind.log" 2>&1 < /dev/null &
    pid=$!
  fi
  { echo "$pid"; identity "$pid"; } > "$DIR/$kind.pid"
  sleep 0.2
  alive "$DIR/$kind.pid" || die "$ID $kind exited; see $DIR/logs/$kind.log"
}
rpc() {
  local id=$1 method=$2 params=${3:-'[]'} port
  port=$(awk -v id="$id" '$1==id {print $3}' "$ROOT/cluster.state")
  [ -n "$port" ] || return 1
  curl --noproxy '*' --fail --silent --show-error --max-time 3 \
    -H 'Content-Type: application/json' "http://127.0.0.1:$port" \
    -d "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params}" |
    jq 'if has("error") then error(.error|tostring) elif has("result") then .result else error("Missing result") end'
}
field() {
  local value
  value=$(jq -er --arg key "$1" 'if $key=="" then . else .[$key] end') || return 1
  if [ "${2:-}" = hex ]; then
    [[ "$value" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
    printf '%d\n' "$((value))"
  else printf '%s\n' "$value"; fi
}
height() { rpc "$1" get_tip_block_number | field '' hex; }
free_ports() {
  local p seen=' '
  for p in "$@"; do
    [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || die "Invalid port: $p"
    case "$seen" in *" $p "*) die "Duplicate port: $p";; esac
    seen="$seen$p "
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then die "Port $p in use; choose different port bases"; fi
  done
}
write_miner() {
  local delay=$1
  cat > "$DIR/ckb-miner.toml" <<EOF
data_dir = "data"
[chain]
spec = { file = "specs/dev.toml" }
[logger]
log_to_file = false
log_to_stdout = true
color = false
[sentry]
dsn = ""
[miner.client]
rpc_url = "http://127.0.0.1:$RP/"
block_on_submit = true
poll_interval = 100
[[miner.workers]]
EOF
  if [ "$POW_ALGO" = eaglesong ]; then
    printf 'worker_type = "EaglesongSimple"\nthreads = 1\n' >> "$DIR/ckb-miner.toml"
  else
    printf 'worker_type = "Dummy"\ndelay_type = "Constant"\nvalue = %s\n' "$delay" >> "$DIR/ckb-miner.toml"
  fi
}
init_node() {
  local id=$1 role=$2 idx=$3 peer genesis boot='[]'
  local rp=$((RPC_BASE+idx)) pp=$((P2P_BASE+idx))
  DIR="$ROOT/nodes/$id"; RP=$rp
  [ ! -e "$DIR" ] || die "Node directory already exists: $DIR"
  free_ports "$rp" "$pp"
  mkdir -p "$DIR/logs" "$DIR/data/network"
  local args=(init --chain dev -C "$DIR" --rpc-port "$rp" --p2p-port "$pp" --genesis-message "$GENESIS_MESSAGE" --log-to stdout)
  [ "$role" != miner ] || args+=(--ba-arg "$LOCK_ARG")
  "$CKB_BIN" "${args[@]}" > "$DIR/logs/init.log" 2>&1
  if [ ! -f "$ROOT/shared/spec.toml" ]; then
    # Freeze a shared timestamp once; later nodes copy these exact bytes.
    awk -v ts="$(date +%s)000" -v pow="$POW_ALGO" '
      /^\[/ { section=$0 }
      # Eaglesong keeps only the epoch overrides in params; discard other dev params and subtables.
      pow=="eaglesong" && /^\[params\]/ { print "[params]\nepoch_duration_target = 14400\ngenesis_epoch_length = 1000\n"; next }
      pow=="eaglesong" && section ~ /^\[params(\]|\.)/ { next }
      pow=="eaglesong" && section=="[genesis]" && /^compact_target[[:space:]]*=/ { print "compact_target = 0x1e015555"; next }
      section=="[genesis]" && /^timestamp[[:space:]]*=/ { print "timestamp = " ts; next }
      section=="[params]" && /^permanent_difficulty_in_dummy[[:space:]]*=/ { next }
      pow=="dummy" && section=="[params]" && /^genesis_epoch_length[[:space:]]*=/ { next }
      section=="[pow]" && /^func[[:space:]]*=/ { print "func = \"" (pow=="dummy" ? "Dummy" : "Eaglesong") "\""; next }
      { print }
      /^\[params\]/ && pow=="dummy" { print "genesis_epoch_length = 1000\npermanent_difficulty_in_dummy = true" }
    ' "$DIR/specs/dev.toml" > "$ROOT/shared/spec.toml"
  fi
  cp "$ROOT/shared/spec.toml" "$DIR/specs/dev.toml"
  "$CKB_BIN" peer-id gen --secret-path "$DIR/data/network/secret_key" >> "$DIR/logs/init.log" 2>&1
  peer=$("$CKB_BIN" peer-id from-secret --secret-path "$DIR/data/network/secret_key" | awk '{print $NF}')
  [[ "$peer" =~ ^[A-Za-z0-9]+$ ]] || die 'Unexpected peer-id output'
  if [ "$id" != miner-0 ]; then
    local bp bpeer
    read -r bp bpeer <<< "$(awk '$1=="miner-0"{print $4,$5}' "$ROOT/cluster.state")"
    boot="[\"/ip4/127.0.0.1/tcp/$bp/p2p/$bpeer\"]"
  fi
  awk -v port="$pp" -v rpc_port="$rp" -v rpc_bind="$RPC_BIND" -v p2p_bind="$P2P_BIND" -v boot="$boot" -v role="$role" '
    /^\[/ { section=$0; skip=(role=="sync" && $0=="[block_assembler]") }
    skip { next }
    section=="[network]" && /^listen_addresses[[:space:]]*=/ { print "listen_addresses = [\"/ip4/" p2p_bind "/tcp/" port "\"]"; next }
    section=="[rpc]" && /^listen_address[[:space:]]*=/ { print "listen_address = \"" rpc_bind ":" rpc_port "\""; next }
    /^bootnodes[[:space:]]*=/ { print "bootnodes = " boot; next }
    /^discovery_local_address[[:space:]]*=/ { print "discovery_local_address = true"; next }
    /^cache_size[[:space:]]*=/ { print "cache_size = 16777216"; next }
    { print }
    /^\[network\]/ { print "whitelist_peers = " boot }
  ' "$DIR/ckb.toml" > "$DIR/ckb.toml.tmp"
  mv "$DIR/ckb.toml.tmp" "$DIR/ckb.toml"
  write_miner "$BLOCK_INTERVAL_MS"
  genesis=$("$CKB_BIN" list-hashes -C "$DIR" -f json | jq -er 'to_entries[0].value.genesis')
  if [ -f "$ROOT/shared/genesis.hash" ]; then
    [ "$genesis" = "$(cat "$ROOT/shared/genesis.hash")" ] || die "$id genesis mismatch"
  else echo "$genesis" > "$ROOT/shared/genesis.hash"; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$role" "$rp" "$pp" "$peer" >> "$ROOT/cluster.state"
  log "Initialized $id RPC=$rp P2P=$pp"
}
cmd_init() {
  [ ! -f "$ROOT/.ready" ] || { log 'Already initialized'; return; }
  [ ! -s "$ROOT/cluster.state" ] || die 'Partial init; inspect logs then clean --force and retry'
  need_ckb
  local ports=() i
  for ((i=0;i<MINERS+SYNCS;i++)); do ports+=("$((RPC_BASE+i))" "$((P2P_BASE+i))"); done
  free_ports "${ports[@]}"
  mkdir -p "$ROOT/shared" "$ROOT/nodes" "$ROOT/evidence"
  echo 'ckb-cluster-v1' > "$ROOT/.ckb-cluster"
  : > "$ROOT/cluster.state"
  save_env
  printf '%s\n' "$GENESIS_MESSAGE" > "$ROOT/shared/genesis.message"
  "$CKB_BIN" --version > "$ROOT/shared/ckb.version"
  for ((i=0;i<MINERS;i++)); do init_node "miner-$i" miner "$i"; done
  for ((i=0;i<SYNCS;i++)); do init_node "sync-$i" sync "$((MINERS+i))"; done
  touch "$ROOT/.ready"
}
wait_rpc() {
  local id=$1 end=$((SECONDS+30))
  until rpc "$id" local_node_info >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$end" ] || die "$id RPC timeout"
    sleep 1
  done
}
connect_peers() {
  local id r rp pp peer hub hport
  read -r hport hub <<< "$(awk '$1=="miner-0"{print $4,$5}' "$ROOT/cluster.state")"
  while read -r id r rp pp peer; do
    [ "$id" != miner-0 ] || continue
    rpc "$id" add_node "[\"$hub\",\"/ip4/127.0.0.1/tcp/$hport\"]" >/dev/null
    rpc miner-0 add_node "[\"$peer\",\"/ip4/127.0.0.1/tcp/$pp\"]" >/dev/null
  done < "$ROOT/cluster.state"
}
pause() {
  local id r rp pp peer
  [ "$NODE" = all ] || { lookup "$NODE"; [ "$R" = miner ] || die 'Select a miner'; }
  while read -r id r rp pp peer; do
    if [ "$NODE" = all ] || [ "$NODE" = "$id" ]; then stop_pid "$ROOT/nodes/$id/miner.pid"; fi
  done < "$ROOT/cluster.state"
}
resume() {
  local id r rp pp peer count delay started=0
  prepare_miner_cpu; save_env
  [ "$MINING_MODE" != ondemand ] || { log 'ondemand: use mine'; return; }
  count=$(awk '$2=="miner"{n++}END{print n+0}' "$ROOT/cluster.state")
  delay=$BLOCK_INTERVAL_MS
  [ "$MINING_MODE" != staggered ] || delay=$((count*delay))
  while read -r id r rp pp peer; do
    [ "$r" = miner ] || continue
    [ "$MINING_MODE" != solo ] || [ "$id" = miner-0 ] || continue
    lookup "$id"; alive "$DIR/node.pid" || die "$id node is stopped; run up first"
    alive "$DIR/miner.pid" && continue
    if [ "$MINING_MODE" = staggered ] && [ "$started" -gt 0 ]; then
      sleep "$(awk -v ms="$BLOCK_INTERVAL_MS" 'BEGIN {printf "%.3f",ms/1000}')"
    fi
    write_miner "$delay"; launch miner miner; started=$((started+1))
  done < "$ROOT/cluster.state"
}
check_views() {
  local id r rp pp peer h min=9223372036854775807 max=0 hash expected='' chain='' c
  local heights=()
  while read -r id r rp pp peer; do
    lookup "$id"; alive "$DIR/node.pid" || return 1
    h=$(height "$id") || return 1; heights+=("$h")
    [ "$h" -ge "$min" ] || min=$h; [ "$h" -le "$max" ] || max=$h
    [ "$(rpc "$id" get_block_hash '["0x0"]' | field '')" = "$(cat "$ROOT/shared/genesis.hash")" ] || return 1
    c=$(rpc "$id" get_blockchain_info | field chain) || return 1
    [ -n "$chain" ] || chain=$c; [ "$c" = "$chain" ] || return 1
    if [ "$(wc -l < "$ROOT/cluster.state")" -gt 1 ]; then
      [ "$(rpc "$id" get_peers | jq length)" -gt 0 ] || return 1
    fi
  done < "$ROOT/cluster.state"
  [ "$((max-min))" -le 1 ] || return 1
  while read -r id r rp pp peer; do
    hash=$(rpc "$id" get_block_hash "[\"$(printf '0x%x' "$min")\"]") || return 1
    [ -n "$expected" ] || expected=$hash; [ "$hash" = "$expected" ] || return 1
  done < "$ROOT/cluster.state"
}
wait_views() {
  local end=$((SECONDS+30))
  until check_views; do
    [ "$SECONDS" -lt "$end" ] || die 'Peer/genesis/chain/tip health check failed'
    sleep 1
  done
}
intervals() {
  local tip h header ts prev=0 sum=0 count=0 start
  tip=$(height miner-0); start=$((tip>4 ? tip-4 : 1))
  for ((h=start;h<=tip;h++)); do
    header=$(rpc miner-0 get_header_by_number "[\"$(printf '0x%x' "$h")\"]")
    ts=$(printf '%s' "$header" | field timestamp hex)
    echo "block=$h timestamp_ms=$ts"
    if [ "$prev" -gt 0 ]; then echo "interval_ms=$((ts-prev))"; sum=$((sum+ts-prev)); count=$((count+1)); fi
    prev=$ts
  done
  if [ "$count" -gt 0 ]; then
    if [ "$POW_ALGO" = eaglesong ]; then
      echo "average_interval_ms=$((sum/count)) pow=$POW_ALGO mode=$MINING_MODE"
      echo 'INFO: Eaglesong uses real CPU PoW; block intervals are probabilistic'
      return
    fi
    echo "average_interval_ms=$((sum/count)) target_ms=$BLOCK_INTERVAL_MS mode=$MINING_MODE"
    if [ "$MINING_MODE" = race ]; then echo 'INFO: race has no interval guarantee'
    elif [ "$((sum/count))" -lt "$((BLOCK_INTERVAL_MS*7/8))" ] || [ "$((sum/count))" -gt "$((BLOCK_INTERVAL_MS*9/8))" ]; then echo 'WARN: observed interval outside target ±12.5%'; fi
  fi
}
status() {
  local id r rp pp peer tip peers base h np mp cap worker failed=0
  echo "time=$(date -u +%FT%TZ) mode=$MINING_MODE pow=$POW_ALGO rpc_bind=$RPC_BIND p2p_bind=$P2P_BIND miner_cpu_requested=$MINER_CPU miners=$MINERS syncs=$SYNCS root=$ROOT"
  base=$(height miner-0 2>/dev/null) || base=0
  while read -r id r rp pp peer; do
    np=- mp=- cap=- worker=-; lookup "$id"
    if alive "$DIR/node.pid"; then read -r np < "$DIR/node.pid"; fi
    if alive "$DIR/miner.pid"; then
      read -r mp < "$DIR/miner.pid"; cap=0; worker=$mp
      [ ! -f "$DIR/miner.cpu-limit" ] || read -r cap < "$DIR/miner.cpu-limit"
      [ ! -f "$DIR/miner-worker.pid" ] || read -r worker < "$DIR/miner-worker.pid"
    fi
    if tip=$(rpc "$id" get_tip_header 2>/dev/null) && peers=$(rpc "$id" get_peers 2>/dev/null); then
      h=$(printf '%s' "$tip" | field number hex)
      echo "$id node_pid=$np miner_pid=$mp worker_pid=$worker cpu_limit=$cap rpc=$rp p2p=$pp peers=$(printf '%s' "$peers" | jq length) height=$h lag=$((base-h)) hash=$(printf '%s' "$tip" | field hash) peer_id=$peer"
    else echo "$id node_pid=$np miner_pid=$mp worker_pid=$worker cpu_limit=$cap rpc=$rp OFFLINE"; failed=1; fi
  done < "$ROOT/cluster.state"
  if [ "$failed" -eq 0 ]; then intervals; fi
}
snapshot() {
  local out="$ROOT/evidence/${1:-snapshot}-$(date -u +%Y%m%dT%H%M%S)-$$.txt" id r rp pp peer
  { status
    while read -r id r rp pp peer; do
      echo "=== $id ==="; rpc "$id" get_tip_header || true; rpc "$id" get_peers || true
    done < "$ROOT/cluster.state"
  } > "$out"
  log "Snapshot: $out"
}
# Rebind only after all processes are stopped. Prepare and validate every file
# before replacing any of them; leave unrelated config sections unchanged.
configure_bindings() {
  local id r rp pp peer changed=0 rpc_addr p2p_addr
  while read -r id r rp pp peer; do
    lookup "$id"
    rpc_addr=$(awk '/^\[/ {s=$0} s=="[rpc]" && /^listen_address[[:space:]]*=/ {split($0,a,"\"");print a[2]}' "$DIR/ckb.toml")
    p2p_addr=$(awk '/^\[/ {s=$0} s=="[network]" && /^listen_addresses[[:space:]]*=/ {split($0,a,"\"");print a[2]}' "$DIR/ckb.toml")
    [ "$rpc_addr" = "$RPC_BIND:$rp" ] && [ "$p2p_addr" = "/ip4/$P2P_BIND/tcp/$pp" ] || changed=1
  done < "$ROOT/cluster.state"
  if [ "$changed" = 1 ]; then
    while read -r id r rp pp peer; do
      lookup "$id"
      if alive "$DIR/node.pid" || alive "$DIR/miner.pid"; then
        die 'Stop all cluster processes with down before changing RPC/P2P bindings'
      fi
    done < "$ROOT/cluster.state"
    while read -r id r rp pp peer; do
      lookup "$id"
      awk -v rpc="$RPC_BIND:$rp" -v p2p="/ip4/$P2P_BIND/tcp/$pp" '
        /^\[/ {s=$0}
        s=="[rpc]" && /^listen_address[[:space:]]*=/ {print "listen_address = \"" rpc "\"";nr++;next}
        s=="[network]" && /^listen_addresses[[:space:]]*=/ {print "listen_addresses = [\"" p2p "\"]";np++;next}
        {print}
        END {if (nr!=1 || np!=1) exit 1}
      ' "$DIR/ckb.toml" > "$DIR/ckb.toml.bind-next" || die "Invalid binding fields in $id config; original retained"
    done < "$ROOT/cluster.state"
    while read -r id r rp pp peer; do
      lookup "$id"; mv "$DIR/ckb.toml.bind-next" "$DIR/ckb.toml"
    done < "$ROOT/cluster.state"
  fi
  save_env
}
cmd_up() {
  local id r rp pp peer initial end wait_s
  [ -f "$ROOT/.ready" ] || cmd_init
  need_ckb
  [ "$("$CKB_BIN" --version)" = "$(cat "$ROOT/shared/ckb.version")" ] || die 'CKB version changed; use original binary'
  # Preflight all stopped-node ports before starting any node.
  local ports=()
  while read -r id r rp pp peer; do
    cmp -s "$ROOT/shared/spec.toml" "$ROOT/nodes/$id/specs/dev.toml" || die "$id spec changed"
    lookup "$id"
    if ! alive "$DIR/node.pid"; then ports+=("$rp" "$pp"); fi
  done < "$ROOT/cluster.state"
  if [ "${#ports[@]}" -gt 0 ]; then free_ports "${ports[@]}"; fi
  prepare_miner_cpu
  configure_bindings
  if [ "$RPC_BIND" = 0.0.0.0 ]; then log 'RPC listens on all IPv4 interfaces; restrict access to trusted hosts with a firewall'; fi
  while read -r id r rp pp peer; do lookup "$id"; launch node run; done < "$ROOT/cluster.state"
  while read -r id r rp pp peer; do wait_rpc "$id"; done < "$ROOT/cluster.state"
  connect_peers
  initial=$(height miner-0); resume
  if [ "$MINING_MODE" != ondemand ]; then
    wait_s=$((BLOCK_INTERVAL_MS*MINERS*5/1000+30))
    [ "$POW_ALGO" != eaglesong ] || wait_s=$TIMEOUT
    end=$((SECONDS+wait_s))
    until [ "$(height miner-0)" -ge "$((initial+4))" ]; do
      [ "$SECONDS" -lt "$end" ] || die 'Mining timeout: main-chain height did not advance four blocks'
      sleep 1
    done
  fi
  wait_views; status; snapshot baseline
}
down() {
  local id r rp pp peer
  [ "$NODE" = all ] || lookup "$NODE"
  # Stop mining first, including when the selected node is a sync node.
  while read -r id r rp pp peer; do
    if [ "$NODE" = all ] || [ "$NODE" = "$id" ]; then stop_pid "$ROOT/nodes/$id/miner.pid"; fi
  done < "$ROOT/cluster.state"
  while read -r id r rp pp peer; do
    if [ "$NODE" = all ] || [ "$NODE" = "$id" ]; then
      stop_pid "$ROOT/nodes/$id/node.pid"; log "Stopped $id; data retained"
    fi
  done < "$ROOT/cluster.state"
}
# An atomic directory lock serializes commands; no automatic stale-lock deletion.
LOCKED=0 MINE_ACTIVE=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$MINE_ACTIVE" = 1 ]; then
    stop_pid "$ROOT/nodes/$NODE/miner.pid" || true
    if [ -f "$ROOT/nodes/$NODE/ckb-miner.toml.before-mine" ]; then
      mv "$ROOT/nodes/$NODE/ckb-miner.toml.before-mine" "$ROOT/nodes/$NODE/ckb-miner.toml"
    fi
  fi
  if [ "$rc" -ne 0 ] && [ -d "$ROOT/nodes" ]; then
    for file in "$ROOT"/nodes/*/logs/*.log; do [ ! -f "$file" ] || { echo "=== $file (last 20 lines) ===" >&2; tail -n 20 "$file" >&2; }; done
  fi
  if [ "$LOCKED" = 1 ]; then rm -f "$ROOT/.lock/owner"; rmdir "$ROOT/.lock" 2>/dev/null || true; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ ! -e "$ROOT" ]; then
  case "$CMD" in
    init|up) mkdir -p "$ROOT";;
    down) log "Already stopped: $ROOT does not exist"; exit 0;;
    clean) [ "$FORCE" = 1 ] || die 'Repeat with --force to confirm cleanup'; log "Already clean: $ROOT"; exit 0;;
    *) die 'Cluster not initialized';;
  esac
fi
if [ ! -f "$ROOT/.ckb-cluster" ]; then
  [ -z "$(ls -A "$ROOT")" ] || die 'Root is not an empty directory or a marked CKB cluster'
  case "$CMD" in init|up) ;; *) die 'Cluster not initialized';; esac
fi
mkdir "$ROOT/.lock" 2>/dev/null || die "Cluster command already running; inspect $ROOT/.lock/owner"
LOCKED=1; echo "$$" > "$ROOT/.lock/owner"
# The shared spec is the persisted source of truth, including for old clusters
# whose cluster.env predates POW_ALGO. Do not change consensus via config edits.
case "$CMD" in
  init|up|resume-mining|mine|add-node)
    if [ -f "$ROOT/shared/spec.toml" ]; then
      spec_pow=$(awk '
        /^\[/ { section=$0 }
        section=="[pow]" && /^func[[:space:]]*=/ { split($0,a,"\""); print a[2] }
      ' "$ROOT/shared/spec.toml")
      expected_pow=Dummy; [ "$POW_ALGO" != eaglesong ] || expected_pow=Eaglesong
      [ "$spec_pow" = "$expected_pow" ] || die 'PoW differs from the saved chain spec; restore POW_ALGO or use a new --root'
    fi;;
esac
case "$CMD" in
  init) cmd_init;;
  up) cmd_up;;
  down) down;;
  status) status;;
  pause-mining) pause;;
  resume-mining) need_ckb; resume;;
  mine)
    [ "$MINING_MODE" = ondemand ] || die 'mine requires MINING_MODE=ondemand'
    [ "$NODE" != all ] || NODE=miner-0
    lookup "$NODE"; [ "$R" = miner ] || die 'Select a miner'
    alive "$DIR/node.pid" || die 'Run up first'
    for f in "$ROOT"/nodes/*/miner.pid; do if alive "$f"; then die 'Pause all miners before mine'; fi; done
    need_ckb; prepare_miner_cpu; save_env; initial=$(height "$NODE"); target=$((initial+BLOCKS)); end=$((SECONDS+TIMEOUT))
    cp "$DIR/ckb-miner.toml" "$DIR/ckb-miner.toml.before-mine"; MINE_ACTIVE=1
    write_miner 1000; launch miner miner
    until [ "$(height "$NODE")" -ge "$target" ]; do
      [ "$SECONDS" -lt "$end" ] || die "mine timeout; target=$target"
      sleep 0.2
    done
    stop_pid "$DIR/miner.pid"; mv "$DIR/ckb-miner.toml.before-mine" "$DIR/ckb-miner.toml"; MINE_ACTIVE=0
    log "Mined: start=$initial target=$target actual=$(height "$NODE")";;
  add-node)
    [ -f "$ROOT/.ready" ] || die 'Initialize first'
    need_ckb; [ "$ROLE" != miner ] || prepare_miner_cpu
    lookup miner-0; alive "$DIR/node.pid" || die 'Run up first'
    idx=$(wc -l < "$ROOT/cluster.state"); [ "$idx" -lt 64 ] || die 'Maximum 64 nodes'
    next=$(awk -v role="$ROLE" '$2==role {split($1,a,"-"); if(a[2]>=n)n=a[2]+1}END{print n+0}' "$ROOT/cluster.state")
    id="$ROLE-$next"
    # Cross-check against every allocated RPC and P2P port, even if stopped.
    awk -v a="$((RPC_BASE+idx))" -v b="$((P2P_BASE+idx))" '$3==a||$4==a||$3==b||$4==b {exit 1}' "$ROOT/cluster.state" || die 'Port ranges overlap'
    init_node "$id" "$ROLE" "$idx"
    if [ "$ROLE" = miner ]; then MINERS=$((MINERS+1)); else SYNCS=$((SYNCS+1)); fi
    save_env; lookup "$id"; launch node run; wait_rpc "$id"; connect_peers; wait_views
    if [ "$ROLE" = miner ]; then NODE=all; pause; resume; fi
    status;;
  logs)
    [ "$NODE" != all ] || die 'Specify --node ID'; lookup "$NODE"
    # Log following should not hold the control lock.
    rm -f "$ROOT/.lock/owner"; rmdir "$ROOT/.lock"; LOCKED=0
    if [ "$FOLLOW" = 1 ]; then tail -n 100 -F "$DIR/logs/node.log" "$DIR/logs/miner.log"
    else for f in "$DIR"/logs/*.log; do [ ! -f "$f" ] || tail -n 100 "$f"; done; fi;;
  snapshot) snapshot;;
  export)
    snapshot
    stage=$(mktemp -d "$ROOT/evidence/export.XXXXXX")
    cp "$ROOT/cluster.env" "$ROOT/cluster.state" "$stage/"
    cp -R "$ROOT/shared" "$stage/shared"
    mkdir "$stage/evidence"; cp "$ROOT"/evidence/*.txt "$stage/evidence/"
    while read -r id r rp pp peer; do
      mkdir -p "$stage/nodes/$id/logs"
      cp "$ROOT/nodes/$id/ckb.toml" "$ROOT/nodes/$id/ckb-miner.toml" "$stage/nodes/$id/"
      for f in "$ROOT/nodes/$id"/logs/*.log; do [ ! -f "$f" ] || tail -n 2000 "$f" > "$stage/nodes/$id/logs/$(basename "$f")"; done
    done < "$ROOT/cluster.state"
    archive="$ROOT/evidence/ckb-cluster-$(date -u +%Y%m%dT%H%M%S)-$$.tar.gz"
    tar -czf "$archive" -C "$stage" .; rm -r "$stage"; echo "$archive";;
  clean)
    [ "$FORCE" = 1 ] || die 'Deletes this cluster directory; repeat with --force'
    [ "$NODE" = all ] || die 'clean removes the entire cluster; omit --node'
    [ "$(cat "$ROOT/.ckb-cluster")" = ckb-cluster-v1 ] || die 'Invalid cluster marker'
    down; rm -rf -- "$ROOT"; LOCKED=0; log "Removed $ROOT";;
esac
