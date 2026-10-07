#!/usr/bin/env python3
"""Regenerates the per-course, music and materials export presets in game/export_presets.cfg.

One `.pck` per game/courses/<dir>, one for assets/music/ and one for
assets/materials/ (the props' photographs), built via
`godot --export-pack "<preset name>" <out.pck>` (tools/build_web_streamed.sh
drives this). export_presets.cfg is otherwise hand-maintained (`Web`,
`WebSpike`, `Server`, `Android`) — this script owns every preset named
`Course_*`, `MusicPack` or `MaterialsPack`, written as one block between the marker comments
below, and rewrites it from the current game/courses/ listing. Re-runnable;
run it whenever a course is added, removed or renamed, and after saving
export presets in the editor (which drops the markers).

    python3 tools/gen_course_export_presets.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game"
PRESETS_PATH = GAME / "export_presets.cfg"

BEGIN = "; BEGIN generated course + music presets — owned by tools/gen_course_export_presets.py"
END = "; END generated course + music presets"

# Everything a per-course (or the music) pck must exclude so it carries only
# its own payload — not the shared shell resources every build already has,
# and not any other course's data.
SHARED_EXCLUDES = [
    "legacy/*",
    "resources/*",
    "i18n/*",
    "scenes/*",
    "scripts/*",
    "shaders/*",
    "themes/*",
    "addons/*",
    "spikes/*",
    "tests/*",
]

PRESET_TEMPLATE = """[preset.{index}]

name="{name}"
platform="Web"
runnable=false
advanced_options=true
dedicated_server=false
custom_features=""
export_filter="exclude"
include_filter=""
exclude_filter="{exclude_filter}"
export_files=PackedStringArray()
export_path="{export_path}"
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.{index}.options]

custom_template/debug=""
custom_template/release=""
variant/extensions_support=false
variant/thread_support=false
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=true
html/export_icon=true
html/custom_html_shell=""
html/head_include=""
html/canvas_resize_policy=2
html/focus_canvas_on_start=true
html/experimental_virtual_keyboard=false
progressive_web_app/enabled=false
"""


def course_dirs() -> list[str]:
    courses = GAME / "courses"
    return sorted(p.name for p in courses.iterdir() if p.is_dir())


def course_preset(index: int, dirs: list[str], this_dir: str) -> str:
    others = [f"courses/{d}/*" for d in dirs if d != this_dir]
    exclude = ", ".join(SHARED_EXCLUDES + ["assets/*"] + others)
    return PRESET_TEMPLATE.format(
        index=index,
        name=f"Course_{this_dir}",
        exclude_filter=exclude,
        export_path=f"../build/web/courses/{this_dir}.pck",
    )


def music_preset(index: int, dirs: list[str]) -> str:
    exclude = ", ".join(
        SHARED_EXCLUDES
        + ["assets/env/*", "assets/materials/*", "assets/objects/*", "assets/sounds/*",
           "assets/terrain/*", "assets/trees/*"]
        + [f"courses/{d}/*" for d in dirs]
    )
    return PRESET_TEMPLATE.format(
        index=index, name="MusicPack", exclude_filter=exclude,
        export_path="../build/web/music.pck",
    )


def materials_preset(index: int, dirs: list[str]) -> str:
    """The props' photographs (CourseRoot.PROP_ALBEDO_PATH), fetched by the race
    for the first course with props and only when `[quality] prop_textures` is on."""
    exclude = ", ".join(
        SHARED_EXCLUDES
        + ["assets/env/*", "assets/music/*", "assets/objects/*", "assets/sounds/*",
           "assets/terrain/*", "assets/trees/*"]
        + [f"courses/{d}/*" for d in dirs]
    )
    return PRESET_TEMPLATE.format(
        index=index, name="MaterialsPack", exclude_filter=exclude,
        export_path="../build/web/materials.pck",
    )


def generate_block(start_index: int) -> str:
    dirs = course_dirs()
    parts = [course_preset(start_index + i, dirs, d) for i, d in enumerate(dirs)]
    parts.append(music_preset(start_index + len(dirs), dirs))
    parts.append(materials_preset(start_index + len(dirs) + 1, dirs))
    return "\n".join(parts)


PRESET_HEADER = re.compile(r"^\[preset\.(\d+)(\.options)?\]$", re.MULTILINE)


def is_generated(block: str) -> bool:
    name = re.search(r'^name="([^"]*)"$', block, re.MULTILINE)
    return name is not None and (name.group(1).startswith("Course_")
                                 or name.group(1) in ("MusicPack", "MaterialsPack"))


def split_presets(text: str) -> tuple[str, list[str]]:
    """The text before the first preset, and each preset (`[preset.N]` plus its
    `[preset.N.options]`) as one block, marker comments stripped."""
    text = text.replace(BEGIN + "\n", "").replace(END + "\n", "")
    text = text.replace(BEGIN, "").replace(END, "")
    starts = [m.start() for m in PRESET_HEADER.finditer(text) if m.group(2) is None]
    if not starts:
        return text, []
    head = text[:starts[0]]
    blocks = [text[a:b].strip("\n") + "\n" for a, b in zip(starts, starts[1:] + [len(text)])]
    return head, blocks


def renumber(block: str, index: int) -> str:
    return PRESET_HEADER.sub(lambda m: f"[preset.{index}{m.group(2) or ''}]", block)


def main() -> None:
    # The Godot editor rewrites this file on every save and drops comments —
    # the two markers included — so the generated block cannot be found by its
    # markers alone. Every preset this script owns is recognised by its name
    # instead, wherever it now sits, and removed before the block is written
    # again; otherwise each editor save followed by a run appends another copy
    # of all of them. Hand-maintained presets keep their order, renumbered from 0.
    head, blocks = split_presets(PRESETS_PATH.read_text())
    kept = [renumber(b, i) for i, b in enumerate(b for b in blocks if not is_generated(b))]
    block = generate_block(len(kept))
    body = "\n".join(kept)
    PRESETS_PATH.write_text(f"{head.rstrip()}\n\n{body}\n{BEGIN}\n{block}\n{END}\n")
    print(f"kept {len(kept)} hand-maintained presets; wrote {len(course_dirs())} "
          f"course presets + MusicPack + MaterialsPack starting at preset.{len(kept)}")


if __name__ == "__main__":
    main()
