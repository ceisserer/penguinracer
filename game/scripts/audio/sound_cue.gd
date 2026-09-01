## One effect from ETR's `data/sounds/sounds.lst`.
##
## The original keeps a single `sf::Sound` per entry and retriggering one that
## is already playing is dropped ([code]TSound::Play[/code] early-returns on
## [code]Playing[/code]). [AudioDirector] reproduces that by owning one
## [AudioStreamPlayer] per cue rather than a voice pool, so a burst of herring
## pickups layers exactly as many voices as the original does.
@tool
class_name SoundCue
extends Resource

@export var id: StringName = &""
@export var stream: AudioStream

## Multiplier on the global effects volume, transcribed from `SetSoundVolumes`
## in `racing.cpp` — the original's only per-sound mix. The result is
## [code]min(sound_volume * race_gain, 100)[/code], so at the default volume of
## 90 the snow slide's 1.5 is clipped back to 1.11 by the ceiling.
@export var race_gain: float = 1.0

## The `[vol]` column of `sounds.lst`, migrated for provenance only.
##
## The original never reads it: [code]CSound::LoadChunk[/code] constructs every
## chunk at [code]param.sound_volume[/code] and nothing revisits it except the
## six entries `racing.cpp` overrides by name. Kept the way
## [member TerrainLayer.legacy_color] is — so a re-import can be diffed against
## the source, and so the discrepancy is visible rather than lost.
@export var legacy_volume: float = 1.0
