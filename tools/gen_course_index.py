#!/usr/bin/env python3
"""Writes courses.json for a folder of course packs, so the folder's address can
be added in the game's course menu (Add course… → the folder's http(s) URL).

One entry per `<dir>.pck` in the folder. What the menu shows before the pack is
fetched — name, author, description, size, slope — comes from the course's row
in game/resources/courses.tres when there is one, and is otherwise just the
directory name. Build the packs with a `Course_<dir>` export preset (see
tools/gen_course_export_presets.py and tools/build_web_streamed.sh); the format
the game reads is documented on ExternalCourses.parse_index.

    python3 tools/gen_course_index.py build/web/courses
    python3 tools/gen_course_index.py /srv/courses --out /srv/courses/courses.json
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "game" / "resources" / "courses.tres"


def read_catalog(path: Path) -> dict:
    """Every [sub_resource] of courses.tres as a dict of its fields, by dir."""
    rows, row = {}, None
    field = re.compile(r'^(\w+) = (.*)$')
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("[sub_resource"):
            row = {}
            continue
        if line.startswith("["):
            row = None
            continue
        m = field.match(line)
        if row is None or not m:
            continue
        key, value = m.groups()
        if value.startswith('"'):
            row[key] = json.loads(value)
        elif value.startswith("Vector2("):
            row[key] = [float(v) for v in value[8:-1].split(",")]
        else:
            try:
                row[key] = float(value)
            except ValueError:
                pass
        if key == "dir":
            rows[row["dir"]] = row
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("folder", type=Path, help="folder holding the <dir>.pck files")
    ap.add_argument("--out", type=Path, help="default: <folder>/courses.json")
    args = ap.parse_args()

    catalog = read_catalog(CATALOG) if CATALOG.exists() else {}
    courses = []
    for pck in sorted(args.folder.glob("*.pck")):
        if not re.fullmatch(r"[A-Za-z0-9_-]+", pck.stem):
            print(f"skipped {pck.name}: the game only accepts plain names")
            continue
        row = catalog.get(pck.stem, {})
        entry = {"file": pck.name, "name": row.get("display_name", pck.stem)}
        for key, out in (("author", "author"), ("description", "description")):
            if row.get(key):
                entry[out] = row[key]
        if "world_size" in row:
            entry["width"], entry["length"] = row["world_size"]
        if "base_angle" in row:
            entry["angle"] = row["base_angle"]
        courses.append(entry)

    out = args.out or args.folder / "courses.json"
    out.write_text(json.dumps({"courses": courses}, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print(f"{out}: {len(courses)} courses")


if __name__ == "__main__":
    main()
