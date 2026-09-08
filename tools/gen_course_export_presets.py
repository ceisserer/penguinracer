#!/usr/bin/env python3
"""Regenerates the per-course + music export presets in game/export_presets.cfg.

One `.pck` per game/courses/<dir> plus one for assets/music/, built via
`godot --export-pack "<preset name>" <out.pck>` (tools/build_web_streamed.sh
drives this). export_presets.cfg is otherwise hand-maintained (`Web`,
`WebSpike`) — this script only owns the block between the marker comments
below, and rewrites it from the current game/courses/ listing. Re-runnable;
run it whenever a course is added, removed or renamed.

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
        + ["assets/env/*", "assets/objects/*", "assets/sounds/*", "assets/terrain/*"]
        + [f"courses/{d}/*" for d in dirs]
    )
    return PRESET_TEMPLATE.format(
        index=index, name="MusicPack", exclude_filter=exclude,
        export_path="../build/web/music.pck",
    )


def generate_block(start_index: int) -> str:
    dirs = course_dirs()
    parts = [course_preset(start_index + i, dirs, d) for i, d in enumerate(dirs)]
    parts.append(music_preset(start_index + len(dirs), dirs))
    return "\n".join(parts)


def main() -> None:
    text = PRESETS_PATH.read_text()
    if BEGIN not in text:
        # First run: append the marker pair after the hand-maintained
        # presets (Web=0, WebSpike=1) — WebOneCourse (preset.2), superseded
        # by the generated Course_bunny_hill, is expected to already be gone.
        text = text.rstrip("\n") + f"\n\n{BEGIN}\n{END}\n"

    before, rest = text.split(BEGIN, 1)
    _, after = rest.split(END, 1)

    # Presets are numbered sequentially; count how many hand-maintained
    # [preset.N] blocks precede the marker to know where generated ones start.
    start_index = len(re.findall(r"^\[preset\.\d+\]$", before, re.MULTILINE))
    block = generate_block(start_index)

    PRESETS_PATH.write_text(f"{before}{BEGIN}\n{block}\n{END}{after}")
    print(f"wrote {len(course_dirs())} course presets + MusicPack starting at preset.{start_index}")


if __name__ == "__main__":
    main()
