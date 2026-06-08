#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$HOME/.niidbench/pyenv-root/versions/niidbench-py37/bin/python}"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data/fedprox_raw}"
RUN_ROOT="${RUN_ROOT:-$ROOT_DIR/logs/fedprox_scaffold}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
DEVICE="${DEVICE:-cpu}"
SEED="${SEED:-0}"
COMM_ROUNDS="${COMM_ROUNDS:-200}"
LOCAL_EPOCHS="${LOCAL_EPOCHS:-20}"
BATCH_SIZE="${BATCH_SIZE:-10}"
LR="${LR:-0.01}"
RHO="${RHO:-0}"
SAMPLE_SYNTHETIC="${SAMPLE_SYNTHETIC:-0.3333333333}"
SAMPLE_MNIST="${SAMPLE_MNIST:-0.01}"
SAMPLE_FEMNIST="${SAMPLE_FEMNIST:-0.05}"

DEFAULT_DATASETS=(
  fedprox_synthetic_0_0
  fedprox_synthetic_0.5_0.5
  fedprox_synthetic_1_1
  fedprox_synthetic_iid
  fedprox_mnist
  fedprox_femnist
)

if [[ $# -gt 0 ]]; then
  DATASETS=("$@")
elif [[ -n "${DATASETS:-}" ]]; then
  read -r -a DATASETS <<<"$DATASETS"
else
  DATASETS=("${DEFAULT_DATASETS[@]}")
fi

RUN_DIR="$RUN_ROOT/$RUN_ID"
CONSOLE_DIR="$RUN_DIR/console"
EXPERIMENT_LOG_DIR="$RUN_DIR/experiment_logs"
CSV_DIR="$RUN_DIR/csv"
MANIFEST="$RUN_DIR/manifest.tsv"

sample_for_dataset() {
  case "$1" in
    fedprox_mnist) echo "$SAMPLE_MNIST" ;;
    fedprox_femnist) echo "$SAMPLE_FEMNIST" ;;
    fedprox_synthetic_*) echo "$SAMPLE_SYNTHETIC" ;;
    *) echo "1" ;;
  esac
}

export_metrics_csv() {
  local dataset="$1"
  local log_file="$2"
  local csv_file="$3"

  "$PYTHON_BIN" - "$dataset" "$log_file" "$csv_file" <<'PY'
import csv
import re
import sys

dataset, log_file, csv_file = sys.argv[1:4]
round_no = None
rows = []
current = None

round_re = re.compile(r'in comm round:(\d+)')
train_re = re.compile(r'>> Global Model Train accuracy: ([0-9.eE+-]+)')
test_re = re.compile(r'>> Global Model Test accuracy: ([0-9.eE+-]+)')
train_loss_re = re.compile(r'>> Global Model Train loss: ([0-9.eE+-]+)')
test_loss_re = re.compile(r'>> Global Model Test loss: ([0-9.eE+-]+)')

def flush_current():
    if current is not None and current.get('test_accuracy') is not None:
        rows.append(current.copy())

with open(log_file, 'r') as f:
    for line in f:
        m = round_re.search(line)
        if m:
            flush_current()
            round_no = int(m.group(1))
            current = {
                'dataset': dataset,
                'round': round_no,
                'train_accuracy': None,
                'test_accuracy': None,
                'train_loss': None,
                'test_loss': None,
            }
            continue
        m = train_re.search(line)
        if m and current is not None:
            current['train_accuracy'] = float(m.group(1))
            continue
        m = test_re.search(line)
        if m and current is not None:
            current['test_accuracy'] = float(m.group(1))
            continue
        m = train_loss_re.search(line)
        if m and current is not None:
            current['train_loss'] = float(m.group(1))
            continue
        m = test_loss_re.search(line)
        if m and current is not None:
            current['test_loss'] = float(m.group(1))

flush_current()

with open(csv_file, 'w', newline='') as f:
    writer = csv.DictWriter(
        f,
        fieldnames=['dataset', 'round', 'train_accuracy', 'test_accuracy', 'train_loss', 'test_loss'],
    )
    writer.writeheader()
    writer.writerows(rows)
PY
}

