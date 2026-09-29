## The course menu's three parts and the list of courses added by address:
## which course is Tux Racer's, what an address may name, and that an entry
## survives on its own — see [ExternalCourses] and [enum CourseListing.Category].
##
## The fetch itself is not here: the suite runs in one frame and a download
## needs many. What it would exercise is [method PackStream.fetch_and_mount],
## which the streamed web build uses for every course.
class_name TestExternalCourses
extends RefCounted

const SCRATCH := "user://test_external_courses.cfg"

static func run(t: TestCase) -> void:
	_the_originals_are_tux_racers(t)
	_addresses(t)
	_the_index(t)
	_the_entry_is_kept(t)

static func _the_originals_are_tux_racers(t: TestCase) -> void:
	t.begin("external courses/categories")
	var catalog: CourseCatalog = CourseCatalog.load_default()
	for dir: String in CourseCatalog.TUXRACER_ORIGINALS:
		var listing: CourseListing = catalog.find(dir)
		t.ok(listing != null, "%s is in the catalog" % dir)
		if listing != null:
			t.ok(listing.category() == CourseListing.Category.TUXRACER,
				"%s is one of Tux Racer's" % dir)
	# ETR's `default` group holds courses ETR added; the group is not the answer.
	var wall: CourseListing = catalog.find("chinese_wall")
	t.ok(wall != null and wall.group == "default"
		and wall.category() == CourseListing.Category.ETR,
		"a course in ETR's default group that ETR added is ETR's")
	var tuxway: CourseListing = catalog.find("tuxway")
	t.ok(tuxway != null and tuxway.category() == CourseListing.Category.ETR,
		"an extras course is ETR's")
	var tux_racer_count: int = 0
	for e: CourseListing in catalog.entries:
		if e.category() == CourseListing.Category.TUXRACER:
			tux_racer_count += 1
	t.ok(tux_racer_count == 5, "five Tux Racer courses (%d)" % tux_racer_count)

	var external := CourseListing.new()
	external.dir = "aaa_first_by_name"
	external.source_url = "https://example.org/aaa_first_by_name.pck"
	t.ok(external.category() == CourseListing.Category.EXTERNAL,
		"a course with an address is an added one")
	var sorted := CourseCatalog.new()
	sorted.entries = catalog.entries.duplicate()
	sorted.entries.push_front(external)
	sorted.sort()
	var last: int = -1
	var ordered: bool = true
	for e: CourseListing in sorted.entries:
		ordered = ordered and e.category() >= last
		last = e.category()
	t.ok(ordered, "sorted Tux Racer, then ETR, then added")
	t.ok(sorted.entries.back() == external, "an added course sorts last whatever its name")

	# Added courses sort by the server they were filed under, then by name.
	var by_server := CourseCatalog.new()
	for spec: Array in [["b", "Zeta", "Alpine"], ["a", "Alpha", "Zermatt"],
			["c", "Beta", "alpine"]]:
		var l := CourseListing.new()
		l.dir = spec[0]
		l.display_name = spec[1]
		l.server_name = spec[2]
		l.source_url = "https://example.org/%s.pck" % spec[0]
		by_server.entries.push_back(l)
	by_server.sort()
	var order: String = "".join(by_server.entries.map(func(l): return l.dir))
	t.ok(order in ["cba", "bca"] and order.ends_with("a"),
		"grouped by server, the server's courses together (%s)" % order)

static func _addresses(t: TestCase) -> void:
	t.begin("external courses/addresses")
	var cases: Dictionary = {
		"https://example.org/courses/my_hill.pck": "my_hill",
		"http://example.org/my-hill.PCK?v=2#x": "my-hill",
		"  https://example.org/a/b/c/Hill_2.pck  ": "Hill_2",
		"ftp://example.org/my_hill.pck": "",
		"https://example.org/my_hill.zip": "",
		"https://example.org/..pck": "",
		"https://example.org/my hill.pck": "",
		"https://my_hill.pck": "",
		"example.org/my_hill.pck": "",
		"": "",
	}
	for url: String in cases:
		var dir: String = ExternalCourses.dir_for_url(url)
		t.ok(dir == cases[url], "%s names '%s' (got '%s')" % [url, cases[url], dir])

