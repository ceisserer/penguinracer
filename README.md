# PenguinRacer

A Godot 4.7 rebuild of [Extreme Tux Racer](http://extremetuxracer.sourceforge.net/) 0.8.4:
downhill penguin racing with the original's physics model and real snow deformation.

Targets **web (WebGL2 / Compatibility renderer)** and **desktop native** from one project.

- [`etracer.md`](./etracer.md) — analysis of the original C++ source. The reference for *what
  the original does*, especially §4.1 (physics constants) and §5 (legacy file formats).
- [`godot-port-plan.md`](./godot-port-plan.md) — the rebuild plan: architecture, new data model,
  phases and risks.
- [`materials.md`](./materials.md) — how a terrain material works end to end: one
  `TerrainLayer` per `terrains.lst` record, friction pre-blended for the physics and
  per-layer tables uploaded to the splat shader, why the file has seven kinds of ice, and
  what Godot's editor can author.
- [`PROGRESS.md`](./PROGRESS.md) — what is built and what is knowingly missing.
- [`history.md`](./history.md) — how it got here: the de-risking spikes and the discoveries that
  changed the plan.

## Layout

```
game/                     Godot project
  scripts/physics/        RacePhysics + surface + snow — no node dependencies
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
  scripts/render/         terrain chunks, GPU snow field, spray
  scripts/camera/         chase camera
  scripts/character/      the character rig, the migrated keyframe root motion, and
                          the catalog of the five playable characters
  scripts/race/           the race scene and the racers on the hill: the player, up to
                          nine computer opponents, an optional ghost of a saved run,
                          and one per network peer
  scripts/net/            the ENet session and the snapshots it carries
  scripts/shell/          HUD, main menu, course menu, settings screen
  scripts/audio/          the AudioDirector autoload and the sound/music banks
  scripts/config/         GameConfig: the settings file, read once at startup
  scenes/                 main_menu.tscn (the main scene), course_menu.tscn,
                          character_menu.tscn, settings_menu.tscn, ghost_menu.tscn,
                          race.tscn, results_menu.tscn
  themes/                 etr_menu.tres — ETR's GUI palette as a Godot theme,
                          plus the two checkbox icons it needs
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         generated: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/              generated: terrain layers, object prefabs, environments, events,
                          courses.tres and characters.tres (the two menu indexes),
                          characters/<name>/ (rig, animations, preview), the sound
                          bank and music library
  assets/                 generated: textures, skyboxes and the migrated audio
  tests/                  headless suite (physics, surface, input, audio, terrain
                          library, course objects, settings, character rig,
                          chase camera, recording and playback, computer opponents)
                          + ODE benchmark
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
godot --path game                                    # play — opens on the main menu
godot --path game -- --course=wild_mountains         # ... straight into a course, no menu
godot --path game -- --character=trixi               # ... as someone other than Tux
godot --headless --path game --script res://tests/run_tests.gd   # test suite + benchmark
godot --path game spikes/s1_pingpong/s1_spike.tscn   # snow render-target spike
godot --path game res://scenes/key_log.tscn          # keyboard delivery probe
godot --path game -- --no-audio                      # play with the sound off
godot --path game -- --no-intro                      # ... and without the start animation
godot --path game -- --host --course=bunny_hill      # host a session for others to join
godot --path game -- --join=<address> --course=bunny_hill    # ... join one
```

Every race opens with the original's start sequence: your character is standing off to one side of
the line,
waddles across to it, turns to face down the hill and drops onto his belly. Four and a half
seconds, and **any key skips it**. `R` mid-race goes straight back to racing without replaying it,
and a scripted run — anything passing `--auto-input=`, `--no-intro`, or `?nointro=1` in a browser
— never sees it at all, which is what keeps screenshot comparisons comparable.

Controls: arrow keys steer/paddle/brake, space charges a jump, `Ctrl` plus a direction turns an
air into a trick, `R` restarts, `P` freezes the race in place with a `PAUSED` banner and unfreezes
it again, `Esc` drops straight back to the course list — a race left this way is abandoned rather
than resumed, and Back from the list returns to the main menu. A gamepad's left stick steers.

Playing over a remote desktop, set its keyboard to a raw/map mode rather than a character
translating one — a translating mode sends held keys as zero-length pulses, and steering, paddling
and jump all stop working while `R` and `Esc` carry on. `res://scenes/key_log.tscn` says which one
you are on. Where the remote cannot be changed, `godot --path game -- --remote-keyboard` bridges
the pulses; it is off by default because it costs a tenth of a second on every release. The game
notices a pulsed link on its own and prints one line naming the flag — but only once a run of
pulses has arrived faster than a hand can tap, since a single sub-frame keystroke looks exactly
the same and a quick flick of the steering is not a diagnosis.

Sound and music are the original's, and so is the way they are mixed: the herring chime is three
overlapping cues because ETR gives each sound a single voice, riding a terrain loops whatever
`terrains.lst` names for it, and the racing track comes from the course's theme. Two of the
original's quirks came along deliberately — the slide sound has no speed term (ETR wrote one and
left it commented out) and 12 of its 43 terrains, `snow` included, name no sound at all.

