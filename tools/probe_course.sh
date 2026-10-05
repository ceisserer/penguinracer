#!/usr/bin/env bash
# One racer down a real course, headless: speed by distance, every flight,
# every herring and tree hit, the time. See game/tests/probe_course.gd.
#   tools/probe_course.sh --course=snow_park --driver=hard   (easy|medium|hard|straight)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${GODOT:-godot}" --headless --path "$ROOT/game" --script res://tests/probe_course.gd -- "$@"
