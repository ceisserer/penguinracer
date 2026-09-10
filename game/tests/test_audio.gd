## The audio data and the original's mixing arithmetic.
##
## Nothing here is audible — a headless run has the Dummy driver — but
## everything that decides *what* plays is data, and that is what breaks
## silently. The bank, the themes, the terrain → cue mapping and `CalcSoundVol`
## are all checked against `audio.cpp`, `racing.cpp` and the two `.lst` files
## they read.
##
## "Not audible" is not "not testable", and reading it that way is what let the
## terrain slide hold a voice and emit silence for a whole phase. The Dummy
## driver still mixes, so a stream that cannot produce a frame is visible here
## — see the loop-window assertions in [method _director_behaviour], and
## `AudioDirector._set_loop` for what they are guarding.
class_name TestAudio
extends RefCounted

static func run(t: TestCase) -> void:
	_sound_bank(t)
	_volume_curve(t)
	_music_library(t)
	_terrain_cues(t)
	_director_behaviour(t)

static func _sound_bank(t: TestCase) -> void:
	t.begin("audio/sound bank")
	var bank := SoundBank.load_default()
	t.ok(bank.cues.size() == 10, "all ten of sounds.lst survived (%d)" % bank.cues.size())

	for id: StringName in [&"tree_hit", &"pickup1", &"pickup2", &"pickup3",
			&"snow_sound", &"ice_sound", &"rock_sound", &"grass_sound",
			&"mud_sound", &"leaves_sound"]:
		var cue: SoundCue = bank.cue(id)
		t.ok(cue != null and cue.stream != null, "cue '%s' has a stream" % id)

	t.ok(bank.cue(&"no_such_sound") == null, "an unknown name resolves to nothing")

	# `SetSoundVolumes` in racing.cpp, the original's whole per-sound mix.
	t.eq_f(bank.cue(&"snow_sound").race_gain, 1.5, 1e-6, "snow keeps its 1.5 gain")
	t.eq_f(bank.cue(&"ice_sound").race_gain, 0.6, 1e-6, "ice keeps its 0.6 gain")
	t.eq_f(bank.cue(&"rock_sound").race_gain, 1.1, 1e-6, "rock keeps its 1.1 gain")
	t.eq_f(bank.cue(&"pickup2").race_gain, 0.8, 1e-6, "the second pickup is quieter")
	# The four the original never names keep the plain effects volume.
	t.eq_f(bank.cue(&"grass_sound").race_gain, 1.0, 1e-6, "grass is never rebalanced")
	t.eq_f(bank.cue(&"tree_hit").race_gain, 1.0, 1e-6, "the tree hit is never rebalanced")

	# `[vol]` is dead data in the original but is migrated, and the two
	# genuinely disagree — which is the whole reason to keep both.
	t.eq_f(bank.cue(&"snow_sound").legacy_volume, 0.2, 1e-6,
		"sounds.lst still says 0.2 for the snow slide")

static func _volume_curve(t: TestCase) -> void:
	t.begin("audio/volume curve")
	# CalcSoundVol: min(sound_volume * fact, MIX_MAX_VOLUME), MIX_MAX_VOLUME=100.
	var director := AudioDirector.new()
	t.eq_f(director.cue_volume(1.0), 90.0, 1e-4, "the default effects volume is 90")
	t.eq_f(director.cue_volume(0.8), 72.0, 1e-4, "a 0.8 gain lands at 72")
	t.eq_f(director.cue_volume(1.5), 100.0, 1e-4,
		"the snow slide's 1.5 is clipped by the mixer ceiling, not scaled")
	t.eq_f(director.cue_volume(1.1), 99.0, 1e-4, "rock at 1.1 just fits under it")

	director.sound_volume = 50
	t.eq_f(director.cue_volume(1.5), 75.0, 1e-4, "below the ceiling the gain is linear again")
	director.sound_volume = 200
	t.eq_f(director.cue_volume(1.0), 100.0, 1e-4, "the volume itself is clamped to 100")

	# SFML's volume is a linear amplitude percentage, so half amplitude is -6 dB.
	t.eq_f(AudioDirector._percent_to_db(100.0), 0.0, 1e-4, "full volume is unity gain")
	t.eq_f(AudioDirector._percent_to_db(50.0), -6.0206, 1e-3, "half amplitude is -6 dB")
	t.eq_f(AudioDirector._percent_to_db(20.0), -13.9794, 1e-3,
		"the default music volume of 20 is -14 dB")
	t.ok(AudioDirector._percent_to_db(0.0) < -60.0 and is_finite(AudioDirector._percent_to_db(0.0)),
		"silence is a finite floor, not -inf")
	director.free()

