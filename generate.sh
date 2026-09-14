#!/usr/bin/env bash
# Immagine 2D -> modello 3D texturizzato (+ rigging opzionale).
#
#   ./generate.sh                 elabora tutte le immagini in ./images
#   RIG=1 ./generate.sh           genera anche l'FBX riggato
#   OCTREE_RESOLUTION=512 ./generate.sh
#
# Un'immagine per modello (png/jpg/jpeg/webp). I risultati vanno in output/NNN.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERE/scripts/lib.sh"
load_config
require_docker

IMAGE="$IMAGE_TAG"
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "immagine ${IMAGE} non trovata. Lancia prima:  ./setup.sh"
if ! image_is_current "$IMAGE" && [ "${DEV:-0}" != "1" ]; then
  die "l'immagine ${IMAGE} e' vecchia (manca /opt/scripts). Rilancia ./setup.sh, oppure DEV=1 ./generate.sh"
fi

IMAGES_DIR="$(realpath -m "${IMAGES_DIR:-./images}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR:-./output}")"
CKPTS_DIR="$(realpath -m "${CKPTS_DIR:-./ckpts}")"

shopt -s nullglob nocaseglob
imgs=("$IMAGES_DIR"/*.png "$IMAGES_DIR"/*.jpg "$IMAGES_DIR"/*.jpeg "$IMAGES_DIR"/*.webp)
shopt -u nocaseglob
[ "${#imgs[@]}" -gt 0 ] || die "nessuna immagine in ${IMAGES_DIR} (png/jpg/jpeg/webp)"
[ -d "$CKPTS_DIR/Hunyuan3D-2.1" ] || die "pesi non trovati. Lancia ./setup.sh"
if [ "${RIG:-0}" = "1" ] && [ ! -d "$CKPTS_DIR/UniRig" ]; then
  die "RIG=1 ma i pesi UniRig non ci sono. Lancia: RIG=1 ./setup.sh"
fi
mkdir -p "$OUTPUT_DIR"

# una run alla volta: due generazioni insieme non ci stanno in VRAM
if [ -n "$(docker ps -q --filter 'name=^img23d-run$' 2>/dev/null || true)" ]; then
  die "c'e' gia' una generazione in corso (img23d-run). Fermala con: docker stop img23d-run"
fi

DEV_MOUNTS=()
if [ "${DEV:-0}" = "1" ]; then
  for f in "$HERE"/scripts/*; do
    [ -f "$f" ] && DEV_MOUNTS+=(-v "$f":/opt/scripts/"$(basename "$f")":ro)
  done
  info "DEV=1: ${#DEV_MOUNTS[@]} script montati dall'host (niente rebuild)"
fi

say "Generazione"
echo "  immagine : $IMAGE"
echo "  input    : $IMAGES_DIR  (${#imgs[@]} immagini)"
echo "  output   : $OUTPUT_DIR"
echo "  shape    : ${SHAPE_STEPS} step / octree ${OCTREE_RESOLUTION}   texture ${TEXTURE_RESOLUTION}px"
echo "  rigging  : $( [ "${RIG:-0}" = 1 ] && echo 'ON (UniRig)' || echo off )"

docker run --rm --gpus all \
  --name img23d-run \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e HF_HOME=/data/ckpts/hf -e HY3DGEN_MODELS=/data/ckpts \
  -e SHAPE_STEPS -e SHAPE_GUIDANCE -e TEXTURE_STEPS -e TEXTURE_RESOLUTION \
  -e OCTREE_RESOLUTION -e REMOVE_BACKGROUND -e RIG \
  -e RIG_UE_NAMES -e RIG_FLIP_LR -e EXPORT_TEXTURES \
  -e PS2_TEXTURE -e PS2_TEXTURE_SIZE -e PS2_POSTERIZE \
  -e POST_DECIMATE_FACES -e POST_QUAD_REMESH -e POST_QUAD_FACES -e EXPORT_FORMATS \
  -e PREVIEW -e PREVIEW_FORMAT -e PREVIEW_FRAMES \
  -v "$IMAGES_DIR":/data/input:ro \
  -v "$OUTPUT_DIR":/data/output \
  -v "$CKPTS_DIR":/data/ckpts \
  -v "$CKPTS_DIR/Hunyuan3D-2.1":/opt/hunyuan/ckpts/Hunyuan3D-2.1 \
  ${RIG:+-v "$CKPTS_DIR/UniRig":/opt/unirig/ckpts} \
  ${DEV_MOUNTS[@]+"${DEV_MOUNTS[@]}"} \
  --shm-size="${SHM_SIZE:-16g}" \
  "$IMAGE"

say "Fatto"
shopt -s nullglob
for d in "$OUTPUT_DIR"/[0-9][0-9][0-9]; do
  extra=""
  [ -f "$d/model_light.glb" ]  && extra="$extra +light"
  [ -f "$d/model_retopo.glb" ] && extra="$extra +retopo"
  [ -f "$d/model_rigged.fbx" ] && extra="$extra +rig"
  echo "  $(basename "$d")/  model.glb$extra"
done
echo
echo "  guarda un modello senza aprire nulla:"
echo "    mpv $(ls "$OUTPUT_DIR"/[0-9][0-9][0-9]/preview.* 2>/dev/null | tail -1 2>/dev/null)"
