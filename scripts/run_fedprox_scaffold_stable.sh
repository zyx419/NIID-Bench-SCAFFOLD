#!/usr/bin/env bash
set -euo pipefail

# Stable SCAFFOLD settings verified on FedProx JSON datasets:
# LR=0.001 avoids the exploding global cross-entropy loss seen with LR=0.01.
# LOCAL_EPOCHS=10 reduces client drift compared with LOCAL_EPOCHS=20.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export LR="${LR:-0.001}"
export LOCAL_EPOCHS="${LOCAL_EPOCHS:-10}"
export COMM_ROUNDS="${COMM_ROUNDS:-200}"
export BATCH_SIZE="${BATCH_SIZE:-10}"
export RUN_ID="${RUN_ID:-stable-lr${LR}-ep${LOCAL_EPOCHS}-$(date +%Y%m%d-%H%M%S)}"

exec "$ROOT_DIR/scripts/run_fedprox_scaffold.sh" "$@"
