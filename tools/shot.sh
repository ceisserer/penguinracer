#!/usr/bin/env bash
# Deterministic screenshot from a scripted run, for look comparisons.
#
#     tools/shot.sh /tmp/out.png [frames] [course] [auto-input]
#
# Prefers the real GPU. If the container has a Wayland socket and a DRI render
# node, the capture runs against it and 120 frames of Bunny Hill take about 5 s;
# the llvmpipe fallback below takes a little over two minutes for the same
# frame. Set SHOT_FORCE_SOFTWARE=1 to take the slow path deliberately — worth
# doing before trusting a small tone measurement, since the two rasterisers do
# not agree to the last level.
#
# Either way `--fixed-fps` makes the simulation advance by frame count rather
# than by how slowly it happens to draw, which is what makes two runs — and the
# two paths — comparable at all.
set -euo pipefail
OUT="${1:?output png}"
FRAMES="${2:-250}"
COURSE="${3:-bunny_hill}"
INPUT="${4:-paddle}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GODOT="${GODOT:-godot}"
ARGS=(--path "$ROOT/game" --rendering-driver opengl3
    --resolution 1280x720 --fixed-fps 60 --
    --capture="$OUT" --capture-frames="$FRAMES"
    --auto-input="$INPUT" --course="$COURSE")

WL_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
if [[ -z "${SHOT_FORCE_SOFTWARE:-}" && -S "$WL_SOCKET" && -e /dev/dri/renderD128 ]]; then
    # Needs libEGL and libdecor, which the base image does not carry:
    #     sudo apt-get install -y libegl1 libegl-mesa0 libdecor-0-0
    # Without them Godot reports "Can't load EGL dynamic library" and then
    # misdiagnoses it as the driver being too old for OpenGL 3.3.
    exec "$GODOT" --display-driver wayland "${ARGS[@]}"
fi

exec xvfb-run -a -s "-screen 0 1280x800x24" \
    env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    "$GODOT" "${ARGS[@]}"
