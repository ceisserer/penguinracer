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

## How long [method quit_game] leaves between silencing the mixer and bringing
## the tree down. See that method for why the wait exists and how long it has
## to be; the measured floor is one mixer buffer and this is several of them.
const QUIT_SETTLE := 0.1

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
var _current_track: AudioStream
## Set by [method quit_game] so a second close request cannot restart the wait.
var _quitting: bool = false

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

## Stop everything that is sounding. Safe to call more than once.
func silence() -> void:
	halt_all()
	if _music != null:
		_music.stop()
		_music.stream = null
	_current_track = null

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
## Only the music showed up there, because it is the one thing still playing
## when a player quits; a looping slide cue would have joined it.
##
## [b]How long, and why it is not counted in frames.[/b] What has to elapse is
## one mixer buffer on the audio thread, which is wall-clock time and has
## nothing to do with how fast the renderer is going. Waiting a frame or two
## happens to work on a slow frame and not on a fast one: in a scene idling at
## about 1500 fps, five runs each, yielding without a wall-clock wait leaked
## 5/5 and a 5 ms wait leaked 0/5 — the frames were there either way, the
## milliseconds were not. [constant QUIT_SETTLE] is 100 ms, several buffers at
## any plausible latency setting, and not something a player feels on the way
## out. A frame count that looked sufficient on this machine would have been a
## frame count that came apart on a faster one.
func quit_game(code: int = 0) -> void:
	if _quitting:
		return
	_quitting = true
	silence()
	await get_tree().create_timer(QUIT_SETTLE, true, false, true).timeout
	get_tree().quit(code)

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

## `CSound::Play`. A cue already sounding is left alone rather than restarted.
func play(id: StringName, loop: bool = false) -> void:
	if not enabled:
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
	_play_stream(library.track(id) if library != null else null, loop)

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
	_current_track = null
	if _music != null:
		_music.stop()

func music_track() -> AudioStream:
	return _current_track

func _play_stream(stream: AudioStream, loop: bool) -> void:
	if not enabled or _music == null or stream == null:
		return
	if stream == _current_track and _music.playing:
		return
	_set_loop(stream, loop)
	_current_track = stream
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
