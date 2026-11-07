#!/usr/bin/env bash
# weston-gpu-to-mediamtx.sh
# GPU-accelerated Weston (no Xvfb) -> PipeWire stream -> GStreamer -> MediaMTX -> browser.
#
# Chain: Weston (--backend=pipewire, --renderer=gl on your GPU render node)
#        -> PipeWire video node -> gst pipewiresrc -> H.264 -> RTSP -> MediaMTX -> WebRTC
#
# Requirements:
#   - Weston >= 12 built with the PipeWire backend and GL renderer
#     (check:  ls /usr/lib/*/weston/ | grep -i pipewire ;  weston --help | grep -i backend)
#   - A GPU with a render node (/dev/dri/renderD128) and your user in the `render`/`video` groups
#   - pipewire, gstreamer1.0-pipewire, gstreamer1.0-plugins-{base,good,bad,ugly}, gstreamer1.0-rtsp, jq
#   - mediamtx in PATH
#   - Optional HW encoders: vaapih264enc / vah264enc (Intel/AMD) or nvh264enc (NVIDIA)
#
# Usage:
#   ./weston-gpu-to-mediamtx.sh glxgears            # X11 app via XWayland
#   ./weston-gpu-to-mediamtx.sh weston-simple-dmabuf-egl
#   ENCODER=nvh264enc ./weston-gpu-to-mediamtx.sh ./my_3d_app
#
# Watch: http://<server-ip>:8889/desktop

set -euo pipefail

WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-4000}"            # kbit/s
ENCODER="${ENCODER:-x264enc}"         # x264enc | vah264enc | vaapih264enc | nvh264enc
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"
WL_SOCKET="${WL_SOCKET:-wl-capture}"
STREAM_PATH="${STREAM_PATH:-desktop}"
RTSP_PORT="${RTSP_PORT:-8554}"
MEDIAMTX_BIN="${MEDIAMTX_BIN:-mediamtx}"
MEDIAMTX_CONF="${MEDIAMTX_CONF:-}"
NODE_MATCH="${NODE_MATCH:-weston|pipewire}"   # regex to find Weston's PipeWire node

