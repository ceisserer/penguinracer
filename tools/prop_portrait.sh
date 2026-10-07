#!/usr/bin/env bash
# A close look at one solid prop outside any course (game/tests/prop_portrait.gd).
#
#     tools/prop_portrait.sh /tmp/out.png <prefab> [--dist=14] [--orbit=0] [--textures=1]
#         [--eye=1.6] [--fov=60] [--size=x,y,z] [--snow=1]
#
# SHOT_METHOD and SHOT_RESOLUTION as in tools/shot.sh (Mobile and 1024x576 here
# by default, which this container's 1.25 compositor scale returns as 1280x720).
# Real GPU only: there is no software Vulkan, and a close-up is for looking at.
# A frame takes ~3 s; a run that hangs (on quit, after the PNG) is killed at 30.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="$(realpath -m "${1:?output png}")"
shift
METHOD="${SHOT_METHOD:-mobile}"
case "$METHOD" in
    gl_compatibility) DRIVER=opengl3 ;;
    mobile|forward_plus) DRIVER=vulkan ;;
    *) echo "SHOT_METHOD must be mobile, forward_plus or gl_compatibility" >&2; exit 2 ;;
esac
WL_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
if [[ ! -S "$WL_SOCKET" || ! -e /dev/dri/renderD128 ]]; then
    echo "prop_portrait.sh needs the real GPU (Wayland socket + /dev/dri/renderD128)" >&2
    exit 1
fi
exec timeout -s KILL 30 "$GODOT" --display-driver wayland --path "$ROOT/game" \
    --rendering-method "$METHOD" --rendering-driver "$DRIVER" \
    --resolution "${SHOT_RESOLUTION:-1024x576}" --fixed-fps 60 --audio-driver Dummy \
    --script res://tests/prop_portrait.gd -- "$OUT" "$@"
