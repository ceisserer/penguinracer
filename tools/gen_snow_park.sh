#!/usr/bin/env bash
# Generates the authored course Snow Park into game/courses/snow_park/, its
# furniture prefabs (snowman, igloo, chairlift) into game/resources/objects/,
# and its row in the course catalog. Deterministic and re-runnable; see
# game/addons/course_gen/gen_snow_park.gd. Two stages with a Godot --import
# between them, as tools/import_all.sh: the splat PNGs have to be imported
# before course.tres can hold them as textures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PROJECT="$ROOT/game"
GEN=res://addons/course_gen/gen_snow_park.gd

echo "==> register scripts"
"$GODOT" --headless --path "$PROJECT" --import >/dev/null
echo "==> assets"
"$GODOT" --headless --path "$PROJECT" --script "$GEN" -- --stage=assets
echo "==> godot import"
"$GODOT" --headless --path "$PROJECT" --import >/dev/null
echo "==> resources"
"$GODOT" --headless --path "$PROJECT" --script "$GEN" -- --stage=resources
echo "==> godot import"
"$GODOT" --headless --path "$PROJECT" --import >/dev/null
echo "==> done"
