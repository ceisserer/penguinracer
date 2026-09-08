## The native side of course/music streaming: [PackStream] itself never runs
## a network fetch on this platform, so what is testable headlessly is the
## no-op path every native build takes — see the class doc on [PackStream]
## and risk S6 in `godot-port-plan.md`.
class_name TestPackStream
extends RefCounted

static func run(t: TestCase) -> void:
	t.begin("pack_stream/native_no_op")
	# A resource this build already ships: PackStream must not attempt
	# anything, native or web, once ResourceLoader already has it.
	var ok_err: Error = await PackStream.ensure(MusicLibrary.PATH, "music.pck")
	t.ok(ok_err == OK, "an already-bundled resource resolves without a fetch")

	# A path nothing bundles. On this platform (not web) PackStream must
	# report it missing rather than try an HTTP request that has nowhere to
	# go in a headless run.
	if not OS.has_feature("web"):
		var missing_err: Error = await PackStream.ensure(
			"res://courses/__does_not_exist__/course.tscn", "courses/__does_not_exist__.pck")
		t.ok(missing_err == ERR_FILE_NOT_FOUND,
			"a native build never fetches — an unbundled path is just missing")
