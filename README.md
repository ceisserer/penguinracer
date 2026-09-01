# PenguinRacer

A Godot 4.7 rebuild of [Extreme Tux Racer](http://extremetuxracer.sourceforge.net/) 0.8.4:
downhill penguin racing with the original's physics model and real snow deformation.

Targets **web (WebGL2 / Compatibility renderer)** and **desktop native** from one project.

- [`etracer.md`](./etracer.md) — analysis of the original C++ source. The reference for *what
  the original does*, especially §4.1 (physics constants) and §5 (legacy file formats).
- [`godot-port-plan.md`](./godot-port-plan.md) — the rebuild plan: architecture, new data model,
  phases and risks.
- [`PROGRESS.md`](./PROGRESS.md) — what is built, what was learned, what is next.

## Layout

```
game/                     Godot project
  scripts/physics/        RacePhysics + surface + snow — no node dependencies
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
  scripts/render/         terrain chunks, GPU snow field, spray
  scripts/camera/         chase camera
  scripts/race/           the race scene: wires simulation to presentation
  scripts/shell/          HUD and course menu
  scenes/                 race.tscn, course_menu.tscn
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         generated: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/              generated: terrain layers, object prefabs, environments, events,
                          courses.tres (the course-menu index)
  tests/                  headless physics suite + ODE benchmark
  spikes/s1_pingpong/     the ping-pong render-target spike (risk S1)
etr-0.8.4/                the original source and data, read-only
tools/                    importer driver and the browser test harness
```

## Prerequisites

Godot 4.7.2 on `PATH` as `godot`, plus its export templates if you want to build for the web.

```bash
curl -sLO https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip
unzip -q Godot_v4.7.2-stable_linux.x86_64.zip
sudo mv Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot
```

## Import the original content

```bash
./tools/import_all.sh                 # all 44 courses
./tools/import_all.sh --course=bunny_hill
./tools/import_all.sh --force         # overwrite courses edited in-editor
```

Four passes: register scripts, write assets, let Godot import the new PNGs, then build the
resource graph. The ETR tree is only ever read. A course that has been touched in the editor
carries a provenance flag and is skipped unless `--force` is given.

## Run

```bash
godot --path game                                    # play
godot --headless --path game --script res://tests/run_tests.gd   # physics suite + benchmark
godot --path game spikes/s1_pingpong/s1_spike.tscn   # snow render-target spike
```

Controls: arrows steer, up paddles, down brakes, space charges a jump, `R` restarts,
`Esc` opens the course menu.

The game opens on the course menu, drawn over the loaded course: all 44 courses with preview,
author and description, arrows and Enter to pick one. It comes back up a few seconds after the
finish line so the next course is one keypress away. Course/cup progression, medals and profiles
are still to come — the menu does free selection only.

Development flags, useful for headless verification:

```bash
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains
```

On a machine with no GPU, `tools/shot.sh` wraps the same flags in Xvfb and llvmpipe and pins the
simulation to `--fixed-fps 60`, so the frame count *is* the race time and two runs are comparable:

```bash
tools/shot.sh /tmp/shot.png 200 bunny_hill paddle    # out, frames, course, scripted input
```

To compare a capture against a reference screenshot rather than squinting at it — there is no
Pillow in the container, so these are a small pure-Python PNG reader and two readers on top of it:

```bash
python3 tools/regionstats.py shot.png 200 550 500 700       # per-channel median/percentiles/clipping
python3 tools/linstats.py shot.png 0.25 200 550 500 700     # pre-tonemap linear value, for a frame
                                                            # rendered with tonemap_exposure = 0.25
```

## Web

```bash
godot --headless --path game --export-release "Web" build/web/index.html
(cd tools/webtest && npm install)   # first time only
node tools/webtest/server.js build/web 8060 &
node tools/webtest/run_web_test.js http://127.0.0.1:8060/index.html /tmp/web.png RACE_READY
```

The server sets COOP/COEP and the right MIME types for `.wasm` and `.pck`; without them the
export fails with an unhelpful console error.

Three export presets are defined: `Web` (everything), `WebOneCourse` (bunny_hill only — a
6.6 MB pck, the shape per-course streaming needs) and `WebSpike` (the S1 render-target spike).

```bash
godot --headless --path game --export-release "WebSpike" build/spike/index.html
node tools/webtest/server.js build/spike 8061 &
node tools/webtest/run_web_test.js http://127.0.0.1:8061/index.html /tmp/spike.png S1_DONE
```

The spike verifies itself and exits non-zero on failure, so it can gate CI.
