## Headless test entry point.
##
##     godot --headless --path game --script res://tests/run_tests.gd
##
## Exits non-zero on any failure so it can gate CI.
extends SceneTree

## Everything runs on the first frame rather than in `_initialize`, because the
## tree's root is not itself inside the tree yet at that point and an
## [AudioStreamPlayer] refuses to start outside one. The physics suite does not
## care either way; the audio group does.
func _process(_delta: float) -> bool:
	_run()
	return true

func _run() -> void:
	var t := TestCase.new()
	var start: int = Time.get_ticks_msec()

	TestScripts.run(t)
	TestForces.run(t)
	TestSimulation.run(t)
	TestSurface.run(t)
	TestTerrainLibrary.run(t)
	TestEnvironments.run(t)
	TestObjects.run(t)
	TestCharacter.run(t)
	TestCamera.run(t)
	TestReflection.run(t)
	TestConfig.run(t)
	TestInput.run(t)
	TestMultiplayer.run(t)
	TestSpray.run(t)
	TestAI.run(t)
	TestAudio.run(t)
	TestPackStream.run(t)

	var elapsed: int = Time.get_ticks_msec() - start
	print("")
	print("=== PenguinRacer physics suite ===")
	for f: String in t.failures():
		print("  FAIL  ", f)
	print("  %d passed, %d failed  (%d ms)" % [t.passed, t.failed, elapsed])

	if t.failed == 0 and not OS.get_cmdline_user_args().has("--no-bench"):
		print("")
		print("=== ODE substep benchmark (risk S2) ===")
		var b: Dictionary = BenchPhysics.run()
		print("  %d frames / %.0f s simulated in %.1f ms wall" % [
			b["frames"], b["simulated_seconds"], b["wall_ms"]])
		print("  %.4f ms per frame  (%.2f%% of a 16.7 ms budget)" % [
			b["per_frame_ms"], b["budget_fraction"] * 100.0])
		print("  %.2f ODE substeps per frame, %d total" % [
			b["substeps_per_frame"], b["substeps"]])
		print("  %.2f net-force evaluations per frame" % b["evals_per_frame"])
		print("  %.0fx real time on this machine" % b["realtime_factor"])
		print("  final speed %.1f m/s over %.0f m" % [b["final_speed"], b["distance"]])

		# The two numbers that actually predict a frame. S2 measured the ODE
		# loop, which was never the problem; a field of ten and the snow
		# mirror's own maintenance are where the milliseconds were.
		print("")
		print("=== a full hill ===")
		var f: Dictionary = BenchPhysics.run_field()
		print("  %d racers, %d planning lines, one snow field" % [
			f["racers"], f["racers"] - 1])
		print("  %.4f ms per frame  (%.2f%% of a 16.7 ms budget)" % [
			f["per_frame_ms"], f["budget_fraction"] * 100.0])
		var s: Dictionary = BenchPhysics.bench_snow()
		print("  SnowField.decay %.4f ms/tick, recenter %.4f ms/tick" % [
			s["decay_ms"], s["recenter_ms"]])

	quit(0 if t.failed == 0 else 1)