The game opens on a main menu with four entries. Three are ETR's own words for what they do:
**Practice** is a single free race and opens the course list — all 44 courses with preview, author
and description, arrows and Enter to pick one — **Select a character** is the five of them from
`char/characters.lst`, arrows over a framed name with the original's 128x128 preview under it, and
**Configuration** is the settings screen below. The fourth, **Race the computer**, is beyond the
original and is the section after next. Picking a course draws a loading panel and then hands over to the race; `Esc` there brings
the course list back over the live slope, so the next course is one keypress away, and it comes up
by itself a few seconds after the finish line with the time and herring count. Cups, medals and
profiles are still to come — selection is free, and the events are imported and waiting.

A run that names a course or a scripted input (`--course=`, `--auto-input=`, and so every
`tools/shot.sh`) skips the menu and lands on the slope, which is also true of `?course=<dir>` on
the web build's URL.

## Racing the computer

ETR races the clock. **Race the computer** puts one to nine opponents on the hill with you, and
opens the same course screen Practice does with two spinners on it: how many, and how well they
drive — easy, medium or hard. Both are remembered, and both can be changed from the in-race menu,
so being beaten and trying again at a different setting takes two keypresses.

An opponent is not a special kind of racer. It runs the same physics you do, on the same tick, over
the same terrain, and it collects the same herring — first one there takes it. It is also solid:
ride into one and you both get shoved, at the cost of the speed you were closing at. A ghost is the
one racer on the hill you cannot touch, because it is a recording of a run that has already
happened and cannot be shoved back. The only thing a
difficulty setting moves is how well it drives: how far ahead it looks, how quickly it reacts, how
much room it insists on round a tree, how long it keeps paddling and how readily it brakes. Nothing
in the force model is scaled for it, because every character in the original has identical physics
and so does every character here. A hard opponent will beat a good line; an easy one brakes into
corners it did not need to brake into and stops paddling at half the speed paddling still helps at.

They start abreast, three metres apart, either side of the course's own start point — you begin
exactly where a practice run begins. They wear the other characters and are called by them, so the
HUD's second line reads `3 / 10   ↑ Trixi 8 m   ↓ Boris 14 m`: your place in the field, and who is
either side of you. After the line the result panel leads with `Position 3rd`.

A race never draws a ghost, whichever one was loaded — the HUD has one status line and in a race
that line is the standings. Your time is still recorded either way, so it can still be saved
afterwards.

From the command line, without the menu:

```bash
godot --path game -- --course=bunny_hill --opponents=5 --difficulty=hard
```

## Racing yourself, and racing other people

