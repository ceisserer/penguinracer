#!/usr/bin/env bash
#
# The PenguinRacer dedicated server: races on one port, the exported web build
# on another, out of one process.
#
#     tools/serve.sh                      # races on 27015, web build on 8060
#     PORT=27100 tools/serve.sh           # ... on another race port
#     WEB_ROOT= tools/serve.sh            # ... races only, no HTTP at all
#
# The web root defaults to `build/web`, which is what `tools/build_web_streamed.sh`
# writes. Nothing there yet is not an error — the server says so and carries on
# serving races, which is the right behaviour for a host that is only ever
# reached by native clients.
#
# Open http://<this machine>:8060/ in a browser and the lobby's server field is
# already filled in with the host that served the page, because the two halves
# are the same machine. That is the whole reason they are the same process.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PORT="${PORT:-27015}"
WEB_PORT="${WEB_PORT:-8060}"
WEB_ROOT="${WEB_ROOT-$ROOT/build/web}"

ARGS=(--headless --path "$ROOT/game" res://scenes/server.tscn --
      --port="$PORT" --web-port="$WEB_PORT")
[[ -n "$WEB_ROOT" ]] && ARGS+=(--web-root="$WEB_ROOT")

exec "$GODOT" "${ARGS[@]}"
