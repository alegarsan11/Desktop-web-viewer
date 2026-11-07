#!/usr/bin/env bash
# probar.sh - lanzador rápido de pruebas sobre el script principal.
#
# Uso:
#   ./probar.sh josm         # editor de mapas 2D (descarga josm-tested.jar si falta)
#   ./probar.sh worldwind    # globo 3D de la NASA (demo run-demo.bash)
#   ./probar.sh gears        # glxgears (prueba mínima de GPU)
#
# Variables opcionales:
#   MAIN=./unido.sh          script principal (por defecto: unido.sh o weston-gpu-to-mediamtx.sh)
#   WW_DIR=~/WorldWindJava-2.2.1   carpeta de WorldWind ya extraída
#   Cualquiera de las del script principal: FPS=60 ENCODER=nvh264enc ...

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Script principal ---
MAIN="${MAIN:-}"
if [[ -z "$MAIN" ]]; then
  for c in "$HERE/unido.sh" "$HERE/weston-gpu-to-mediamtx.sh"; do
    [[ -f "$c" ]] && { MAIN="$c"; break; }
  done
fi
[[ -f "$MAIN" ]] || die "No encuentro el script principal (unido.sh). Usa MAIN=/ruta/al/script"
log "Script principal: $MAIN"

# Depuración activada por defecto en las pruebas
export INPUT_DEBUG="${INPUT_DEBUG:-1}"

case "${1:-}" in
  josm)
    JAR="$HERE/josm-tested.jar"
    if [[ ! -f "$JAR" ]]; then
      log "Descargando JOSM..."
      if command -v curl >/dev/null; then
        curl -L --fail -o "$JAR" https://josm.openstreetmap.de/josm-tested.jar
      elif command -v wget >/dev/null; then
        wget -O "$JAR" https://josm.openstreetmap.de/josm-tested.jar
      else
        die "Necesito curl o wget para descargar JOSM"
      fi
    fi
    log "Lanzando JOSM (en JOSM: menú Imagery → OpenStreetMap Carto)"
    exec bash "$MAIN" "$JAR"
    ;;

  worldwind)
    WW_DIR="${WW_DIR:-}"
    if [[ -z "$WW_DIR" ]]; then
      for d in "$HOME"/WorldWindJava* "$HERE"/WorldWindJava*; do
        [[ -f "$d/run-demo.bash" ]] && { WW_DIR="$d"; break; }
      done
    fi
    [[ -n "$WW_DIR" && -f "$WW_DIR/run-demo.bash" ]] || \
      die "No encuentro WorldWind. Descarga y extrae la release desde https://github.com/NASAWorldWind/WorldWindJava/releases/latest y usa WW_DIR=/ruta"
    log "WorldWind en: $WW_DIR"
    # run-demo.bash usa rutas relativas: hay que ejecutarlo desde su carpeta
    cd "$WW_DIR"
    X11_ONLY=1 exec bash "$MAIN" sh run-demo.bash
    ;;

  gears)
    command -v glxgears >/dev/null || die "Falta glxgears (paquete mesa-utils / mesa-demos)"
    exec bash "$MAIN" glxgears
    ;;

  *)
    echo "Uso: $0 {josm|worldwind|gears}"
    exit 1
    ;;
esac