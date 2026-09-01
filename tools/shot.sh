#!/usr/bin/env bash
# Deterministic screenshot from a software-rendered run, for look comparisons.
#
#     tools/shot.sh /tmp/out.png [frames] [course] [auto-input]
#
# There is no GPU in this container, so the render goes through llvmpipe under
# Xvfb; --fixed-fps makes the simulation advance by frame count rather than by
# how slowly that happens to draw, which is what makes two runs comparable.
set -euo pipefail
OUT="${1:?output png}"
FRAMES="${2:-250}"
COURSE="${3:-bunny_hill}"
INPUT="${4:-paddle}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec xvfb-run -a -s "-screen 0 1280x800x24" \
    env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    "${GODOT:-godot}" --path "$ROOT/game" --rendering-driver opengl3 \
    --resolution 1280x720 --fixed-fps 60 -- \
    --capture="$OUT" --capture-frames="$FRAMES" \
    --auto-input="$INPUT" --course="$COURSE"