static func _music_library(t: TestCase) -> void:
	t.begin("audio/music library")
	var lib := MusicLibrary.load_default()
	t.ok(lib.tracks.size() == 10, "all ten of music.lst survived (%d)" % lib.tracks.size())
	t.ok(lib.themes.size() == 3, "normal, calm and spunky (%d)" % lib.themes.size())

	# Unreferenced by anything in the original, and kept anyway.
	t.ok(not lib.track(&"freezingpoint").is_empty(), "an unreferenced piece is still imported")
	t.ok(not lib.track(&"raceintro").is_empty(), "so is the other one")
	t.ok(lib.track(&"nothing_here").is_empty(), "an unknown name resolves to nothing")
	t.ok(not lib.track(lib.menu_track).is_empty(), "param.menu_music resolves")
	t.ok(not lib.track(lib.credits_track).is_empty(), "param.credits_music resolves")
	t.ok(not lib.track(lib.options_track).is_empty(), "param.config_music resolves")

	var normal: MusicTheme = lib.theme(&"normal")
	t.ok(normal != null and normal.id == &"normal", "the normal theme is there")
	t.ok(normal.race_path == lib.track(&"race_1"), "normal races to race_1")
	t.ok(normal.won_path == lib.track(&"wonrace_1"), "and wins to wonrace_1")
	t.ok(normal.lost_path == lib.track(&"lostrace_1"), "and loses to lostrace_1")

	# The three themes differ only in the racing track — the stings are shared,
	# which is what the situation split buys.
	var calm: MusicTheme = lib.theme(&"calm")
	t.ok(calm.race_path != normal.race_path, "calm races to a different piece")
	t.ok(calm.won_path == normal.won_path, "but shares the win sting")
	t.ok(normal.for_situation(MusicTheme.Situation.RACE) == normal.race_path, "RACE selects the race track")
	t.ok(normal.for_situation(MusicTheme.Situation.WON) == normal.won_path, "WON selects the win sting")
	t.ok(normal.for_situation(MusicTheme.Situation.LOST) == normal.lost_path, "LOST selects the loss sting")

	# racing_themes.lst declares its first entry the fallback.
	t.ok(lib.theme(&"no_such_theme") == lib.themes[0], "an unknown theme falls back to the first")

static func _terrain_cues(t: TestCase) -> void:
	t.begin("audio/terrain cues")
	var bank := SoundBank.load_default()
	var checked: int = 0
	var silent: int = 0
	var dir := DirAccess.open("res://resources/terrain")
	t.ok(dir != null, "the terrain layers are on disk")
	if dir == null:
		return
	for file: String in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var layer: TerrainLayer = load("res://resources/terrain/%s" % file)
		checked += 1
		if layer.slide_sound.is_empty():
			silent += 1
		else:
			t.ok(bank.has_cue(layer.slide_sound),
				"'%s' names a cue that exists (%s)" % [layer.id, layer.slide_sound])
	t.ok(checked >= 40, "every terrain layer was checked (%d)" % checked)

	# The original rides its commonest surface in silence: `snow` ships without
	# a `[sound]` and only `dirty_snow` ever reaches `snow_sound`. Asserted so
	# that filling the gap is a deliberate, visible change rather than a drift.
	var snow: TerrainLayer = load("res://resources/terrain/snow.tres")
	t.ok(snow.slide_sound.is_empty(), "plain snow is silent, as in the original")
	var dirty: TerrainLayer = load("res://resources/terrain/dirty_snow.tres")
	t.ok(dirty.slide_sound == &"snow_sound", "dirty_snow is the one that uses the snow slide")
	t.ok(silent > 0 and silent < checked, "some terrains sound and some do not (%d silent)" % silent)

	# Ice and rock are the two the mix is built around, and Bunny Hill uses both.
	t.ok((load("res://resources/terrain/ice1.tres") as TerrainLayer).slide_sound == &"ice_sound",
		"ice1 slides on ice")
	t.ok((load("res://resources/terrain/rock.tres") as TerrainLayer).slide_sound == &"rock_sound",
		"rock slides on rock")

