## Where a racer's intent comes from.
##
## [RaceInput] has always been the shape of one frame of intent; this is the
## thing that produces it, and it is the seam an AI opponent arrives through.
## Four kinds exist or are foreseen:
##
## - [LocalInputSource] — the keyboard, through [KeyHoldFilter].
## - [ScriptedInputSource] — the canned carve a capture run drives with.
## - [ReplayInputSource] — a recorded trace, re-simulated rather than played
##   back as poses. See [RaceRecording] for when that is the right one.
## - [AIInputSource] — a computer opponent. Nothing had to be added for it:
##   [method poll] is handed the simulation, which owns the position, the
##   velocity, the [SurfaceProvider] under the racer and the tree grid ahead of
##   it. An opponent is a subclass that reads those and returns intent, not a
##   new kind of racer.
##
## [b]Not[/b] a network peer. A remote racer is not simulated here at all — it
## is a [PlaybackRacer] fed by the snapshots its own machine sends. See
## [RaceNetwork] for why that is the model and what it costs.
##
## The signature deliberately takes [RacePhysics] rather than a [Racer]: the
## simulation is everything a source could want to look at, and keeping the node
## layer out of it means an input source is as headless-testable as the physics
## it drives.
class_name InputSource
extends RefCounted

## Fill [param out] with this frame's intent. Called once per simulation tick,
## with [param delta] the fixed tick length — never a frame time.
func poll(out: RaceInput, physics: RacePhysics, delta: float) -> void:
	out.clear()

## Put the source back to the start of a run. Called by [method
## SimulatedRacer.restart]; a stateless source can ignore it.
func reset() -> void:
	pass

## One word for the HUD and the logs.
func describe() -> String:
	return "none"
