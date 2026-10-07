#!/usr/bin/env bash
# Fetch the photographed materials the props and buildings are drawn with, and
# pack them into game/assets/materials/ (tests/pack_prop_materials.gd).
#
#     tools/pack_prop_materials.sh
#
# Every source is CC0 (public domain): Poly Haven (https://polyhaven.com/license)
# and ambientCG (https://docs.ambientcg.com/license/). CREDITS.md lists them.
# Only the packed arrays are committed; the downloads land in build/, which is
# not. The order of SOURCES is the order of the layers, and has to match
# `object_prop.gdshader`'s PROP_LAYER_* and [enum PropMesh.Surface].
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
SRC="$ROOT/build/prop_materials_src"
mkdir -p "$SRC"

PH="https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k"
# layer   source                    colour / normal (OpenGL) / roughness
SOURCES=(
    "logs     polyhaven  wood_trunk_wall"
    "boards   polyhaven  weathered_brown_planks"
    "stone    polyhaven  old_stone_wall"
    "shingles ambientcg  WoodSiding011"
    "rock     polyhaven  dark_rock_02"
    "bark     polyhaven  pine_bark"
)

fetch() { [[ -s "$2" ]] || curl -sSfL -o "$2" "$1"; }

for row in "${SOURCES[@]}"; do
    read -r layer site id <<<"$row"
    dir="$SRC/$layer"
    mkdir -p "$dir"
    case "$site" in
        polyhaven)
            fetch "$PH/$id/${id}_diff_1k.jpg" "$dir/colour.jpg"
            fetch "$PH/$id/${id}_nor_gl_1k.jpg" "$dir/normal.jpg"
            fetch "$PH/$id/${id}_rough_1k.jpg" "$dir/rough.jpg"
            ;;
        ambientcg)
            zip="$dir/$id.zip"
            fetch "https://ambientcg.com/get?file=${id}_1K-JPG.zip" "$zip"
            python3 - "$zip" "$dir" "$id" <<'EOF'
import sys, zipfile
z, out, id = sys.argv[1:]
names = {"Color": "colour.jpg", "NormalGL": "normal.jpg", "Roughness": "rough.jpg"}
with zipfile.ZipFile(z) as f:
    for key, dest in names.items():
        # Not every material has every map (WoodSiding011 has no roughness);
        # the packer fills a missing one.
        if f"{id}_1K-JPG_{key}.jpg" not in f.namelist():
            continue
        with open(f"{out}/{dest}", "wb") as o:
            o.write(f.read(f"{id}_1K-JPG_{key}.jpg"))
EOF
            ;;
    esac
    echo "$layer: $site $id"
done

layers=()
for row in "${SOURCES[@]}"; do layers+=("$SRC/$(awk '{print $1}' <<<"$row")"); done
"$GODOT" --headless --path "$ROOT/game" --script res://tests/pack_prop_materials.gd -- "${layers[@]}"
"$GODOT" --headless --path "$ROOT/game" --import >/dev/null 2>&1 || true
ls -l "$ROOT"/game/assets/materials/
