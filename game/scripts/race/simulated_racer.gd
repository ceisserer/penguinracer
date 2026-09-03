## A racer whose motion is computed here, from intent.
##
## The player is one. So is a computer opponent — same class, an
## [AIInputSource] instead of a [LocalInputSource] — and so is the replay of a
## recorded input trace. What they
## share is that a [RacePhysics] is stepped for them every tick, which is also
## what they cost: the ODE loop, the surface queries, the spray and the
## deformation stamps. A ghost and a remote peer are [PlaybackRacer]s precisely
## so that none of that is paid twice.
##
## Everything that hangs off the simulation hangs off here: the spray emitter is
## driven from the substep signal, the snow stamps are laid inside the substep
## loop so a fast pass leaves a continuous trench, and the recorder takes one
## word of intent and — every third tick — one pose.
##
## [b]The item grid is shared.[/b] Two simulated racers on one course race for
## the same herring and the first one there takes it, because
## [member RacePhysics.items] is one [ObjectGrid] and collecting clears the flag
## on it. That is the competitive reading and the one the original's data
## supports; per-racer herring would be a grid each, which is a copy of the
## whole item table per opponent. A ghost cannot take anything — it is not
## simulated and never touches the grid.
class_name SimulatedRacer
extends Racer

## An item was collected. Carries the racer because the scene has to know whose
## count to show and, for the local player, whether to play the pickup cue.
signal item_collected(racer: SimulatedRacer, index: int)
signal tree_hit(racer: SimulatedRacer, tree_pos: Vector3)
## This racer ran into another one. [param rival] is a slot in the
## [RacerField] the scene published, not an index into its racer list — they
## are the same list today and the scene is the only thing that knows that.
signal racer_hit(racer: SimulatedRacer, rival: int)

var physics: RacePhysics
var input_source: InputSource = InputSource.new()
## Records this racer's run. Always present for the local player; the ghost it
## produces is only kept if the run was worth keeping.
var recorder: RaceRecorder

## The race clock as this racer experiences it — it stops at their finish line,
## not at anybody else's.
var race_time: float = 0.0
## False while the start animation is playing, while the menu is up, and after
## the scene has torn the simulation down.
var running: bool = false

## This racer's spray. One per simulated racer: the emission counts come out of
## their own steering and their own substeps, so it cannot be shared.
var spray: SprayEmitter
## Particles the spray may have in flight per side. Read once, by [method
## _ready], so it has to be set before the racer enters the tree.
##
## An opponent gets a smaller pool than the player: nine of them at the player's
## budget is 12 600 particles for penguins that are mostly a dot in the fog, and
## the whole reason the pool is fixed at all is to stop a brake-slide spiking a
## frame on a phone.
var spray_pool: int = 700
## Metres across the start line this racer begins from. Zero for the player,
## whose start point is the one the course authored — which is what keeps a
## practice run byte-identical to one from before there were opponents.
var start_offset: float = 0.0
## The CPU deformation mirror this racer stamps, and the GPU one. Both may be
## null — the GPU field is a single 64 m window that follows the view target, so
## a racer outside it stamps the CPU mirror only.
var snow_cpu: SnowField
var snow_gpu: SnowFieldGPU
## Whether this racer's passage deforms the snow at all. On for everyone today;
## the knob exists because eight racers stamping one 1024² render target is the
## first thing that would have to give.
var deforms_snow: bool = true

var _input := RaceInput.new()
## Reused by the once-a-substep terrain query, so the stamps do not allocate.
var _sample := SurfaceSample.new()

func is_simulated() -> bool:
	return true

func _ready() -> void:
	spray = SprayEmitter.new()
	spray.name = "Spray"
	spray.pool_size = spray_pool
	# The emitter positions its two particle systems in world space and steers
	# them with world-space direction vectors, so it must not inherit this
	# node's basis — which is the racer's body, rolling and pitching with the
	# terrain. `top_level` is what keeps the spray upright.
	spray.top_level = true
	add_child(spray)

## Give this racer a simulation to run. Called once per course load; the signals
## are connected here rather than in the scene so that adding a racer is one
## call and cannot forget one.
func attach_physics(p: RacePhysics) -> void:
	physics = p
	spray.surface = p.surface
	physics.substep_advanced.connect(_on_substep)
	physics.item_collected.connect(_on_item_collected)
	physics.tree_hit.connect(func(pos: Vector3) -> void: tree_hit.emit(self, pos))
	physics.racer_hit.connect(func(rival: int) -> void: racer_hit.emit(self, rival))
	physics.race_finished.connect(_on_race_finished)

## Put the racer back on the start line and start a fresh recording.
func restart(start_x: float, start_z: float, course_dir: String) -> void:
	physics.init_at(start_x, start_z)
	race_time = 0.0
	herring = 0
	finished = false
	finish_time = 0.0
	running = true
	input_source.reset()
	state.capture(physics, 0.0, 0)
	snap()
	if recorder != null:
		recorder.begin(course_dir, character_dir, display_name)

## One simulation tick: read intent, step the world, publish the result.
##
## The order is the contract. Intent is polled with the tick length, never a
## frame time, so a source that integrates — the keyboard's hold filter, an AI's
## steering ramp — sees the same delta the physics does. The state is captured
## after the step, and [member previous] is kept from before it, which is what
## [method Racer.present] reads between.
func advance(dt: float) -> void:
	if not running:
		return
	input_source.poll(_input, physics, dt)
	physics.step(_input, dt)
	if not physics.finished:
		race_time += dt
	previous.copy_from(state)
	state.capture(physics, race_time, herring)
	if recorder != null:
		recorder.record(_input, state)

## The intent applied on the last tick. The HUD does not read it; the network
## layer would, if this were ever changed to send inputs rather than snapshots.
func last_input() -> RaceInput:
	return _input

# ------------------------------------------------------------------
#                     what hangs off the simulation
# ------------------------------------------------------------------

## Stamp the deformation field from inside the substep loop, so a fast pass
## leaves a continuous trench instead of a dotted line at frame boundaries.
func _on_substep(h: float, pos: Vector3, speed: float) -> void:
	spray.emit_for_substep(physics, h, pos, speed)
	if physics.airborne or not deforms_snow:
		return
	physics.surface.sample_into(pos.x, pos.z, _sample)
	# `[trackmarks]`, not `[part]`: ETR keeps the two separate, and `strike_snow`
	# is the terrain where they disagree — it sprays but holds no track.
	if not _sample.takes_trackmarks:
		return
	# How deep the belly is riding, capped by the terrain's own compression.
	var sink: float = clampf(_sample.height - pos.y, 0.0, _sample.compression_depth * 2.0)
	var amount: float = maxf(sink, 0.01) * minf(1.0, speed / 6.0)
	if snow_cpu != null:
		snow_cpu.stamp(pos.x, pos.z, PhysConst.TUX_WIDTH * 0.5, amount * h * 20.0)
	if snow_gpu != null:
		snow_gpu.stamp(pos.x, pos.z, PhysConst.TUX_WIDTH * 0.5, amount)

func _on_item_collected(index: int) -> void:
	herring += 1
	state.herring = herring
	item_collected.emit(self, index)

func _on_race_finished() -> void:
	finished = true
	finish_time = race_time
	finished_race.emit(self)

## The terrain normal under the racer, straight off the simulation. The chase
## camera leans its offset with it so it does not bury itself in a steep pitch.
func surface_normal() -> Vector3:
	return physics.plane_nml if physics != null else Vector3.UP
