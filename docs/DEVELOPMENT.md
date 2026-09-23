# PenguinRacer — developer guide

Commands, prerequisites, project layout and the verification harness. For what the project *is*
and why it is built the way it is, see the [README](../README.md).

A Godot 4.7 rebuild of [Extreme Tux Racer](http://extremetuxracer.sourceforge.net/) 0.8.4:
downhill penguin racing with the original's physics model and real snow deformation.

Targets **web (WebGL2 / Compatibility renderer)** and **desktop native (Vulkan / Mobile
renderer)** from one project.

- [`etracer.md`](../etracer.md) — analysis of the original C++ source. The reference for *what
  the original does*, especially §4.1 (physics constants) and §5 (legacy file formats).
- [`godot-port-plan.md`](../godot-port-plan.md) — the rebuild plan: architecture, new data model,
  phases and risks.
- [`materials.md`](../materials.md) — how a terrain material works end to end: one
  `TerrainLayer` per `terrains.lst` record, friction pre-blended for the physics and
  per-layer tables uploaded to the splat shader, why the file has seven kinds of ice, and
  what Godot's editor can author.
- [`PROGRESS.md`](../PROGRESS.md) — what is built and what is knowingly missing.
- [`history.md`](../history.md) — how it got here: the de-risking spikes and the discoveries that
  changed the plan.

## Layout

```
game/                     Godot project
  scripts/physics/        RacePhysics + surface + snow — no node dependencies
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
  scripts/render/         terrain chunks, GPU snow field, spray, ice reflection
  scripts/camera/         chase camera
  scripts/character/      the character rig, the migrated keyframe root motion, and
                          the catalog of the five playable characters
  scripts/race/           the race scene and the racers on the hill: the player, up to
                          nine computer opponents, an optional ghost of a saved run,
                          and one per network peer
  scripts/net/            the WebSocket session and the snapshots it carries, the
                          lobby protocol, and the dedicated server behind both
  scripts/shell/          HUD, main menu, course menu, lobby, settings screen
  scripts/audio/          the AudioDirector autoload and the sound/music banks
  scripts/config/         GameConfig: the settings file, read once at startup
  scenes/                 main_menu.tscn (the main scene), course_menu.tscn,
                          character_menu.tscn, settings_menu.tscn, ghost_menu.tscn,
                          lobby_menu.tscn, race.tscn, results_menu.tscn, and
                          server.tscn — the dedicated server, headless
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
                          chase camera, recording and playback, computer opponents,
                          the lobby server) + ODE benchmark
  spikes/s1_pingpong/     the ping-pong render-target spike (risk S1)
  spikes/s7_reflection/   the planar reflection spike (S7)
etr-0.8.4/                the original source and data, read-only
tools/                    importer driver, serve.sh (the dedicated server),
                          build_server.sh (the same server packaged for a host),
                          and the browser test harness
```

## Prerequisites

Godot 4.7.2 on `PATH` as `godot`, plus its export templates if you want to build for the web.
The desktop build runs the **Mobile** renderer and so needs Vulkan; the web build runs
**Compatibility**, which is what WebGL2 gives you and the only reason the project carries two.
The split is not cosmetic — under Compatibility a shadow-casting light is drawn in a second pass
blended in sRGB, so the desktop gets shadows and the browser does not. See
`game/scripts/config/render_backend.gd`.

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
godot --path game spikes/s7_reflection/s7_spike.tscn # planar reflection spike
godot --path game res://scenes/key_log.tscn          # keyboard delivery probe
godot --path game -- --no-audio                      # play with the sound off
godot --path game -- --no-intro                      # ... and without the start animation
godot --path game -- --fps                           # ... showing the HUD's frame-rate readout
godot --path game -- --wind=2                        # ... with wind, and so the HUD's wind rose
godot --path game -- --snow=3                        # ... snowing hard (0..3)
godot --path game -- --light=night                   # ... after dark (sunny, cloudy or night)
godot --path game -- --server=<address>              # ... straight to the multiplayer lobby
godot --path game -- --lobby                         # ... on the server the settings file names
```

Every race opens with the original's start sequence: your character is standing off to one side of
the line,
waddles across to it, turns to face down the hill and drops onto his belly. Four and a half
seconds, and **any key skips it**. `R` mid-race goes straight back to racing without replaying it,
and a scripted run — anything passing `--auto-input=`, `--no-intro`, or `?nointro=1` in a browser
— never sees it at all, which is what keeps screenshot comparisons comparable.

The HUD is the original's: the stopwatch and the time top left, the herring count top right, and
bottom right the round gauge that carries two numbers at once — the jump charge as a blue fill
rising up the disc while space is held, and the speed as an arc around it that runs green to
60 km/h, yellow to 100 and red to 160, with the number itself in the middle. A bar up the right
edge fills as you descend. It is drawn rather than migrated: ETR's HUD textures are not in this
tree pending the licence audit, so the layout is `hud.cpp`'s own constants and the shapes are
built from them.

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

## Racing yourself

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

## Racing other people

**Network multiplayer** on the main menu. Up to eight players on one hill, on any machine the game
runs on — a desktop build and a browser tab are the same kind of client here.

### Running a server

There has to be one, and it is this same project run headless:

```bash
tools/serve.sh                      # races on 27015, the web build on 8060
PORT=27100 tools/serve.sh           # ... on another race port
WEB_ROOT= tools/serve.sh            # ... races only, no HTTP at all

# or, spelled out — note that a relative --web-root resolves against `game/`,
# because Godot gives a script no way to ask for the shell's directory
godot --headless --path game res://scenes/server.tscn -- \
    --port=27015 --web-root=../build/web --web-port=8060
```

To run it on another machine, `tools/build_server.sh` assembles `build/server/`: a Linux
dedicated-server export of the project (the `Server` preset: no courses, no textures, no music,
main scene `scenes/server.tscn` through the `dedicated_server` feature tag), a copy of
`build/web`, and a `start.sh` that takes the same `PORT` / `WEB_PORT` / `WEB_ROOT` overrides.
The host needs no Godot and no checkout:

```bash
tools/build_server.sh [--build-web]         # --build-web runs build_web_streamed.sh first
scp -r build/server host:penguinracer
ssh host penguinracer/start.sh
```

It opens two listeners in one process. The **race port** carries the sessions, over WebSocket,
which is the one transport a native build and a browser can both open — ENet is UDP and a page has
no UDP socket. The **web port** hands out the exported WebAssembly build itself, with the
COOP/COEP headers a threaded export needs and the right MIME types for `.wasm` and `.pck`; point
it at whatever `tools/build_web_streamed.sh` wrote. Leave `--web-root` off and it serves races
alone, which is what you want when a real static host or a CDN is serving the build.

The point of the two being one process is that a link is enough: open `http://<server>:8060/` and
the lobby's server field is already filled in with the host that served the page. On the desktop
it defaults to `127.0.0.1`, which is what a second terminal wants.

A page served over **HTTPS** may not open a `ws://` socket, so a public deployment wants a reverse
proxy terminating TLS in front of both, and the address field then takes `wss://your.host/…`. The
server itself does no TLS, no compression, no keep-alive and no rate limiting; it is a server you
run for people you know.

### Playing

**Network multiplayer** connects, then lists every race that has not started yet — name, course,
how many are in it, who created it, and whether it is locked. From there:

- **Join** one. If it is locked, type the password first. The password never leaves your machine:
  what goes on the wire is a SHA-256 digest of it salted with the race's name, so a password reused
  from somewhere else is not sent anywhere.
- **Create a race**. This opens the same course screen Practice uses: choose the course, the
  snowfall and the sky, name the race, and set a password or leave it empty for an open race.
  Everybody in the room races the same course under the same weather — it travels with the room,
  and only the admin can change it. You are that
  race's admin: you are the only one who can change the course (*Change course*, the same screen
  again) and the only one who can press Start. Close the window and the race is handed to whoever
  has been in it longest rather than collapsing.

