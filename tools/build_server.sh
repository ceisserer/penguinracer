#!/usr/bin/env bash
#
# Assembles build/server/: everything a Linux host needs to run the dedicated
# server, and nothing else. Copy the directory over and start it there — no
# Godot install, no checkout, no import step on the host.
#
#     tools/build_server.sh               # export the server, copy build/web
#     tools/build_server.sh --build-web   # ... rebuilding the web export first
#     scp -r build/server host:penguinracer
#     ssh host penguinracer/start.sh      # races on 27015, web build on 8060
#
# What ends up in it:
#
#     penguinracer_server.x86_64   the `Server` export preset: a Linux release
#                                  binary with the project embedded, exported
#                                  as a dedicated server (textures stripped,
#                                  no courses, no music; the sounds stay because
#                                  the Audio autoload loads them) whose main
#                                  scene is scenes/server.tscn through the
#                                  `dedicated_server` feature tag
#     web/                         a copy of build/web — the game the server
#                                  hands to browsers
#     start.sh                     the command line, with the same PORT /
#                                  WEB_PORT / WEB_ROOT overrides as serve.sh
#
# build/server/ is rebuilt from scratch each time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PROJECT="$ROOT/game"
WEB="$ROOT/build/web"
OUT="$ROOT/build/server"
BIN="penguinracer_server.x86_64"

case "${1:-}" in
    --build-web) "$ROOT/tools/build_web_streamed.sh" ;;
    "") ;;
    *) echo "usage: $0 [--build-web]" >&2; exit 2 ;;
esac

if [[ ! -f "$WEB/index.html" ]]; then
    echo "no web build in $WEB — run tools/build_web_streamed.sh, or pass --build-web" >&2
    exit 1
fi

# The binary is Godot's Linux release export template with the project
# appended, so the template has to be installed — a distribution's own `godot`
# package does not ship one. Checked here because Godot's own complaint comes
# after a full filesystem scan and only in the editor's language.
VERSION="$("$GODOT" --version | grep -oE '^[0-9.]+\.[a-z]+[0-9]*')"   # 4.7.2.stable
TEMPLATES="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$VERSION"
if [[ ! -f "$TEMPLATES/linux_release.x86_64" ]]; then
    TAG="${VERSION%.*}-${VERSION##*.}"                                  # 4.7.2-stable
    cat >&2 <<EOF
no Linux export template for Godot $VERSION in
    $TEMPLATES
install it once (the download is the full template set, ~1.3 GB; only the
Linux release binary is kept):
    curl -L -o /tmp/tpl.tpz https://github.com/godotengine/godot/releases/download/$TAG/Godot_v${TAG}_export_templates.tpz
    mkdir -p "$TEMPLATES"
    unzip -j /tmp/tpl.tpz templates/linux_release.x86_64 templates/version.txt -d "$TEMPLATES"
    rm /tmp/tpl.tpz
or in the editor: Editor > Manage Export Templates > Download and Install
EOF
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> server binary (Server preset, dedicated server export)"
"$GODOT" --headless --path "$PROJECT" --export-release "Server" "$OUT/$BIN"

echo "==> web build"
cp -a "$WEB" "$OUT/web"

cat > "$OUT/start.sh" <<'EOF'
#!/usr/bin/env bash
# The PenguinRacer dedicated server. Races on one port, the web build on
# another, out of one process.
#
#     ./start.sh                  # races on 27015, web build on 8060
#     PORT=27100 ./start.sh       # ... on another race port
#     WEB_ROOT= ./start.sh        # ... races only, no HTTP at all
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-27015}"
WEB_PORT="${WEB_PORT:-8060}"
WEB_ROOT="${WEB_ROOT-$HERE/web}"

ARGS=(--headless -- --port="$PORT" --web-port="$WEB_PORT")
[[ -n "$WEB_ROOT" ]] && ARGS+=(--web-root="$WEB_ROOT")

exec "$HERE/penguinracer_server.x86_64" "${ARGS[@]}"
EOF
chmod +x "$OUT/start.sh" "$OUT/$BIN"

echo "==> done"
du -sh "$OUT/$BIN" "$OUT/web"