PIDS=()
RUN="$(mktemp -d)"
log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  log "Cleaning up..."
  for ((i=${#PIDS[@]}-1; i>=0; i--)); do kill "${PIDS[i]}" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -f "$RUN/weston.log" ]] && cp "$RUN/weston.log" /tmp/weston-run.log
  rm -rf "$RUN"
  log "Logs kept in /tmp/weston-run.log and /tmp/weston-app.log"
}
trap 'echo "[!] Script failed at line $LINENO: $BASH_COMMAND" >&2' ERR
trap cleanup EXIT INT TERM

for bin in weston gst-launch-1.0 pw-dump jq "$MEDIAMTX_BIN"; do
  command -v "$bin" >/dev/null || die "Missing dependency: $bin"
done
[[ -r "$RENDER_NODE" && -w "$RENDER_NODE" ]] || die "No access to $RENDER_NODE (add your user to the 'render' group)"
gst-inspect-1.0 pipewiresrc >/dev/null 2>&1 || die "Missing gstreamer1.0-pipewire"
gst-inspect-1.0 "$ENCODER"  >/dev/null 2>&1 || die "Encoder element '$ENCODER' not available"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -d "$XDG_RUNTIME_DIR" ]] || { XDG_RUNTIME_DIR="$RUN/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }

# ---------- MediaMTX ----------
if pgrep -x mediamtx >/dev/null; then
  log "MediaMTX already running."
else
  log "Starting MediaMTX..."
  "$MEDIAMTX_BIN" ${MEDIAMTX_CONF:+"$MEDIAMTX_CONF"} >"$RUN/mediamtx.log" 2>&1 &
  PIDS+=($!); sleep 1
  kill -0 "${PIDS[-1]}" 2>/dev/null || { cat "$RUN/mediamtx.log"; die "MediaMTX failed"; }
fi

# ---------- PipeWire (start only if no daemon is running) ----------
if ! pw-cli info 0 >/dev/null 2>&1; then
  log "Starting PipeWire..."
  pipewire >"$RUN/pipewire.log" 2>&1 & PIDS+=($!)
  command -v wireplumber >/dev/null && { wireplumber >"$RUN/wireplumber.log" 2>&1 & PIDS+=($!); }
  sleep 2
fi

# ---------- Weston on the GPU, output exposed as a PipeWire stream ----------
# SHELL_MODE=kiosk   -> the app is fullscreen inside Weston (default)
# SHELL_MODE=desktop -> normal Weston desktop with a panel and a terminal launcher
SHELL_MODE="${SHELL_MODE:-kiosk}"
if [[ "$SHELL_MODE" == "kiosk" ]]; then
  cat >"$RUN/weston.ini" <<EOF
[core]
idle-time=0
xwayland=true
shell=kiosk-shell.so
EOF
else
  cat >"$RUN/weston.ini" <<EOF
[core]
idle-time=0
xwayland=true

[shell]
locking=false
panel-position=bottom

[launcher]
icon=/usr/share/weston/icon_terminal.png
path=weston-terminal
EOF
fi
log "Weston shell mode: $SHELL_MODE"

EXISTING_X="$(ls /tmp/.X11-unix/X* 2>/dev/null || true)"

log "Starting Weston (GL renderer, $RENDER_NODE)..."
# Select the GPU for EGL/GBM. Flags can differ slightly between Weston versions:
# check `weston --help` if this line fails.
weston --backend=pipewire --renderer=gl \
       --width="$WIDTH" --height="$HEIGHT" \
       --socket="$WL_SOCKET" --config="$RUN/weston.ini" \
       >"$RUN/weston.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 50); do [[ -S "$XDG_RUNTIME_DIR/$WL_SOCKET" ]] && break; sleep 0.2; done
[[ -S "$XDG_RUNTIME_DIR/$WL_SOCKET" ]] || { cat "$RUN/weston.log"; die "Weston did not start"; }
log "Weston is up."

# ---------- Launch the 3D app inside Weston ----------
if [[ $# -gt 0 ]]; then
  APP=("$@")
  # A .jar can't be executed directly: run it through java
  if [[ "${APP[0]}" == *.jar ]]; then
    APP=(java -Djava.awt.headless=false -jar "${APP[@]}")
  fi
  # Find the X11 display that Weston's Xwayland just created
  # (a new socket in /tmp/.X11-unix that did not exist before Weston started)
  XDISP=""
  for _ in $(seq 1 40); do
    CURRENT_X="$(ls /tmp/.X11-unix/X* 2>/dev/null || true)"
    NEW_SOCKET="$(comm -13 <(echo "$EXISTING_X" | sort) <(echo "$CURRENT_X" | sort) | head -n 1)"
    if [[ -n "$NEW_SOCKET" ]]; then
      XDISP=":$(basename "$NEW_SOCKET" | sed 's/^X//')"
      break
    fi
    sleep 0.3
  done
  [[ -n "$XDISP" ]] || die "Xwayland did not create a display (is xorg-xwayland installed and xwayland=true active?)"
  log "Weston's Xwayland display: $XDISP"

  log "Launching: ${APP[*]}  (log: /tmp/weston-app.log)"
  if [[ "${APP[0]}" == "java" ]]; then
    # Java: use ONLY Weston's X11 display, hide the host's Wayland/X
    env -u WAYLAND_DISPLAY DISPLAY="$XDISP" "${APP[@]}" >/tmp/weston-app.log 2>&1 &
  else
    # Other apps: Wayland-native on Weston's socket, plus X11 fallback on Weston's Xwayland
    env WAYLAND_DISPLAY="$WL_SOCKET" DISPLAY="$XDISP" "${APP[@]}" >/tmp/weston-app.log 2>&1 &
  fi
  PIDS+=($!)

  # ---------- Browser control: inject mouse/keyboard into Weston's Xwayland only ----------
  echo "$XDISP" >/tmp/weston-xdisplay
  INPUT_SERVER="$(dirname "$(readlink -f "$0")")/input-server.py"
  if [[ "${INPUT:-1}" == "1" && -f "$INPUT_SERVER" ]]; then
    if python3 -c 'import Xlib, aiohttp' 2>/dev/null; then
      log "Starting input server on port ${INPUT_PORT:-8090}..."
      python3 "$INPUT_SERVER" --display "$XDISP" --host "${INPUT_HOST:-0.0.0.0}" \
        --port "${INPUT_PORT:-8090}" ${INPUT_TOKEN:+--token "$INPUT_TOKEN"} \
        >/tmp/weston-input.log 2>&1 &
      PIDS+=($!)
    else
      log "Skipping browser control: install python-xlib and python-aiohttp"
    fi
  fi
fi

# ---------- Find Weston's PipeWire video node ----------
log "Looking for Weston's PipeWire node..."
NODE_ID=""
for _ in $(seq 1 30); do
  NODE_ID="$(pw-dump | jq -r --arg re "$NODE_MATCH" '
    [ .[] | select(.type=="PipeWire:Interface:Node")
          | select((.info.props["media.class"] // "") | test("Video/Source|Stream/Output/Video"))
          | select(((.info.props["node.name"] // "") + (.info.props["node.description"] // "")) | test($re; "i"))
    ] | first | .id // empty')"
  [[ -n "$NODE_ID" ]] && break
  sleep 0.5
done
[[ -n "$NODE_ID" ]] || { pw-dump | jq -r '.[]|select(.type=="PipeWire:Interface:Node")|.info.props["node.name"]'; \
                         die "PipeWire node not found. Set NODE_MATCH to one of the names above."; }
log "Using PipeWire node $NODE_ID"

# ---------- Encoder options ----------
case "$ENCODER" in
  x264enc)       ENC="x264enc tune=zerolatency speed-preset=ultrafast bitrate=$BITRATE key-int-max=$FPS bframes=0 byte-stream=true" ;;
  nvh264enc)     ENC="nvh264enc preset=low-latency-hq bitrate=$BITRATE gop-size=$FPS zerolatency=true" ;;
  vah264enc)     ENC="vah264enc bitrate=$BITRATE key-int-max=$FPS" ;;
  vaapih264enc)  ENC="vaapih264enc bitrate=$BITRATE keyframe-period=$FPS tune=low-power" ;;
  *)             ENC="$ENCODER" ;;
esac

RTSP_URL="rtsp://127.0.0.1:${RTSP_PORT}/${STREAM_PATH}"
HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)"
HOST_IP="${HOST_IP:-localhost}"
log "Publishing to $RTSP_URL"
log "Video only:        http://${HOST_IP}:8889/${STREAM_PATH}"
log "Interactive (use): http://${HOST_IP}:${INPUT_PORT:-8090}/${INPUT_TOKEN:+?token=$INPUT_TOKEN}"

pw-dump | jq -r --argjson id "$NODE_ID" '.[]|select(.id==$id)|"[*] Node name: \(.info.props["node.name"]) | class: \(.info.props["media.class"])"'

# DEBUG_SNAPSHOT=1 saves one captured frame to /tmp/frame.png so you can see what Weston outputs
if [[ "${DEBUG_SNAPSHOT:-0}" == "1" ]]; then
  log "Saving one frame to /tmp/frame.png (waiting up to 15s)..."
  sleep 3
  timeout 15 gst-launch-1.0 -q pipewiresrc path="$NODE_ID" num-buffers=1 keepalive-time=100 \
    ! videoconvert ! pngenc ! filesink location=/tmp/frame.png \
    && log "Frame saved: /tmp/frame.png" || log "No frame received from the PipeWire node (that is the problem)"
fi

# keepalive-time: re-send the last frame every N ms. Weston only produces frames when
# the screen changes, so a static app would otherwise give an empty/black stream.
KEEPALIVE_MS=$(( 1000 / FPS ))

# shellcheck disable=SC2086
gst-launch-1.0 -e \
  pipewiresrc path="$NODE_ID" do-timestamp=true keepalive-time="$KEEPALIVE_MS" \
  ! queue max-size-buffers=3 leaky=downstream \
  ! videoconvert ! videorate \
  ! "video/x-raw,framerate=${FPS}/1" \
  ! queue max-size-buffers=3 leaky=downstream \
  ! $ENC \
  ! "video/x-h264,profile=baseline" \
  ! h264parse config-interval=-1 \
  ! rtspclientsink location="$RTSP_URL" protocols=tcp latency=0