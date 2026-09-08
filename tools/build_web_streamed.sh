#!/usr/bin/env bash
# Builds the streamed web export: a slim base (engine + shell + previews,
# ~57 MB) plus one .pck per game/courses/<dir> and one for assets/music/,
# fetched and mounted at runtime by PackStream only when actually needed.
# See risk S6 in godot-port-plan.md and game/scripts/config/pack_stream.gd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PROJECT="$ROOT/game"
OUT="$ROOT/build/web"

echo "==> regenerating per-course export presets"
python3 "$ROOT/tools/gen_course_export_presets.py"

echo "==> base build (engine + shell, courses/music excluded)"
"$GODOT" --headless --path "$PROJECT" --export-release "Web" "$OUT/index.html"

echo "==> per-course packs"
mkdir -p "$OUT/courses"
for dir in "$PROJECT"/courses/*/; do
    name="$(basename "$dir")"
    "$GODOT" --headless --path "$PROJECT" --export-pack "Course_${name}" "$OUT/courses/${name}.pck"
done

echo "==> music pack"
"$GODOT" --headless --path "$PROJECT" --export-pack "MusicPack" "$OUT/music.pck"

echo "==> done"
du -sh "$OUT/index.html" "$OUT"/*.wasm "$OUT"/*.pck 2>/dev/null || true
echo "courses: $(find "$OUT/courses" -name '*.pck' | wc -l) packs, $(du -ch "$OUT"/courses/*.pck 2>/dev/null | tail -1 | cut -f1) total"