Every run you make is recorded — a couple of bytes per simulated frame, plus a pose twenty times a
second, about 150 kB for a long course — but nothing is written to disk until you ask. Finish a
race and a results screen comes up over the course with your time, your herring, and a field to
name the run; press Save and it is kept, in `user://runs/`, under whatever name you gave it — as
many runs as you like, on as many courses as you like, nothing overwritten.

**Race against ghost** on the main menu lists every run you have saved, across every course, with
its time and herring, and a Delete button for the ones you no longer want. Pick one and it starts
Practice on the course it was recorded on, with that run drawn as a translucent penguin taking the
line it took — amber when you are behind it, green when you are ahead. Whatever you were racing, crossing the line
stands your penguin up out of the racing pose and turns it round to face you. Beat the ghost and it
dances there (`wonrace`); lose to it and it hangs its head (`lostrace`) — the same
split a field race decides by place instead, since this rebuild has no cups to decide it by. A
scripted run (`--auto-input=`) neither loads a ghost nor keeps one, which is what stops a
screenshot comparison growing a second penguin.

Two people on two machines can race the same course together:

```bash
godot --path game -- --host --course=bunny_hill              # one machine
godot --path game -- --join=192.168.1.20 --course=bunny_hill # the other
```

Each machine simulates only its own penguin and tells the others where it is twenty times a
second; nobody's physics is second-guessed. **Desktop only** — the transport is ENet, which is
UDP, and a browser cannot open a UDP socket. There is no lobby yet either, so both ends name the
course themselves and start when they start; `[multiplayer] player_name` in the settings file is
what the other players see you called.

## Settings

Written the first time the game runs, with its comments, read once at startup, and moved either by
hand or from **Configuration** on the main menu — which writes the same file back, comments and
all. Fog is read when a course loads, so a change to it shows on the next race; the window
settings apply as soon as you press Ok. The file lives at:

```
Linux     ~/.local/share/godot/app_userdata/PenguinRacer/penguinracer.cfg
Windows   %APPDATA%\Godot\app_userdata\PenguinRacer\penguinracer.cfg
Web       IndexedDB, per origin
```

```ini
[display]
resolution = "1280x720"   ; or "auto"; ignored on the web, where the page sizes the canvas
fullscreen = false
render_scale = 1.00       ; fraction of the window the 3D scene renders at [0.25...2.0]

[fog]
start_distance = 40.0     ; metres of clear air before fog starts to build
distance_scale = 2.00     ; multiplies the range migrated from the environment's light.lst

[game]
character = "tux"         ; tux, trixi, boris, samuel or beastie
opponents = 3             ; how many computer racers "Race the computer" starts with [1...9]
opponent_skill = "medium" ; easy, medium or hard

[multiplayer]
player_name = "Racer"     ; what other racers see you called
port = 27015              ; the port --host listens on and --join= assumes
```

Delete the file to get the defaults and the comments back. Godot's own `--resolution` and
`--fullscreen` outrank it, so `tools/shot.sh` captures at 1280x720 whatever it says.

The **Configuration** screen's resolution list is the display's, not a fixed one: the screen's own
resolution, the standard modes that share its shape and fit beside the taskbar, and whatever the
file already says. A size of a shape the panel does not have would only letterbox itself, so it is
not offered. In a browser the resolution and fullscreen rows are not shown at all — the page sizes
the canvas there and the `resolution` key is ignored.

The two fog keys are the only place a shipped default deliberately differs from the original's
data. ETR's sunny and night environments say `[fogstart] 0 [fogend] 75`, so its white haze starts
at the camera; the defaults here hold it off to 40 m and stretch the range to 150. That haze is
load-bearing for the way the original's snow reads — `start_distance = 0` with
`distance_scale = 1` renders exactly what `light.lst` says, and is one edit away.

