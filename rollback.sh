#!/usr/bin/env bash
# Operational rollback: stop only this cluster's processes, preserve all data.
set -euo pipefail
PROJECT_DIR=$(cd "$(dirname "$0")" && pwd -P)
exec "$PROJECT_DIR/ckb-cluster.sh" down --root "${1:-$PROJECT_DIR/tmp}"