run_experiment_with_live_logs() {
  local console_log="$1"
  local experiment_log="$2"
  shift 2

  : > "$console_log"
  mkdir -p "$(dirname "$experiment_log")"
  local status_file
  status_file="$(mktemp)"

  set +e
  (
    "$@" 2>&1 \
      | sed -u 's/^/[console] /' \
      | tee -a "$console_log"
    echo "${PIPESTATUS[0]}" > "$status_file"
  ) &
  local cmd_pid=$!

  for _ in $(seq 1 60); do
    if [[ -s "$experiment_log" ]]; then
      break
    fi
    if ! kill -0 "$cmd_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if [[ -f "$experiment_log" ]]; then
    tail -n +1 --pid="$cmd_pid" -F "$experiment_log" 2>/dev/null \
      | sed -u 's/^/[experiment] /' \
      | tee -a "$console_log" &
    local tail_pid=$!
  else
    local tail_pid=""
  fi

  wait "$cmd_pid"
  if [[ -n "$tail_pid" ]]; then
    wait "$tail_pid" >/dev/null 2>&1 || true
  fi
  local cmd_status
  cmd_status="$(cat "$status_file" 2>/dev/null || echo 1)"
  rm -f "$status_file"
  set -e
  return "$cmd_status"
}

main() {
  if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python runtime not found: $PYTHON_BIN" >&2
    echo "Run scripts/setup_niidbench_env.sh first, or set PYTHON_BIN=/path/to/python." >&2
    exit 1
  fi

  mkdir -p "$CONSOLE_DIR" "$EXPERIMENT_LOG_DIR" "$CSV_DIR"
  printf "dataset\tseed\tdevice\tcomm_rounds\tlocal_epochs\tbatch_size\tlr\tsample\tconsole_log\texperiment_log\tcsv\n" > "$MANIFEST"

  for dataset in "${DATASETS[@]}"; do
    sample="$(sample_for_dataset "$dataset")"
    log_name="${dataset}_scaffold_seed${SEED}"
    console_log="$CONSOLE_DIR/${log_name}.console.log"
    experiment_log="$EXPERIMENT_LOG_DIR/${log_name}.log"
    csv_file="$CSV_DIR/${log_name}.csv"

    if [[ ! -d "$DATA_DIR/$dataset/data/train" || ! -d "$DATA_DIR/$dataset/data/test" ]]; then
      echo "Missing FedProx dataset directory: $DATA_DIR/$dataset" >&2
      exit 1
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$dataset" "$SEED" "$DEVICE" "$COMM_ROUNDS" "$LOCAL_EPOCHS" "$BATCH_SIZE" "$LR" "$sample" \
      "$console_log" "$experiment_log" "$csv_file" >> "$MANIFEST"

    echo "[$(date '+%F %T')] Running $dataset"
    run_experiment_with_live_logs "$console_log" "$experiment_log" \
      bash -c 'cd "$1" && shift && "$@"' _ "$ROOT_DIR" \
      "$PYTHON_BIN" experiments.py \
        --model=mlp \
        --dataset="$dataset" \
        --alg=scaffold \
        --partition=fedprox-json \
        --datadir="$DATA_DIR" \
        --logdir="$EXPERIMENT_LOG_DIR" \
        --log_file_name="$log_name" \
        --comm_round="$COMM_ROUNDS" \
        --epochs="$LOCAL_EPOCHS" \
        --batch-size="$BATCH_SIZE" \
        --lr="$LR" \
        --rho="$RHO" \
        --sample="$sample" \
        --init_seed="$SEED" \
        --device="$DEVICE"

    export_metrics_csv "$dataset" "$experiment_log" "$csv_file"
    echo "[$(date '+%F %T')] Finished $dataset -> $csv_file"
  done

  echo "Run directory: $RUN_DIR"
  echo "Manifest: $MANIFEST"
}

main "$@"
