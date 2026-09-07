#!/usr/bin/env bash
# Stop all nodes, or --node ID; preserve chain data and logs.
set -euo pipefail
PROJECT_DIR=$(cd "$(dirname "$0")" && pwd -P)
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  echo 'Usage: ./stop-ckb.sh [--node miner-0|sync-0|all] [--root DIR]'
  echo 'Default: stop all nodes in PROJECT/tmp; preserve data and downloaded CKB.'
  exit 0
fi
exec "$PROJECT_DIR/ckb-cluster.sh" down "$@"
