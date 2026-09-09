## Runtime audio — ETR's `CSound` and `CMusic` (`src/audio.cpp`) on Godot's
## audio server. Autoloaded as `Audio`.
##
## The mixing model is the original's and is worth stating, because it is
## unusual by modern standards:
##
## [b]One player per cue, not a voice pool.[/b] `TSound` owns a single
## `sf::Sound` and `Play` early-returns while it is still playing, so a sound
## can never overlap itself. The three herring pickups are three separate cues
## fired together for exactly that reason — one cue could not have layered.
##
## [b]Volumes are percentages, clamped at 100.[/b] `MIX_MAX_VOLUME` is 100 and
## `CalcSoundVol` clips there, so `snow_sound`'s 1.5 gain is really 1.11 at the
## default effects volume of 90. SFML's volume is a linear amplitude
## percentage, which is what [method @GlobalScope.linear_to_db] converts.
##
## [b]Halt only stops looping sounds.[/b] `CSound::Halt` checks `getLoop()`
## first, so a one-shot cannot be cut off. The terrain slide is the only looped
## cue, and that check is what keeps a stray halt from silencing a pickup.
##
## Godot side: two buses under Master so a future options screen has somewhere
## to attach, created here rather than in a `default_bus_layout.tres` — a
## generated layout file nothing else owns is one more thing to drift, and this
## way the reason for each bus is next to the code that makes it.
class_name AudioDirector
extends Node

const BUS_MUSIC := &"Music"
const BUS_SFX := &"SFX"

## `MIX_MAX_VOLUME` in `audio.cpp`.
const MAX_VOLUME := 100.0
## Stand-in for silence: `linear_to_db(0)` is -inf, which a player mixes badly.
const SILENCE_DB := -80.0

## Longest [method quit_game] will wait for the mixer to let go before bringing
## the tree down anyway. A ceiling, not a duration — the wait ends as soon as
## the playbacks are actually released, which is a few frames. See
## [method await_settled] for why the wait is not a fixed interval.
const QUIT_SETTLE_TIMEOUT := 1.0

## `param.sound_volume`, default from `game_config.cpp`.
var sound_volume: int = 90:
	set(value):
		sound_volume = clampi(value, 0, int(MAX_VOLUME))
		_apply_sound_volumes()

## `param.music_volume`. Deliberately much lower than the effects — the
## original ships 20 against 90 and the tracks are mastered for it.
var music_volume: int = 20:
	set(value):
		music_volume = clampi(value, 0, int(MAX_VOLUME))
		_apply_music_volume()

## `-- --no-audio` for capture runs, where a soundtrack is only a slow start.
var enabled: bool = true

var bank: SoundBank
var library: MusicLibrary

var _players: Dictionary = {}
## Which cues were started looping — see the note on `Halt` above.
var _looping: Dictionary = {}
var _music: AudioStreamPlayer
## The path last asked for, not the loaded [AudioStream] — see
## [member MusicTrack.stream_path]. Compared against on the next
## [method _play_stream] so asking for the piece already playing is not a
## restart.
var _current_track_path: String = ""
## Set by [method begin_shutdown], and never cleared: the mixer is on its way
## out. See that method for what it gates.
var _quitting: bool = false
## Weak handles on the playbacks [method begin_shutdown] stopped, which
## [method await_settled] waits to go null. Weak on purpose: a strong reference
## here would be the very thing that keeps them alive.
var _settling: Array[WeakRef] = []

func _ready() -> void:
	setup()
	# `CSound::FreeSounds` and `CMusic::FreeMusics`: leave nothing sounding
	# when the tree comes down. `tree_exiting` rather than `_exit_tree`,
	# because EXIT_TREE reaches the children first and stopping a player that
	# is already out of the tree releases nothing.
	#
	# By itself this is too late to release anything — see [method quit_game],
	# which is the path every quit in the game actually takes. This stays as
	# the backstop for a tree that comes down some other way.
	tree_exiting.connect(silence)
	# Take the window's close button over, so `quit_game` gets its wait. On web
	# the tab owns the lifetime and there is nothing to intercept.
	if not OS.has_feature("web"):
		get_tree().auto_accept_quit = false

