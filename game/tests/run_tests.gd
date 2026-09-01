## Headless test entry point.
##
##     godot --headless --path game --script res://tests/run_tests.gd
##
## Exits non-zero on any failure so it can gate CI.
extends SceneTree

func _initialize() -> void:
	var t := TestCase.new()
	var start: int = Time.get_ticks_msec()

	TestForces.run(t)
	TestSimulation.run(t)
	TestSurface.run(t)
	TestInput.run(t)

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

	quit(0 if t.failed == 0 else 1)