Press Start and everyone loads the course. Nobody races until the last machine has it built — a
big course pack over a slow link is twenty seconds on one end and half a second on another — and
then a three-second countdown starts the whole field together. There is no start animation in a
network race, which is what the countdown is instead of.

Each machine simulates only its own penguin and tells the others where it is twenty times a
second; nobody's physics is second-guessed and the server does not simulate anything at all. You
can still bump into people: the contact is resolved by both bodies independently, so it feels
very slightly different at each end, which is the honest price of having no referee.

**The race is not over when you cross the line — it is over when the last player does.** Your
penguin coasts to a stop, the clock stops, and the camera follows whoever is still coming down the
hill while the HUD counts how many are left. When the last one is in, everybody gets the same
results screen with the finishing order on it, and Continue puts you back in the room you started
from, ready to go again.

Esc leaves a network race and forfeits it — the others stop waiting for you. `P` and `r` do
nothing there: freezing or restarting your own simulation while seven other people keep racing is
not a pause and not a restart.

`[multiplayer] player_name` and `server` in the settings file are what the lobby screen writes
back, so the name and the server you last used are there next time.

```bash
godot --path game -- --server=penguin.example      # straight to the lobby, on that server
godot --path game -- --lobby                       # ... on the one the settings file names
```

...and `?server=` / `?lobby` in the browser, which is how a link to a server is a link.

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
ice_reflections = true    ; whether ice reflects the racers standing on it
shadows = true            ; racers and trees cast a shadow. Desktop only — the browser's
                          ; renderer cannot draw one without blowing the frame out — and
                          ; off under a cloudy or a night sky either way

[fog]
start_distance = 40.0     ; metres of clear air before fog starts to build
distance_scale = 2.00     ; multiplies the range migrated from the environment's light.lst