## The window's close button, Alt+F4, and the OS asking politely. Godot
## propagates this to every node under the root window — autoloads included —
## just before it would have quit for us, which is the hook `auto_accept_quit
## = false` in [method _ready] leaves open.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()

## Stop everything that is sounding, and refuse to start anything else.
##
## The half of the shutdown that has nothing to do with the tree, split out of
## [method quit_game] so it can be tested without quitting the process. Safe to
## call more than once, and one-way: nothing puts the mixer back.
##
## [b]Why refusing matters.[/b] The settle window [method quit_game] waits out
## is [i]live[/i] — the tree is still processing, so whatever was playing a cue
## on a timer is still asking for it, and [method silence] having just stopped
## the player is precisely what makes `player.playing` false and the next call
## go through. The race asks every tick:
## `RaceScene._update_slide_sound` plays the cue named by the terrain under the
## player. The looping slide restarted inside the window, was sounding when the
## tree came down, and cost every quit from a race
## "2 ObjectDB instances were leaked at exit" plus "1 resources still in use" —
## `rock_slide.wav` and its playback, exactly the looping cue
## [method quit_game] predicted would join the music if it were ever left
## sounding. Gating here rather than in the race covers the pickups, the tree
## hit and the music too, and keeps what a shutdown means in the one file that
## owns the mixer.
func begin_shutdown() -> void:
	_quitting = true
	# Before the silence, not after: `stop()` is what makes `playing` false and
	# drops the player's own handle on its playback.
	_settling.clear()
	_watch(_music)
	for id: StringName in _players:
		_watch(_players[id] as AudioStreamPlayer)
	silence()

## Take a weak handle on what `player` is sounding, if anything.
func _watch(player: AudioStreamPlayer) -> void:
	if player == null or not player.playing:
		return
	var playback: AudioStreamPlayback = player.get_stream_playback()
	if playback != null:
		_settling.push_back(weakref(playback))

## How many of the playbacks [method begin_shutdown] stopped are still alive.
##
## The exact quantity the exit warning counts, which is what lets
## [method await_settled] wait for the real thing instead of for a duration
## that stands in for it.
func settling() -> int:
	var alive: int = 0
	for handle: WeakRef in _settling:
		if handle.get_ref() != null:
			alive += 1
	return alive

## Stop everything that is sounding. Safe to call more than once.
func silence() -> void:
	halt_all()
	if _music != null:
		_music.stop()
		_music.stream = null
	_current_track_path = ""

## How the game leaves: silence the mixer, let it settle, then quit.
##
## [b]Why the wait.[/b] `AudioServer` does not release a playback where it is
## stopped. `stop()` only marks it for deletion; the mixer has to run once more
## to fade it out, and the object is freed after that by the
## `AudioServer::update()` at the end of a main-loop iteration. Neither happens
## if the tree is already coming down, so stopping from `tree_exiting` — or in
## the same breath as `SceneTree.quit()` — frees nothing, and Godot reports the
## stream, its playback and the Ogg packet sequence behind them on the way out:
## [codeblock lang=text]
## WARNING: 4 ObjectDB instances were leaked at exit
## ERROR: 2 resources still in use at exit
## [/codeblock]
## The music is the one thing still playing when a player quits from a menu;
## the looping slide cue joined it on every quit from a race, for a second
## reason — see [method begin_shutdown], which is why the silence sticks.
##
## [b]How long.[/b] Exactly as long as it takes, and no longer — see
## [method await_settled], which watches the playbacks themselves rather than
## waiting out an interval chosen to be comfortably more than enough.
func quit_game(code: int = 0) -> void:
	if _quitting:
		return
	begin_shutdown()
	await await_settled()
	get_tree().quit(code)

