#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.niidbench/pyenv-root}"
ZLIB_PREFIX="${NIIDBENCH_ZLIB_PREFIX:-$HOME/.niidbench/zlib-local}"
PYTHON_VERSION="${NIIDBENCH_PYTHON_VERSION:-3.7.17}"
ENV_NAME="${NIIDBENCH_ENV_NAME:-niidbench-py37}"
PYTHON_BIN="$PYENV_ROOT/versions/$ENV_NAME/bin/python"
PIP_BIN="$PYENV_ROOT/versions/$ENV_NAME/bin/pip"
PIP_CACHE_DIR="${NIIDBENCH_PIP_CACHE_DIR:-$HOME/.niidbench/pip-cache}"

export PYENV_ROOT
export PATH="$PYENV_ROOT/bin:$PATH"
export PIP_CACHE_DIR

ensure_pyenv() {
  if [[ ! -x "$PYENV_ROOT/bin/pyenv" ]]; then
    git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
  fi

  if [[ ! -d "$PYENV_ROOT/plugins/pyenv-virtualenv" ]]; then
    git clone https://github.com/pyenv/pyenv-virtualenv.git \
      "$PYENV_ROOT/plugins/pyenv-virtualenv"
  fi
}

ensure_local_zlib() {
  if [[ -f "$ZLIB_PREFIX/lib/libz.a" && -f "$ZLIB_PREFIX/include/zlib.h" ]]; then
    return
  fi

  rm -rf /tmp/niidbench-zlib-src
  git clone https://github.com/madler/zlib.git /tmp/niidbench-zlib-src
  pushd /tmp/niidbench-zlib-src >/dev/null
  ./configure --prefix="$ZLIB_PREFIX"
  make -j"$(nproc)"
  make install
  popd >/dev/null
}

install_python() {
  if [[ -x "$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python" ]]; then
    return
  fi

  CPPFLAGS="-I$ZLIB_PREFIX/include" \
  LDFLAGS="-L$ZLIB_PREFIX/lib" \
  PKG_CONFIG_PATH="$ZLIB_PREFIX/lib/pkgconfig" \
  pyenv install "$PYTHON_VERSION"
}

create_virtualenv() {
  if [[ -x "$PYTHON_BIN" ]]; then
    return
  fi

  pyenv virtualenv "$PYTHON_VERSION" "$ENV_NAME"
}

install_requirements() {
  mkdir -p "$PIP_CACHE_DIR"
  "$PIP_BIN" install --upgrade "pip==23.3.2" "setuptools<60" wheel

  # torchvision==0.3.0 imports PIL.PILLOW_VERSION, which was removed in Pillow 7.
  # Install it before requirements so torchvision sees a compatible Pillow, and
  # force it again after requirements in case a resolver upgraded it.
  "$PIP_BIN" install --force-reinstall "Pillow==6.2.2"
  "$PIP_BIN" install -r "$ROOT_DIR/requirements.txt"
  "$PIP_BIN" install --force-reinstall "Pillow==6.2.2"
}

verify_environment() {
  "$PYTHON_BIN" - <<'PY'
import PIL
import numpy
import torch
import torchvision
import sklearn

errors = []
if not hasattr(PIL, "PILLOW_VERSION"):
    errors.append("Pillow is incompatible with torchvision==0.3.0: PIL.PILLOW_VERSION is missing")

expected = {
    "numpy": "1.18.1",
    "torch": "1.1.0",
    "torchvision": "0.3.0",
    "sklearn": "0.22.1",
}
actual = {
    "numpy": numpy.__version__,
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "sklearn": sklearn.__version__,
}
for name, version in expected.items():
    if actual[name] != version:
        errors.append("{} expected {}, got {}".format(name, version, actual[name]))

print("Pillow", PIL.__version__)
for name in ("numpy", "torch", "torchvision", "sklearn"):
    print(name, actual[name])

if errors:
    raise SystemExit("\n".join(errors))
PY
}

main() {
  ensure_pyenv
  ensure_local_zlib
  install_python
  create_virtualenv
  install_requirements
  verify_environment

  cat <<EOF
NIID-Bench environment is ready.
PYENV_ROOT=$PYENV_ROOT
Python: $PYTHON_BIN

Activate:
  export PYENV_ROOT="$PYENV_ROOT"
  export PATH="$PYENV_ROOT/bin:\$PATH"
  eval "\$(pyenv init -)"
  eval "\$(pyenv virtualenv-init -)"
  pyenv activate "$ENV_NAME"

Smoke test:
  "$PYTHON_BIN" experiments.py --model=mlp --dataset=fedprox_synthetic_0_0 --alg=scaffold \\
    --partition=fedprox-json --datadir="$ROOT_DIR/data/fedprox_raw" --logdir="$ROOT_DIR/logs/smoke" \\
    --comm_round=1 --epochs=1 --batch-size=10 --lr=0.01 --sample=0.3333333333 --device=cpu
EOF
}

main "$@"
