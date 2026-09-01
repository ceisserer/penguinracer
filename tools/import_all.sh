#!/usr/bin/env bash
# Re-runnable migration from the ETR 0.8.4 data tree to the v2 course format.
#
# Two importer stages with a Godot --import between them: freshly written PNGs
# (splat maps, previews, terrain and object textures) have to be picked up by
# the editor's import pipeline before a resource can reference them as
# Texture2D. Everything under game/courses and game/resources is generated and
# committed; the ETR tree is never written to.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
SOURCE="${SOURCE:-$ROOT/etr-0.8.4/data}"
PROJECT="$ROOT/game"

EXTRA=()
for arg in "$@"; do EXTRA+=("$arg"); done

echo "==> stage 0/4: register scripts"
"$GODOT" --headless --path "$PROJECT" --import >/dev/null

echo "==> stage 1/4: assets"
"$GODOT" --headless --path "$PROJECT" --script res://addons/etr_import/run_import.gd -- \
    --source="$SOURCE" --stage=assets "${EXTRA[@]+"${EXTRA[@]}"}"

echo "==> stage 2/4: godot import"
"$GODOT" --headless --path "$PROJECT" --import >/dev/null

echo "==> stage 3/4: resources"
"$GODOT" --headless --path "$PROJECT" --script res://addons/etr_import/run_import.gd -- \
    --source="$SOURCE" --stage=resources "${EXTRA[@]+"${EXTRA[@]}"}"

echo "==> stage 4/4: godot import"
"$GODOT" --headless --path "$PROJECT" --import >/dev/null

echo "==> done"