## Wait until the mixer has released what [method begin_shutdown] stopped, or
## until [constant QUIT_SETTLE_TIMEOUT] runs out.
##
## [b]Why this is not a fixed wait.[/b] It was one — 100 ms, on the reasoning
## that what has to elapse is a mixer buffer, which is wall-clock time and
## nothing to do with the frame rate. The reasoning is right and the
## implementation could not carry it: [method SceneTree.create_timer] counts
## down by the frame delta, so the interval it delivers is however many whole
## frames happen to fit, measured with the [i]previous[/i] frame's length. On
## the way out of the menu that is not a rounding error. Instrumented over the
## real path, a 100 ms timer returned after 43 ms and four frames — the frame
## that asks to quit is the one that just wrote a PNG or tore down a course, so
## the delta driving the countdown is nothing like the frames that follow it —
## and the music playback was released at 60 ms, on the fifth. Every quit from
## the main menu leaked `start1-jt.ogg`, its packet sequence and their two
## playback objects: the "4 ObjectDB instances / 2 resources" in
## [method quit_game]'s own docs, still there, because the fix was a duration
## that the timer never actually spent.
##
## So wait for the thing instead of for a number. [member _settling] holds a
## weak handle on each playback, [method settling] counts the ones still alive,
## and this yields until that is zero. It is also faster: quitting from a
## silent screen returns on the first check rather than sleeping through a
## tenth of a second that was sized for the worst case.
##
## The timeout is the backstop, not the mechanism. If a driver somehow never
## retires a playback, the game still leaves — one second later, with the
## warning printed and the leak reported by the engine as it always was.
func await_settled() -> void:
	var deadline: int = Time.get_ticks_usec() + int(QUIT_SETTLE_TIMEOUT * 1e6)
	while settling() > 0:
		if Time.get_ticks_usec() >= deadline:
			push_warning("audio: %d playbacks still held after %.1fs; quitting anyway"
				% [settling(), QUIT_SETTLE_TIMEOUT])
			return
		await get_tree().process_frame

## Load the banks and build the voices. Split out of [method _ready] and made
## idempotent because the headless suite attaches a director to a tree that is
## not running node callbacks yet, and calls this itself.
func setup() -> void:
	if _music != null:
		return
	if LaunchArgs.current().no_audio:
		enabled = false
	_ensure_buses()
	bank = SoundBank.load_default()
	library = MusicLibrary.load_default()
	_build_players()
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	_music.bus = BUS_MUSIC
	add_child(_music)
	_apply_music_volume()

# ------------------------------------------------------------------
#                              effects
# ------------------------------------------------------------------

## `CSound::Play`. A cue already sounding is left alone rather than restarted,
## and nothing starts at all once [method begin_shutdown] has run.
func play(id: StringName, loop: bool = false) -> void:
	if not enabled or _quitting:
		return
	var player: AudioStreamPlayer = _players.get(id, null)
	if player == null or player.playing:
		return
	_set_loop(player.stream, loop)
	_looping[id] = loop
	player.play()

## `CSound::Halt` — a no-op unless the cue was started looping.
func halt(id: StringName) -> void:
	if not _looping.get(id, false):
		return
	var player: AudioStreamPlayer = _players.get(id, null)
	if player != null:
		player.stop()
	_looping[id] = false

## `CSound::HaltAll`, which does stop one-shots too.
func halt_all() -> void:
	for id: StringName in _players:
		(_players[id] as AudioStreamPlayer).stop()
		_looping[id] = false

func is_playing(id: StringName) -> bool:
	var player: AudioStreamPlayer = _players.get(id, null)
	return player != null and player.playing

## `CalcSoundVol` in `racing.cpp`: the per-cue gain against the global effects
## volume, clipped at the mixer ceiling.
func cue_volume(gain: float) -> float:
	return minf(float(sound_volume) * gain, MAX_VOLUME)

