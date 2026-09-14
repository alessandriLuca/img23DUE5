#!/usr/bin/env bash
# Scarica i pesi in ./ckpts. Chiamato da setup.sh, usabile da solo.
# I download passano DENTRO il container (ha huggingface-cli): su Ubuntu 24.04
# `pip install --user` fallisce con externally-managed-environment (PEP 668).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_config
require_docker

CKPTS_DIR="$(realpath -m "${CKPTS_DIR:-./ckpts}")"
mkdir -p "$CKPTS_DIR"
IMG="${IMAGE:-$IMAGE_TAG}"

# hf <repo> <sottocartella> [args extra]
hf() {
  local repo="$1" sub="$2"; shift 2
  local cont="/ckpts/$sub"
  if command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$repo" "$@" --local-dir "$CKPTS_DIR/$sub"
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e HOME=/tmp -e HF_HOME=/tmp/hf -v "$CKPTS_DIR":/ckpts \
      --entrypoint huggingface-cli "$IMG" \
      download "$repo" "$@" --local-dir "$cont"
  fi
}

have() { [ -d "$CKPTS_DIR/$1" ] && [ -n "$(ls -A "$CKPTS_DIR/$1" 2>/dev/null)" ]; }

# --- Hunyuan3D-2.1: shape + paint PBR ---
if have Hunyuan3D-2.1; then
  info "Hunyuan3D-2.1: gia' presente"
else
  info "Hunyuan3D-2.1 (shape + paint PBR, ~30GB) ..."
  hf tencent/Hunyuan3D-2.1 Hunyuan3D-2.1
fi

# --- UniRig: solo se il rigging e' attivo ---
if [ "${RIG:-0}" = "1" ]; then
  if have UniRig; then
    info "UniRig: gia' presente"
  else
    info "UniRig (rigging automatico) ..."
    hf VAST-AI/UniRig UniRig
  fi
fi

echo
info "contenuto di ${CKPTS_DIR}: $(ls -1 "$CKPTS_DIR" | tr '\n' ' ')"
info "spazio occupato: $(du -sh "$CKPTS_DIR" 2>/dev/null | cut -f1)"
