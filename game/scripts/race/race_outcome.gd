## The finish-line clip for a just-finished race: `wonrace` or `lostrace`.
##
## A free function rather than a static method on [RaceScene] on purpose.
## [RaceScene] carries a hard reference to the `Config` autoload, and a script
## elsewhere that calls one of its static members forces GDScript to eagerly
## parse the whole class to resolve the call — which is the same parse-cycle
## shape the AGENTS.md trap list already warns about for two autoloads. A pure
## mapping has no reason to drag that in just to be asserted from a test.
class_name RaceOutcome
extends RefCounted

## There are no cups in this rebuild, so the mapping is: a field race
## ([param is_race]) is decided by place ([param won_race]); a solo race is
## decided by beating the saved run it was raced against ([param has_ghost],
## [param beat_ghost]); a plain practice run — neither — has nothing to lose,
## so it celebrates.
##
## DEVIATION: ETR plays `finish` there (`CGameOver::Enter`). That clip is the
## shared stand-up — a second and more of crouching head-down — ending on a flat
## stance with nothing after it, and at the end of every practice run it reads
## as a sulk. `wonrace` is the same stand-up with a lean back and a hop, which
## is also what the music already says: ETR plays the win sting for any practice
## run that was not aborted. `finish` stays the fallback for a character
## without the clip — see [method RaceScene._start_finish_clip].
static func clip(is_race: bool, won_race: bool, has_ghost: bool, beat_ghost: bool) -> StringName:
	if is_race:
		return &"wonrace" if won_race else &"lostrace"
	if has_ghost:
		return &"wonrace" if beat_ghost else &"lostrace"
	return &"wonrace"
