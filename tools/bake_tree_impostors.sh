#!/usr/bin/env bash
# Bake the tree impostor atlases (game/assets/trees/) from LOD 0 of ConiferMesh
# and BareTreeMesh.
#
#     tools/bake_tree_impostors.sh [conifer|bare]     # both when omitted
#
# Re-run for a species whenever its mesh changes shape, and commit its two PNGs. Needs a
# real renderer, so it takes the same route to the GPU as tools/shot.sh (Wayland
# socket + DRI render node), else llvmpipe under xvfb. The bake is one frame
# per atlas, so the software path is quick too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
ARGS=(--path "$ROOT/game" --rendering-method gl_compatibility --rendering-driver opengl3
    --script res://tests/bake_tree_impostors.gd -- "${1:-all}")

WL_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
if [[ -S "$WL_SOCKET" && -e /dev/dri/renderD128 ]]; then
    "$GODOT" --display-driver wayland "${ARGS[@]}"
else
    xvfb-run -a -s "-screen 0 1280x800x24" \
        env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$GODOT" "${ARGS[@]}"
fi
# Pick up the new PNGs (and write their .import sidecars on the first bake).
"$GODOT" --headless --path "$ROOT/game" --import >/dev/null 2>&1 || true