[game]
character = "tux"         ; tux, trixi, boris, samuel or beastie
opponents = 3             ; how many computer racers "Race the computer" starts with [1...9]
opponent_skill = "medium" ; easy, medium or hard
snowfall = 0              ; how hard it is snowing [0...3]: none, a little, more, a lot
conditions = "sunny"      ; what the sky is doing: sunny, cloudy or night

[multiplayer]
player_name = "Racer"     ; what other racers see you called
server = ""               ; the lobby server: a host, a host:port, or a ws:// URL.
                          ; empty means "work it out" — the host that served the
                          ; page in a browser, 127.0.0.1 on the desktop
port = 27015              ; the port the server listens on, and the one an
                          ; address with no port of its own is assumed to use
```

The first two are written back by the **Network multiplayer** screen, so the name and the server
you last connected to are already filled in next time.

Delete the file to get the defaults and the comments back. Godot's own `--resolution` and
`--fullscreen` outrank it, so `tools/shot.sh` captures at the size it asks for whatever the file
says — though `--resolution` is *logical*, and a compositor running a fractional output scale
multiplies it, so check the size of the PNG before trusting a pixel rectangle in it.

**The window can be any shape.** `project.godot` stretches the 1280x720 design canvas with
`aspect="expand"`, which keeps its 720-pixel short side and grows along the long one: a 21:9
window draws on 1680x720 and shows more of the hill to either side, a 4:3 window draws on 1280x960
and shows more of it above and below, and nothing is ever letterboxed. The HUD anchors each of its
pieces to the edge it belongs to, and the camera widens its own lens on anything narrower than
16:9 so no window shape sees less of the course than another.

The **Configuration** screen's resolution list is the display's, not a fixed one: the screen's own
resolution, the standard modes that share its shape and fit beside the taskbar, and whatever the
file already says. The shape filter is about the monitor rather than the game — nothing renders
wrong at any shape now — and it is there because a panel's own aspect ratio is the only evidence
Godot offers about which modes it really has. In a browser the resolution and fullscreen rows are
not shown at all — the page sizes the canvas there and the `resolution` key is ignored.

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
The two weather keys are there for the same reason, and they are the original's own arrangement:
`CRaceSelect` puts light, snow and wind under its course list. Two of the three are offered here —
`snowfall` and `conditions` — and the wind is still `--wind=` only, because wind belongs to a cup
race in `events.lst` and there are no cups yet.

**The sky is chosen per race, not per course.** A course names a *place* (`[env] etr` or
`[env] tuxracer`, a location with skyboxes and a `light.lst` authored under it for each time of
day) and the light is the player's, the way `events.lst` picks it for a cup race in the original.
Three of the four times of day are offered: sunny, cloudy and night. Under the last two nothing
casts a shadow — that is `CCharShape::DrawShadow` returning immediately under `light_id` 1 and 3,
not a simplification — and the snow, the falling flakes, the spray, the fog and what the ice
reflects all change with the sky.

Development flags, useful for headless verification:

```bash
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains
```

`--auto-input=` is `carve`, `brake`, `paddle` or `jump`; the last charges and fires on a fixed
cycle, which is the only way to capture the HUD gauge's inner half.

`tools/shot.sh` wraps the same flags and pins the simulation to `--fixed-fps 60`, so the frame
count *is* the race time and two runs are comparable:

```bash
tools/shot.sh /tmp/shot.png 200 bunny_hill paddle    # out, frames, course, scripted input
SHOT_METHOD=gl_compatibility tools/shot.sh /tmp/web.png 200 bunny_hill paddle
                                                     # ... as the browser will render it
SHOT_RESOLUTION=1024x576 tools/shot.sh /tmp/shot.png  # ... at a true 1280x720 under a 1.25 scale
SHOT_LIGHT=night SHOT_SNOW=2 tools/shot.sh /tmp/night.png
                                                     # ... after dark, in moderate snow
```

`SHOT_METHOD` is `mobile`, `gl_compatibility` or `forward_plus` and the driver follows it; unset
takes the project's own setting for the platform. The same thing without a capture is
`godot --path game --rendering-method gl_compatibility --rendering-driver opengl3`, which is how
the web look is checked without opening a browser.

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
export fails with an unhelpful console error. It also sets `Content-Length`, which Node does not
do on its own for these responses — without it the loading screen's progress bar has no total to
divide by and falls back to counting megabytes, so the harness would be testing a path a real
static host never takes.

To watch the loading screen rather than the race, throttle the link *after* the engine has
booted — otherwise the 28 MB base bundle eats the whole budget before a course is ever
requested. Puppeteer does it through CDP (`Network.emulateNetworkConditions`) on the console line
that marks boot; 2 Mbit/s makes a 9 MB course take about forty seconds, which is the case the bar
exists for.

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
