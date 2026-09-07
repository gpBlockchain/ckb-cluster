#!/usr/bin/env bash
# Stop the cluster before deleting its data; keep source and downloaded CKB.
set -euo pipefail
PROJECT_DIR=$(cd "$(dirname "$0")" && pwd -P)
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  echo 'Usage: ./clean-ckb.sh --force [--root DIR]'
  echo 'Deletes PROJECT/tmp by default: chain data, configs, peer keys, logs and evidence.'
  echo 'Stops nodes/miners first; preserves bin/, scripts and other project files.'
  exit 0
fi
exec "$PROJECT_DIR/ckb-cluster.sh" clean "$@"