## The three behaviours the original's mixer has that a modern one does not,
## exercised against a live director. Headless runs the Dummy audio driver, so
## nothing is audible, but the voice bookkeeping is the same code.
static func _director_behaviour(t: TestCase) -> void:
	t.begin("audio/director")
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		t.ok(false, "no scene tree to attach the director to")
		return
	var director := AudioDirector.new()
	tree.root.add_child(director)
	director.setup()

	t.ok(AudioServer.get_bus_index(AudioDirector.BUS_MUSIC) > 0, "a Music bus exists")
	t.ok(AudioServer.get_bus_index(AudioDirector.BUS_SFX) > 0, "an SFX bus exists")
	t.eq_f(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(AudioDirector.BUS_MUSIC)),
		-13.9794, 1e-3, "the Music bus carries param.music_volume")

	# One player per cue, as `TSound` is one `sf::Sound` per chunk.
	t.ok(director.get_node_or_null(^"rock_sound") != null, "each cue has its own player")
	t.ok(director.get_node_or_null(^"pickup1") != null, "including each of the three pickups")

	director.play(&"rock_sound", true)
	t.ok(director.is_playing(&"rock_sound"), "a looped cue starts")
	var slide: AudioStreamWAV = (director.get_node(^"rock_sound") as AudioStreamPlayer).stream
	t.ok(slide.loop_mode == AudioStreamWAV.LOOP_FORWARD, "and is set to loop")
	# The mode is not the loop. `AudioStreamWAV` takes the playback's end limit
	# from `loop_end` once the mode is on, and the importer leaves it at 0 for
	# every effect here — so `LOOP_FORWARD` by itself wraps to the start having
	# mixed nothing, and the terrain slide held a voice and made no sound on
	# every surface. Assert the window, because the mode above read correct
	# throughout. See `AudioDirector._set_loop`.
	t.ok(slide.loop_end > slide.loop_begin,
		"with a loop window, not just a mode (begin %d, end %d)"
			% [slide.loop_begin, slide.loop_end])
	t.eq_f(float(slide.loop_end - slide.loop_begin) / float(slide.mix_rate),
		slide.get_length(), 1e-3, "and the window is the whole sample")
	# `CSound::Halt` checks getLoop() first: a one-shot cannot be halted.
	director.play(&"tree_hit")
	t.ok(director.is_playing(&"tree_hit"), "a one-shot starts")
	t.ok((director.get_node(^"tree_hit") as AudioStreamPlayer).stream.loop_mode
		== AudioStreamWAV.LOOP_DISABLED,
		"unlooped, which is why the one-shots were never silent")
	director.halt(&"tree_hit")
	t.ok(director.is_playing(&"tree_hit"), "and halt refuses to cut it off")
	director.halt(&"rock_sound")
	t.ok(not director.is_playing(&"rock_sound"), "while the looped cue does stop")

	director.halt_all()
	t.ok(not director.is_playing(&"tree_hit"), "HaltAll stops one-shots too")

	# Asking for the piece already playing is not a restart — this is what lets
	# the menu close back onto an uninterrupted race track.
	director.play_theme(&"normal", MusicTheme.Situation.RACE)
	var playing: AudioStream = director.music_track()
	t.ok(playing != null and playing == load(director.library.track(&"race_1")),
		"the normal theme races to race_1")
	director.play_theme(&"normal", MusicTheme.Situation.RACE)
	t.ok(director.music_track() == playing, "asking again does not swap the stream")
	director.play_theme(&"normal", MusicTheme.Situation.WON)
	t.ok(director.music_track() == load(director.library.track(&"wonrace_1")),
		"a different situation does")

	# What the way out rests on. `quit_game` calls `silence` and then hands the
	# mixer a fixed interval to retire what was stopped; anything `silence`
	# misses is still sounding when the interval runs out, and is reported as a
	# leaked ObjectDB instance at exit rather than as a failure here.
	director.play(&"rock_sound", true)
	t.ok(director.is_playing(&"rock_sound"), "a cue is sounding before the shutdown")
	director.silence()
	t.ok(not director.is_playing(&"rock_sound"), "silence stops a looping effect")
	t.ok(director.music_track() == null, "and forgets the music track")
	t.ok((director.get_node(^"Music") as AudioStreamPlayer).stream == null,
		"and lets go of the stream the music player held")
	director.silence()
	t.ok(director.music_track() == null, "and survives being called twice")

	# ...and the other half: the settle window is live, so a silence that does
	# not also refuse buys nothing. `RaceScene._update_slide_sound` plays the
	# terrain's cue every tick, and `silence` stopping the player is exactly
	# what makes the next call go through — the slide restarted inside the wait
	# and leaked `rock_slide.wav` and its playback on every quit from a race.
	# Like the `silence` group above, the real symptom is an exit-time
	# warning rather than a failure here.
	director.play(&"rock_sound", true)
	t.ok(director.is_playing(&"rock_sound"), "the slide is sounding before the quit")
	director.begin_shutdown()
	t.ok(not director.is_playing(&"rock_sound"), "beginning a shutdown silences it")
	director.play(&"rock_sound", true)
	t.ok(not director.is_playing(&"rock_sound"), "and it cannot start again")
	director.play(&"tree_hit")
	t.ok(not director.is_playing(&"tree_hit"), "nor can a one-shot")
	director.play_theme(&"normal", MusicTheme.Situation.RACE)
	t.ok(director.music_track() == null, "nor the music")

	# And what the wait is now for. `AudioServer` releases a stopped playback an
	# iteration or two later, so the shutdown has to snapshot what it stopped
	# and wait for those objects rather than for an interval standing in for
	# them — a `SceneTree` timer counts frame deltas and returned after 43 ms of
	# a 100 ms wait on the real path, one frame before the music was released.
	# Counted here in the same frame as the shutdown, which is before the
	# server has had an iteration to free anything.
	t.ok(director.settling() == 1,
		"the shutdown waits on the one playback it stopped (got %d)" % director.settling())
	director.begin_shutdown()
	t.ok(director.settling() == 0,
		"and on nothing when nothing was sounding (got %d)" % director.settling())

	# `--no-audio` has to gate every entry point, not just the music.
	director.enabled = false
	director.stop_music()
	director.play(&"pickup1")
	t.ok(not director.is_playing(&"pickup1"), "--no-audio silences effects")
	director.play_theme(&"normal", MusicTheme.Situation.RACE)
	t.ok(director.music_track() == null, "and music")

	tree.root.remove_child(director)
	director.free()