# ------------------------------------------------------------------
#                               music
# ------------------------------------------------------------------

## `CMusic::Play`. Asking for the piece that is already playing is not a
## restart — the original compares against `curr_music` and returns — which is
## what lets the menu open over a race without cutting the track.
func play_music(id: StringName, loop: bool = true) -> void:
	_play_stream(library.track(id) if library != null else "", loop)

## `CMusic::PlayTheme`.
func play_theme(theme_id: StringName, situation: MusicTheme.Situation) -> void:
	if library == null:
		return
	var theme: MusicTheme = library.theme(theme_id)
	if theme == null:
		return
	_play_stream(theme.for_situation(situation), true)

## `param.menu_music` — what every menu in the original plays.
func play_menu_music() -> void:
	if library != null:
		play_music(library.menu_track)

## `CMusic::Halt`.
func stop_music() -> void:
	_current_track_path = ""
	if _music != null:
		_music.stop()

func music_track() -> AudioStream:
	return _music.stream if _music != null else null

## Streamed rather than passed an already-loaded [AudioStream]: on the web
## export music is not in the base bundle (see [PackStream]), so the piece
## has to be fetched before it can be loaded. On every other build
## [method PackStream.ensure] resolves in the same call — the resource is
## already there — so this still assigns [member _music]`.stream`
## synchronously with respect to the caller in every case that matters to a
## test.
func _play_stream(path: String, loop: bool) -> void:
	if not enabled or _quitting or _music == null or path.is_empty():
		return
	if path == _current_track_path and _music.playing:
		return
	_current_track_path = path
	if await PackStream.ensure(path, "music.pck") != OK:
		return
	var stream: AudioStream = load(path)
	if stream == null:
		return
	# Checked again on the far side of the await: on a web build that fetch is
	# a real round trip, and a quit can land in the middle of it.
	if _quitting:
		return
	_set_loop(stream, loop)
	_music.stream = stream
	_music.play()

# ------------------------------------------------------------------
#                              plumbing
# ------------------------------------------------------------------

func _build_players() -> void:
	if bank == null:
		return
	for cue: SoundCue in bank.cues:
		if cue == null or cue.id.is_empty() or cue.stream == null:
			continue
		var player := AudioStreamPlayer.new()
		player.name = String(cue.id)
		player.stream = cue.stream
		player.bus = BUS_SFX
		add_child(player)
		_players[cue.id] = player
	_apply_sound_volumes()

## The original sets every chunk to `param.sound_volume` at load and then
## overrides six of them on entering a race, and never puts them back. Since a
## race is the only place any of those six can sound, applying the gains once
## here is indistinguishable from doing it in `CRacing::Enter`.
func _apply_sound_volumes() -> void:
	if bank == null:
		return
	for cue: SoundCue in bank.cues:
		var player: AudioStreamPlayer = _players.get(cue.id, null)
		if player != null:
			player.volume_db = _percent_to_db(cue_volume(cue.race_gain))

func _apply_music_volume() -> void:
	var bus: int = AudioServer.get_bus_index(BUS_MUSIC)
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, _percent_to_db(float(music_volume)))

static func _percent_to_db(percent: float) -> float:
	if percent <= 0.0:
		return SILENCE_DB
	return linear_to_db(percent / MAX_VOLUME)

## Looping is a property of the stream in Godot and of the call in SFML, so it
## is set per play rather than baked into the import.
##
## The streams are shared — `wonrace_1` is the win sting of all three themes —
## which is safe only because every caller agrees: music always loops, and the
## one looping effect is the terrain slide, whose cue is used nowhere else.
static func _set_loop(stream: AudioStream, loop: bool) -> void:
	if stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = \
			AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = loop

func _ensure_buses() -> void:
	for name: StringName in [BUS_MUSIC, BUS_SFX]:
		if AudioServer.get_bus_index(name) >= 0:
			continue
		var index: int = AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, name)
		AudioServer.set_bus_send(index, &"Master")
