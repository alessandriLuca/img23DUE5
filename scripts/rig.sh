#!/usr/bin/env bash
# Rigging automatico di una mesh con UniRig: scheletro -> skin -> merge.
# Gira DENTRO il container. Chiamato da entrypoint.sh quando RIG=1.
#
#   rig.sh <input_mesh.glb> <output_rigged.fbx>
#
# UniRig lavora in tre passi (skeleton, skin, merge). Se uno fallisce, esce
# non-zero e l'entrypoint tiene comunque il GLB texturizzato.
set -euo pipefail

IN="$1"; OUT="$2"
UNIRIG=/opt/unirig
work="$(mktemp -d)"
skel="$work/skeleton.fbx"
skin="$work/skin.fbx"
clean="$work/input_clean.glb"

# UniRig NON legge bene i GLB texturizzati (esportati da Blender: pymeshlab dice
# "Bad glTF json error"). Gli serve solo la GEOMETRIA: la normalizzo con trimesh
# in un GLB pulito, lo stesso formato dei GLB grezzi che gia' digeriva. La texture
# la rimette lo step finale, non UniRig (che comunque la butterebbe).
python3 - "$IN" "$clean" <<'PY'
import sys, trimesh
src, dst = sys.argv[1], sys.argv[2]
m = trimesh.load(src, process=False, force='mesh')
m.export(dst)
print(f"[rig] input normalizzato per UniRig: {len(m.vertices)} vert, {len(m.faces)} facce")
PY

cd "$UNIRIG"

echo "[rig] scheletro ..."
bash launch/inference/generate_skeleton.sh --input "$clean" --output "$skel"

echo "[rig] skin weights ..."
bash launch/inference/generate_skin.sh --input "$skel" --output "$skin"

echo "[rig] merge sulla geometria ..."
# source = file con lo skin, target = geometria pulita (stessa topologia della mesh texturizzata)
bash launch/inference/merge.sh --source "$skin" --target "$clean" --output "$OUT"

rm -rf "$work"
[ -f "$OUT" ] && echo "[rig] OK -> $OUT"
