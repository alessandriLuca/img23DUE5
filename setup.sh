#!/usr/bin/env bash
# Preparazione una tantum. Non interattivo, idempotente.
#
#   bash setup.sh
#   nohup bash setup.sh > setup.log 2>&1 &      # il build compila estensioni CUDA
#   RIG=1 bash setup.sh                          # scarica anche i pesi UniRig
#
# Fa: controlli -> build immagine -> pesi. La generazione e' ./generate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERE/scripts/lib.sh"
load_config
cd "$HERE"

PROBLEMS=()
problem() { warn "$*"; PROBLEMS+=("$*"); }

# ------------------------------------------------------------- 1. controlli
say "1/3  Controlli"
require_docker
info "docker: $(docker --version | cut -d, -f1)"
if command -v nvidia-smi >/dev/null 2>&1; then
  info "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
else
  warn "nvidia-smi assente: la GPU si verifichera' dentro il container"
fi
FREE=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
info "spazio libero: ${FREE:-?} GB  (immagine ~25GB + pesi ~30GB)"
[ -n "${FREE:-}" ] && [ "$FREE" -lt 70 ] && [ ! -d "${CKPTS_DIR}/Hunyuan3D-2.1" ] \
  && problem "meno di 70 GB liberi: potrebbe non entrare tutto"

chmod +x setup.sh generate.sh scripts/*.sh 2>/dev/null
mkdir -p "$IMAGES_DIR" "$OUTPUT_DIR" "$CKPTS_DIR"

# ---------------------------------------------------------------- 2. build
# Prima dei pesi: fetch_ckpts.sh usa huggingface-cli, che sta nell'immagine.
# Il build compila estensioni CUDA (custom_rasterizer, flash_attn): puo'
# durare parecchio ed e' il punto piu' incline a fallire (vedi README).
say "2/3  Immagine ${IMAGE_TAG}  (il build compila estensioni CUDA, ci mette)"
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  info "SKIP_BUILD=1, salto"
else
  docker build -t "$IMAGE_TAG" . || die "build fallito (vedi README, sezione 'Se il build fallisce')"
  info "build ok"
fi
export IMAGE="$IMAGE_TAG"

# ----------------------------------------------------------------- 3. pesi
say "3/3  Pesi"
./scripts/fetch_ckpts.sh || problem "download dei pesi incompleto"

# ------------------------------------------------------------- riepilogo
say "Riepilogo"
printf '  %-14s %s\n' "immagine" "$IMAGE_TAG"
printf '  %-14s %s\n' "pesi" "$(du -sh "$CKPTS_DIR" 2>/dev/null | cut -f1)"
printf '  %-14s %s\n' "rigging" "$( [ "${RIG:-0}" = 1 ] && echo 'pesi UniRig scaricati' || echo 'off (RIG=1 per abilitarlo)' )"

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  echo; echo "  PROBLEMI:"; for p in "${PROBLEMS[@]}"; do echo "    - $p"; done
  exit 1
fi
echo
echo "  Pronto. Metti un'immagine in images/ e lancia:"
echo "    ./generate.sh"
