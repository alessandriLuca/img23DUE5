#!/usr/bin/env bash
# Gira DENTRO il container core (Hunyuan3D-2.1). Non lanciarlo a mano: usa
# ./generate.sh
#
#   per ogni immagine in /data/input:
#     gpu-check -> cartella numerata -> mesh+texture (GLB) -> preview turntable
#
# Il rigging (UniRig) NON avviene qui: lo fa generate.sh in un secondo container,
# se RIG=1.
set -euo pipefail
cd /opt/hunyuan
S=/opt/scripts

# --- FIX bpy "undefined symbol: rtcIsSYCLDeviceSupported" -------------------
# Sia Hunyuan che UniRig fanno "import bpy". bpy porta la sua libembree4.so.4
# (col simbolo SYCL), ma un'altra libembree4 senza quel simbolo viene caricata
# prima e vince la risoluzione del SONAME. Precaricando quella di bpy, il simbolo
# c'e' sempre. Vale per texture (gen_3d.py) e rigging (rig.sh -> UniRig), che
# ereditano LD_PRELOAD da questa shell.
BPY_EMBREE="$(find /opt/conda/lib/python*/site-packages/bpy/lib -name 'libembree4.so.4' 2>/dev/null | head -1)"
if [ -n "$BPY_EMBREE" ]; then
  export LD_PRELOAD="${BPY_EMBREE}${LD_PRELOAD:+:$LD_PRELOAD}"
  echo "[entrypoint] LD_PRELOAD bpy embree: $BPY_EMBREE"
else
  echo "[entrypoint] ATTENZIONE: libembree4 di bpy non trovata (import bpy potrebbe fallire)" >&2
fi

# --- GPU utilizzabile? ---
python3 - <<'PY'
import sys, torch
if not torch.cuda.is_available():
    print("[gpu-check] ERRORE: torch non vede la GPU (manca --gpus all?).", file=sys.stderr); sys.exit(1)
cap = "sm_%d%d" % torch.cuda.get_device_capability(0)
archs = torch.cuda.get_arch_list()
print(f"[gpu-check] {torch.cuda.get_device_name(0)} -> {cap} | torch {torch.__version__}")
if cap not in archs:
    ptx = [a for a in archs if a.startswith("compute_")]
    print(f"[gpu-check] ATTENZIONE: {cap} non fra le arch compilate {archs}", file=sys.stderr)
    if not ptx:
        print("[gpu-check] nessun PTX di fallback: mi fermo.", file=sys.stderr); sys.exit(1)
PY

# immagini da elaborare
mapfile -t IMAGES < <(find /data/input -maxdepth 1 -type f \
  \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | sort)
[ "${#IMAGES[@]}" -gt 0 ] || { echo "[entrypoint] nessuna immagine in /data/input" >&2; exit 1; }
echo "[entrypoint] immagini da elaborare: ${#IMAGES[@]}"

for src in "${IMAGES[@]}"; do
  name="$(basename "${src%.*}")"
  # cartella numerata progressiva, non sovrascrive
  d="$(python3 "$S/organize_output.py" /data/output)"
  echo
  echo "[entrypoint] === $(basename "$src") -> $(basename "$d") ==="
  cp "$src" "$d/source$(printf '%s' "${src##*.}" | sed 's/^/./')"
  glb="$d/model.glb"

  if xvfb-run -a python3 "$S/gen_3d.py" "$src" "$glb"; then
    echo "[3d]    $(basename "$glb")  (mesh + texture PBR)"
  else
    rc=$?
    if [ -f "$glb" ]; then
      echo "[3d]    $(basename "$glb")  (SENZA texture, vedi log)" >&2
    else
      echo "[3d]    FALLITO su $(basename "$src") (rc=$rc)" >&2
      continue
    fi
  fi

  # export delle mappe texture in PNG separati (albedo/roughness/metallic/orm),
  # da collegare a mano in UE. Non tocca model.glb.
  if [ "${EXPORT_TEXTURES:-1}" != "0" ] && [ -f "$glb" ]; then
    python3 "$S/extract_textures.py" -- "$glb" "$d" 2>&1 | grep -E "^\[tex\]" || true
  fi

  # post-processing (retopo / alleggerimento / export multi-formato)
  # non tocca model.glb: aggiunge file accanto. Salta se tutto e' spento.
  if { [ "${POST_DECIMATE_FACES:-0}" != "0" ] || [ "${POST_QUAD_REMESH:-0}" = "1" ] \
       || [ "${EXPORT_FORMATS:-glb}" != "glb" ]; } && [ -f "$glb" ]; then
    xvfb-run -a blender --background --python "$S/postprocess.py" -- "$glb" "$d" 2>&1 \
      | grep -E "^\[post\]" || true
  fi

  # rigging automatico (UniRig), stessa immagine, solo se RIG=1
  if [ "${RIG:-0}" = "1" ] && [ -f "$glb" ]; then
    rigged="$d/model_rigged.fbx"
    if bash "$S/rig.sh" "$glb" "$rigged" 2>&1; then
      echo "[rig]   $(basename "$rigged")"
      # rifinitura per Unreal: nomi ossa UE Mannequin + piedi a Z=0 + scala cm.
      # L'FBX finale prende il NOME DELL'IMMAGINE (es. yo.png -> yo.fbx), cosi' in
      # UE lo Skeletal Mesh e lo Skeleton si chiamano "yo" / "yo_Skeleton".
      if [ "${RIG_UE_NAMES:-1}" != "0" ]; then
        ue="$d/${name}.fbx"
        flip=""; [ "${RIG_FLIP_LR:-0}" = "1" ] && flip="--flip-lr"
        if python3 "$S/rig_finalize.py" -- "$rigged" "$ue" $flip 2>&1 | grep -E "^\[finalize\]"; then
          echo "[rig]   $(basename "$ue")  (pronto per UE)"
        else
          echo "[rig]   rifinitura UE fallita (resta model_rigged.fbx grezzo)" >&2
        fi
      fi
    else
      echo "[rig]   rigging fallito per $(basename "$glb") (il GLB texturizzato resta valido)" >&2
    fi
  fi

  # preview turntable
  if [ "${PREVIEW:-1}" = "1" ] && [ -f "$glb" ]; then
    prev="$d/preview.${PREVIEW_FORMAT:-mp4}"
    xvfb-run -a blender --background --python "$S/render_turntable.py" -- \
      "$glb" "$prev" --frames "${PREVIEW_FRAMES:-48}" >/dev/null 2>&1 \
      && echo "[prev]  $(basename "$prev")" \
      || echo "[prev]  render turntable fallito per $(basename "$glb")" >&2
  fi
done

echo
echo "[entrypoint] fatto."
