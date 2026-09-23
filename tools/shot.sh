#!/usr/bin/env bash
# Deterministic screenshot from a scripted run, for look comparisons.
#
#     tools/shot.sh /tmp/out.png [frames] [course] [auto-input]
#
# The weather is two environment variables rather than two more positionals, so
# that every existing invocation still means the clear sunny day every reference
# capture was taken on: SHOT_LIGHT=sunny|cloudy|night and SHOT_SNOW=0..3.
#
# The game ships two renderers — Mobile on the desktop and Compatibility on the
# web, which is the only one a browser offers — and they do not light a frame
# the same way, so a capture has to say which one it is of. `SHOT_METHOD` picks:
# `mobile` (the desktop default, Vulkan), `gl_compatibility` (what the web
# build runs, and what a desktop `--compat` run reproduces), or `forward_plus`.
# Unset takes the project's own setting for this platform. Compatibility needs
# the GL driver and the other two need Vulkan, so the driver follows the method
# rather than being pinned; `SHOT_DRIVER` overrides that if you need a specific
# pairing.
#
# Prefers the real GPU. If the container has a Wayland socket and a DRI render
# node, the capture runs against it and 120 frames of Bunny Hill take about 5 s;
# the llvmpipe fallback below takes a little over two minutes for the same
# frame. Set SHOT_FORCE_SOFTWARE=1 to take the slow path deliberately — worth
# doing before trusting a small tone measurement, since the two rasterisers do
# not agree to the last level.
#
# `--resolution` is *logical*: a compositor running a fractional output scale
# multiplies it, and this container's Wayland session runs at 1.25, so the
# default comes out as a 1600x900 PNG. Region boxes in the tone-fitting notes
# (history Â§11, Â§22) are 1280x720 pixels, so either scale the box by the PNG's
# own size or ask for `SHOT_RESOLUTION=1024x576` and get exactly 1280x720 back.
# Check the size of what you got before trusting a documented rectangle.
#
# The *shape* is yours to choose too, and it changes what is in frame rather
# than just how big it is: `window/stretch/aspect="expand"` means a 4:3 request
# shows more hill above and below and a 21:9 one more to either side. Ask for
# 16:9 when comparing against an existing capture.
#
# Either way `--fixed-fps` makes the simulation advance by frame count rather
# than by how slowly it happens to draw, which is what makes two runs — and the
# two paths — comparable at all. `--no-audio` keeps the run silent, which a
# capture has no use for and which saves loading 18 MB of streams. It used to
# be load-bearing as well — a capture that played anything printed a "leaked at
# exit" warning over the screenshot — but that is fixed at the source now, in
# `AudioDirector.quit_game`, and a capture with sound exits just as cleanly.
set -euo pipefail
OUT="${1:?output png}"
FRAMES="${2:-250}"
COURSE="${3:-bunny_hill}"
INPUT="${4:-paddle}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GODOT="${GODOT:-godot}"
METHOD="${SHOT_METHOD:-}"
case "$METHOD" in
    gl_compatibility) DRIVER=opengl3 ;;
    mobile|forward_plus) DRIVER=vulkan ;;
    "") DRIVER="" ;;
    *) echo "SHOT_METHOD must be mobile, forward_plus or gl_compatibility" >&2; exit 2 ;;
esac
DRIVER="${SHOT_DRIVER:-$DRIVER}"

ARGS=(--path "$ROOT/game")
[[ -n "$METHOD" ]] && ARGS+=(--rendering-method "$METHOD")
[[ -n "$DRIVER" ]] && ARGS+=(--rendering-driver "$DRIVER")
ARGS+=(--resolution "${SHOT_RESOLUTION:-1280x720}" --fixed-fps 60 --
    --capture="$OUT" --capture-frames="$FRAMES"
    --auto-input="$INPUT" --course="$COURSE" --no-audio)
# The weather, which is not in the positional arguments because every reference
# capture in the repository is a clear sunny day and has to stay one.
# SHOT_LIGHT is sunny, cloudy or night; SHOT_SNOW is 0..3.
[[ -n "${SHOT_LIGHT:-}" ]] && ARGS+=(--light="$SHOT_LIGHT")
[[ -n "${SHOT_SNOW:-}" ]] && ARGS+=(--snow="$SHOT_SNOW")

WL_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
if [[ -z "${SHOT_FORCE_SOFTWARE:-}" && -S "$WL_SOCKET" && -e /dev/dri/renderD128 ]]; then
    # Needs libEGL and libdecor, which the base image does not carry:
    #     sudo apt-get install -y libegl1 libegl-mesa0 libdecor-0-0
    # Without them Godot reports "Can't load EGL dynamic library" and then
    # misdiagnoses it as the driver being too old for OpenGL 3.3.
    exec "$GODOT" --display-driver wayland "${ARGS[@]}"
fi

# The software fallback is llvmpipe, which is a GL rasteriser: there is no
# lavapipe in this image, so Vulkan — and with it Mobile and Forward+ — has no
# software path at all. Say so rather than falling back to a renderer the
# caller did not ask for.
if [[ "$DRIVER" == "vulkan" ]]; then
    echo "no software Vulkan here — SHOT_METHOD=$METHOD needs the real GPU" >&2
    exit 3
fi

exec xvfb-run -a -s "-screen 0 1280x800x24" \
    env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    "$GODOT" "${ARGS[@]}"
