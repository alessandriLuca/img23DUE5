#!/usr/bin/env bash
# Funzioni comuni a setup.sh e generate.sh. Non si lancia da solo.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { echo; echo "=========================================================="; \
         echo "[$(date +%H:%M:%S)] $*"; echo "=========================================================="; }
info() { echo "[$(date +%H:%M:%S)]   $*"; }
warn() { echo "[$(date +%H:%M:%S)] ~~ $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] !! $*" >&2; exit 1; }

# Carica config.env, poi lascia vincere le variabili gia' presenti nell'ambiente
# (cosi' `RIG=1 ./generate.sh` sovrascrive il file senza modificarlo).
load_config() {
  local cfg="$ROOT_DIR/config.env"
  [ -f "$cfg" ] || die "config.env non trovato in $ROOT_DIR"

  local preset=()
  while IFS= read -r name; do
    [ -n "${!name+x}" ] && preset+=("$name=${!name}")
  done < <(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' "$cfg")

  # shellcheck disable=SC1090
  set -a; source "$cfg"; set +a

  local kv
  for kv in "${preset[@]}"; do export "${kv?}"; done
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker non trovato."
}

# L'immagine core contiene gli script che ci aspettiamo?
image_is_current() {
  docker run --rm --entrypoint test "$1" -f /opt/scripts/gen_3d.py 2>/dev/null
}
