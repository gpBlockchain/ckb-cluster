#!/usr/bin/env bash
# Internal supervisor for a CPU-capped and/or paced miner. Not a cluster CLI entry point.
set -euo pipefail
umask 077
MODE=${1:-}; shift || true
same_process() {
  local file=$1 pid stamp command
  [ -f "$file" ] || return 1
  { read -r pid; IFS= read -r stamp; IFS= read -r command; } < "$file" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
  [ -n "$stamp" ] && [ -n "$command" ] || return 1
  kill -0 "$pid" 2>/dev/null &&
    [ "$(ps -p "$pid" -o lstart= 2>/dev/null)" = "$stamp" ] &&
    [ "$(ps -p "$pid" -o command= 2>/dev/null)" = "$command" ]
}
same_starting_child() {
  local pid stamp
  [ -f "$DIR/miner-pacer.pid" ] || return 1
  { read -r pid; IFS= read -r stamp; } < "$DIR/miner-pacer.pid"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
  [ "$(ps -p "$pid" -o ppid= 2>/dev/null | awk '{print $1}')" = "$$" ] &&
    [ "$(ps -p "$pid" -o lstart= 2>/dev/null)" = "$stamp" ]
}
record_process() {
  local file=$1 pid=$2
  { echo "$pid"; ps -p "$pid" -o lstart=; ps -p "$pid" -o command=; } > "$file"
}
stop_recorded() {
  local file=$1 pid n
  if same_process "$file"; then
    read -r pid < "$file"
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    for ((n=0;n<40;n++)); do same_process "$file" || break; sleep 0.1; done
    if same_process "$file"; then kill -KILL "$pid" 2>/dev/null || true; fi
    for ((n=0;n<20;n++)); do same_process "$file" || break; sleep 0.1; done
    if same_process "$file"; then echo "Failed to stop supervised process $pid" >&2; return 1; fi
  fi
  rm -f "$file"
}
stop_children() {
  # Stop throttling first, then wake and terminate a possibly suspended miner.
  stop_recorded "$DIR/miner-limiter.pid"
  stop_recorded "$DIR/miner-worker.pid"
  if [ "${PACER_STARTING:-0}" = 1 ] && same_starting_child; then
    read -r pacer < "$DIR/miner-pacer.pid"
    record_process "$DIR/miner-pacer.pid" "$pacer"
  fi
  stop_recorded "$DIR/miner-pacer.pid"
  rm -f "$DIR/miner-pacer.url"
  # Recover the direct RPC URL even after an interrupted previous supervisor.
  if [ -f "$DIR/ckb-miner.toml" ]; then
    local url
    url=$(awk '/^# upstream_rpc_url = / {print $4}' "$DIR/ckb-miner.toml")
    if [ -n "$url" ]; then
      awk -v url="$url" '/^rpc_url = / {$0="rpc_url = " url} {print}' "$DIR/ckb-miner.toml" > "$DIR/ckb-miner.toml.rpc-next"
      mv "$DIR/ckb-miner.toml.rpc-next" "$DIR/ckb-miner.toml"
    fi
  fi
}
if [ "$MODE" = cleanup ]; then
  [ $# -eq 1 ] || exit 2
  DIR=$1
  stop_children
  exit 0
fi
[ "$MODE" = run ] && [ $# -eq 5 ] && [ "$4" = --node-dir ] || {
  echo 'Internal usage: miner-runner.sh run CPU CPULIMIT CKB --node-dir DIR' >&2; exit 2;
}
CPU=$1 LIMITER=$2 CKB=$3 DIR=$5
[[ "$CPU" =~ ^(0|[1-9]|[1-9][0-9]|100)$ ]] || exit 2
[ -x "$CKB" ] && [ -d "$DIR" ] || exit 2
[ "$CPU" = 0 ] || [ -x "$LIMITER" ] || exit 2
PACING=0
[ ! -f "$DIR/miner.pacing-ms" ] || read -r PACING < "$DIR/miner.pacing-ms"
[[ "$PACING" =~ ^(0|[1-9][0-9]{0,8})$ ]] || exit 2
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  stop_children || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
stop_children
if [ "$PACING" -gt 0 ]; then
  PROJECT=$(cd "$(dirname "$0")" && pwd -P)
  upstream=$(awk -F '"' '/^# upstream_rpc_url = / {print $2}' "$DIR/ckb-miner.toml")
  read -r PYTHON < "$DIR/miner.python"
  PACER_STARTING=1
  "$PYTHON" "$PROJECT/eaglesong-pacer.py" --upstream "$upstream" --interval-ms "$PACING" \
    --ready-file "$DIR/miner-pacer.url" > "$DIR/logs/pacer.log" 2>&1 &
  record_process "$DIR/miner-pacer.pid" "$!"
  for ((n=0;n<100;n++)); do
    # macOS framework Python execs its app binary before entering Python code.
    # Until readiness, verify our direct child and birth time, not its argv[0].
    same_starting_child || { echo 'Eaglesong pacer exited during startup' >&2; exit 1; }
    [ ! -s "$DIR/miner-pacer.url" ] || break
    sleep 0.1
  done
  [ -s "$DIR/miner-pacer.url" ] || { echo 'Eaglesong pacer startup timed out' >&2; exit 1; }
  read -r pacer < "$DIR/miner-pacer.pid"
  record_process "$DIR/miner-pacer.pid" "$pacer"
  PACER_STARTING=0
  read -r url < "$DIR/miner-pacer.url"
  awk -v url="$url" '/^rpc_url = / {$0="rpc_url = \"" url "\""} {print}' "$DIR/ckb-miner.toml" > "$DIR/ckb-miner.toml.rpc-next"
  mv "$DIR/ckb-miner.toml.rpc-next" "$DIR/ckb-miner.toml"
fi
"$CKB" miner -C "$DIR" &
worker=$!
record_process "$DIR/miner-worker.pid" "$worker"
if [ "$CPU" -gt 0 ]; then
  "$LIMITER" --pid "$worker" --limit "$CPU" > "$DIR/logs/cpulimit.log" 2>&1 &
  limiter=$!
  record_process "$DIR/miner-limiter.pid" "$limiter"
fi
printf '%s\n' "$CPU" > "$DIR/miner.cpu-limit"
while same_process "$DIR/miner-worker.pid"; do
  if [ "$CPU" -gt 0 ] && ! same_process "$DIR/miner-limiter.pid"; then
    echo 'CPU limiter exited unexpectedly; stopping this miner rather than running uncapped' >&2
    exit 1
  fi
  if [ "$PACING" -gt 0 ] && ! same_process "$DIR/miner-pacer.pid"; then
    echo 'Eaglesong pacer exited unexpectedly; stopping miner rather than running unpaced' >&2
    exit 1
  fi
  sleep 0.5
done
rc=0; wait "$worker" || rc=$?
exit "$rc"
