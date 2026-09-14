#!/usr/bin/env bash
# img23d.sh — client Linux/Mac: manda un'IMMAGINE al server, genera il modello 3D,
# riporta giu' i risultati.
#
#   ./img23d.sh foto.png
#   ./img23d.sh foto.png --rig
#   ./img23d.sh foto.png --rig --octree 512 --texture 2048
#
# Al primo avvio, se manca img23d.config, te lo crea chiedendoti server e cartella.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/img23d.config"

command -v ssh >/dev/null || { echo "ssh non trovato"; exit 1; }
command -v scp >/dev/null || { echo "scp non trovato"; exit 1; }

# ---- config (primo avvio interattivo) ------------------------------------
SERVER=""; REMOTE_DIR="~/imageTo3D"
# parsing manuale (NON source): evita che la tilde ~ venga espansa sul PC locale
if [ -f "$CFG" ]; then
  while IFS='=' read -r k v; do
    k="${k// /}"
    case "$k" in
      SERVER)     SERVER="$(printf '%s' "$v" | sed 's/^ *//;s/ *$//')" ;;
      REMOTE_DIR) REMOTE_DIR="$(printf '%s' "$v" | sed 's/^ *//;s/ *$//')" ;;
    esac
  done < "$CFG"
fi
if [ -z "${SERVER:-}" ] || [ "$SERVER" = "utente@host.esempio.com" ]; then
  echo
  echo "  Primo avvio: configuriamo img23d."
  echo "  (potrai modificare i valori in img23d.config)"
  echo
  read -rp "  Server SSH (utente@host): " SERVER
  [ -n "$SERVER" ] || { echo "server obbligatorio"; exit 1; }
  read -rp "  Cartella sul server [~/imageTo3D]: " REM
  REMOTE_DIR="${REM:-~/imageTo3D}"
  printf 'SERVER=%s\nREMOTE_DIR=%s\n' "$SERVER" "$REMOTE_DIR" > "$CFG"
  echo
  echo "  Salvato in img23d.config"
fi
REMOTE_SH="${REMOTE_DIR/#\~\//\$HOME/}"
LOCAL_DIR="$HERE/output"

# ---- argomenti ------------------------------------------------------------
IMG=""; ENVSTR=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rig)        ENVSTR="$ENVSTR RIG=1" ;;
    --octree)     shift; ENVSTR="$ENVSTR OCTREE_RESOLUTION=$1" ;;
    --texture)    shift; ENVSTR="$ENVSTR TEXTURE_RESOLUTION=$1" ;;
    --shapesteps) shift; ENVSTR="$ENVSTR SHAPE_STEPS=$1" ;;
    --keep)       KEEP=1 ;;
    *)            IMG="$1" ;;
  esac
  shift
done
[ -n "$IMG" ] || { echo "uso: ./img23d.sh <immagine> [--rig] [--octree N] [--texture N] [--keep]"; exit 1; }
[ -f "$IMG" ] || { echo "immagine non trovata: $IMG"; exit 1; }

ext="${IMG##*.}"; ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
case "$ext" in png|jpg|jpeg|webp) ;; *) echo "formato non supportato: .$ext"; exit 1 ;; esac
base="$(basename "${IMG%.*}" | tr -cd 'A-Za-z0-9_-')"
[ -n "$base" ] || base="input"
remoteName="$base.$ext"
ENVSTR="$(echo "$ENVSTR" | sed 's/^ *//')"

echo
echo "  server   : $SERVER"
echo "  immagine : $(basename "$IMG") -> images/$remoteName"
[ -n "$ENVSTR" ] && echo "  extra    : $ENVSTR"
echo

# ---- 1. upload immagine ---------------------------------------------------
prep="cd \"$REMOTE_SH\" 2>/dev/null || { echo '[img23d] cartella remota non trovata: $REMOTE_SH' >&2; exit 2; }; mkdir -p images output"
[ "$KEEP" = "1" ] || prep="$prep; rm -f images/*.png images/*.jpg images/*.jpeg images/*.webp"
ssh "$SERVER" "$prep" || { echo "preparazione remota fallita. Controlla SERVER/REMOTE_DIR in img23d.config"; exit 1; }
scp "$IMG" "$SERVER:$REMOTE_DIR/images/$remoteName"

# ---- 2. genero ------------------------------------------------------------
run="cd \"$REMOTE_SH\"; ls -1 output 2>/dev/null | grep -E '^[0-9]{3}\$' | sort > /tmp/img23d_before.txt || true; $ENVSTR bash generate.sh >&2; ls -1 output 2>/dev/null | grep -E '^[0-9]{3}\$' | sort > /tmp/img23d_after.txt; comm -13 /tmp/img23d_before.txt /tmp/img23d_after.txt | sed 's/^/IMG23D_NEW=/'"
created="$(ssh "$SERVER" "$run")"

folders="$(echo "$created" | tr -d '\r' | sed -n 's/^IMG23D_NEW=\([0-9][0-9][0-9]\)$/\1/p')"
[ -n "$folders" ] || { echo "il server non ha prodotto nessuna cartella nuova. Guarda il log qui sopra."; exit 1; }

# ---- 3. scarico le cartelle nuove -----------------------------------------
mkdir -p "$LOCAL_DIR"
echo
echo "  scarico: $(echo "$folders" | tr '\n' ' ')"
for f in $folders; do
  scp -r "$SERVER:$REMOTE_DIR/output/$f" "$LOCAL_DIR" || echo "  (copia di $f incompleta)"
done
echo
for f in $folders; do
  echo "  $LOCAL_DIR/$f"
  ls -1 "$LOCAL_DIR/$f" 2>/dev/null | sed 's/^/    /'
done
echo
echo "  fatto."