The character is the one ETR does not keep: its registration screen asks once per launch and
`players.lst` has no column for the answer. There are no player profiles here yet, so the question
has its own menu entry and the answer sticks — `--character=<dir>` (or `?character=` in a browser)
overrides it for one run without touching the file.

Sound and music volumes are still ETR's defaults on the audio director and are in neither the file
nor the settings screen yet. The two multiplayer keys are in the file but not on the screen: a name
you cannot see anyone use and a port with no session to open are settings for a lobby that does not
exist. The two opponent keys are in the file and on the *course* screen rather than the settings
one, because that is where the choice is actually made — beside the course you are about to race.

Development flags, useful for headless verification:

```bash
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains
```

`tools/shot.sh` wraps the same flags and pins the simulation to `--fixed-fps 60`, so the frame
count *is* the race time and two runs are comparable:

```bash
tools/shot.sh /tmp/shot.png 200 bunny_hill paddle    # out, frames, course, scripted input
```

It renders on the real GPU when the machine has a Wayland socket and a DRI render node — that
needs `libegl1 libegl-mesa0 libdecor-0-0`, without which Godot misreports the missing EGL library
as an unsupported OpenGL version — and falls back to Xvfb + llvmpipe otherwise. 120 frames of
Bunny Hill take about 3 s on the GPU and a little over two minutes in software.
`SHOT_FORCE_SOFTWARE=1` forces the slow path; the two rasterisers do not agree to the last level,
so it is worth using before trusting a small tone measurement.

To compare a capture against a reference screenshot rather than squinting at it — there is no
Pillow in the container, so these are a small pure-Python PNG reader and two readers on top of it:

```bash
python3 tools/regionstats.py shot.png 200 550 500 700       # per-channel median/percentiles/clipping
python3 tools/linstats.py shot.png 0.25 200 550 500 700     # pre-tonemap linear value, for a frame
                                                            # rendered with tonemap_exposure = 0.25
```

## Web

The web export is streamed: `Web` builds a slim base (engine + shell + all 44 course preview
thumbnails, ~65 MB) that excludes every course's `course.tscn`/`course.tres`/`heightmap.res`/
`splat_*.png` and all of `assets/music/`. Those are built as separate `.pck` files — one per
course (268 KB–9.2 MB each, depending on the course) plus one for music (14 MB) — and fetched
over HTTP at runtime by `PackStream` (`game/scripts/config/pack_stream.gd`) only when a course
is actually chosen or a track first plays. A native build is unaffected: `PackStream.ensure()`
is a single `ResourceLoader.exists()` check that is already true, since a native export still
bundles everything in one pck.

```bash
./tools/build_web_streamed.sh
(cd tools/webtest && npm install)   # first time only
node tools/webtest/server.js build/web 8060 &
node tools/webtest/run_web_test.js \
    "http://127.0.0.1:8060/index.html?course=bunny_hill" /tmp/web.png RACE_READY
```

The server sets COOP/COEP and the right MIME types for `.wasm` and `.pck`; without them the
export fails with an unhelpful console error.

`?course=<dir>` is how a browser says what `--course=` says on a command line, since there is no
command line in a page: it starts that course instead of the main menu, which is what lets the
harness wait on `RACE_READY`. `?autostart` does the same for the default course, `?nointro=1`
skips the start animation, and `?character=<dir>` races as one of the other four.

Export presets: `Web` (the streamed base), one generated `Course_<dir>` per course plus
`MusicPack` (owned by `tools/gen_course_export_presets.py` — re-run it whenever a course is
added, removed or renamed; `tools/build_web_streamed.sh` does this automatically), and
`WebSpike` (the S1 render-target spike).

```bash
godot --headless --path game --export-release "WebSpike" build/spike/index.html
node tools/webtest/server.js build/spike 8061 &
node tools/webtest/run_web_test.js http://127.0.0.1:8061/index.html /tmp/spike.png S1_DONE
```

The spike verifies itself and exits non-zero on failure, so it can gate CI.