static func _the_index(t: TestCase) -> void:
	t.begin("external courses/a folder's index")
	t.ok(ExternalCourses.is_pack_url("https://h.org/a/x.pck?v=1"), "a .pck is one course")
	t.ok(not ExternalCourses.is_pack_url("https://h.org/a/"), "anything else is a folder")
	t.ok(ExternalCourses.index_url_for("https://h.org/packs/") == "https://h.org/packs/courses.json"
		and ExternalCourses.index_url_for("https://h.org/packs") == "https://h.org/packs/courses.json"
		and ExternalCourses.index_url_for("https://h.org") == "https://h.org/courses.json",
		"a folder is asked for its courses.json")
	t.ok(ExternalCourses.index_url_for("https://h.org/list/mine.json") == "https://h.org/list/mine.json",
		"an index named outright is read as it is")
	var text := JSON.stringify({"courses": [
		{"file": "tuxway.pck", "name": "TuXway", "author": "Crazywater",
			"width": 100, "length": 1500, "angle": 25},
		{"file": "sub/deep_one.pck"},
		{"file": "https://mirror.org/far_away.pck", "name": "Far"},
		{"file": "not_a_pack.zip"},
		{"file": "../bad name.pck"},
		"junk",
	]})
	var found: Array[CourseListing] = ExternalCourses.parse_index(text,
		"https://h.org/packs/courses.json", "My Server")
	t.ok(found.size() == 3, "three of six entries are courses (%d)" % found.size())
	if found.size() == 3:
		t.ok(found[0].dir == "tuxway" and found[0].source_url == "https://h.org/packs/tuxway.pck"
			and found[0].title() == "TuXway" and found[0].world_size == Vector2(100, 1500)
			and is_equal_approx(found[0].base_angle, 25.0),
			"a relative file resolves beside the index, with what the index says of it")
		t.ok(found[1].source_url == "https://h.org/packs/sub/deep_one.pck"
			and found[1].title() == "deep_one", "a subfolder resolves; no name reads as the dir")
		t.ok(found[2].source_url == "https://mirror.org/far_away.pck",
			"a whole address is taken as it is")
		t.ok(found.all(func(l): return l.server_name == "My Server" and l.is_external()),
			"all filed under the server name")
	t.ok(ExternalCourses.parse_index("{}", "https://h.org/courses.json", "s").is_empty()
		and ExternalCourses.parse_index("<html>", "https://h.org/courses.json", "s").is_empty(),
		"a page that is not an index lists nothing")

static func _the_entry_is_kept(t: TestCase) -> void:
	t.begin("external courses/the entry is kept")
	var saved_path: String = ExternalCourses.store_path
	ExternalCourses.store_path = SCRATCH
	DirAccess.remove_absolute(SCRATCH)

	t.ok(ExternalCourses.listings().is_empty(), "no file, no courses")
	t.ok(ExternalCourses.check("S", "https://example.org/bunny_hill.pck")
		== ExternalCourses.BUILT_IN, "a course the game ships is refused")
	t.ok(ExternalCourses.check("S", "example.org/") == ExternalCourses.BAD_URL,
		"an address without http(s) is refused")
	t.ok(ExternalCourses.check("  ", "https://example.org/my_hill.pck")
		== ExternalCourses.NO_SERVER_NAME, "a course needs a server name")
	t.ok(ExternalCourses.check("S", "https://example.org/my_hill.pck").is_empty(),
		"a new course is accepted")
	t.ok(ExternalCourses.check("S", "https://example.org/").is_empty(),
		"a folder is accepted before its index is read")

	# What [method ExternalCourses.add] writes once the pack has checked out.
	var cfg := ConfigFile.new()
	cfg.set_value("my_hill", "url", "https://example.org/courses/my_hill.pck")
	cfg.set_value("my_hill", "server", "Home")
	cfg.set_value("my_hill", "name", "My Hill")
	cfg.set_value("my_hill", "author", "Somebody")
	cfg.set_value("my_hill", "world_size", Vector2(80, 900))
	cfg.set_value("my_hill", "base_angle", 27.0)
	# An entry whose address does not name its section is not trusted.
	cfg.set_value("other", "url", "https://example.org/courses/my_hill.pck")
	cfg.save(SCRATCH)

	var listings: Array[CourseListing] = ExternalCourses.listings()
	t.ok(listings.size() == 1, "one course read back (%d)" % listings.size())
	if listings.size() == 1:
		var l: CourseListing = listings[0]
		t.ok(l.dir == "my_hill" and l.title() == "My Hill" and l.author == "Somebody",
			"name and author read back")
		t.ok(l.server_name == "Home", "the server name reads back")
		t.ok(l.world_size == Vector2(80, 900) and is_equal_approx(l.base_angle, 27.0),
			"size and slope read back")
		t.ok(l.is_external() and l.scene_path == "res://courses/my_hill/course.tscn",
			"it loads from where its pack mounts")
		t.ok(not ExternalCourses.is_mounted("my_hill"),
			"nothing is fetched by reading the list")
	t.ok(ExternalCourses.check("Other", "https://elsewhere.org/my_hill.pck")
		== ExternalCourses.ALREADY_ADDED, "the same course twice is refused")

	ExternalCourses.remove("my_hill")
	t.ok(ExternalCourses.listings().is_empty(), "removed is gone")

	DirAccess.remove_absolute(SCRATCH)
	ExternalCourses.store_path = saved_path
