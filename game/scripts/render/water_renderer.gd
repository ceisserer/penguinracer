## The water standing on a course: its surface, its waves and wakes, and the
## water the racers throw up wading through it.
##
## DEVIATION: ETR has no water. A course that has some carries it as
## [member CourseData.water], a signed depth per heightmap vertex; the physics
## wades in it ([method RacePhysics.calc_water_force]) and this draws it, both
## off the same grid, so the shoreline a racer is slowed at is the one on
## screen.
##
## [b]The surface.[/b] Every heightmap cell the water touches is cut into
## [constant SUB]² quads (17 cm — the 50 cm terrain grid is far too coarse to
## move), stood at the water's level — the ground plus the signed depth, which
## on a bank is *under* the ground, so the depth test cuts the shoreline where
## the two meet — and carrying the depth in `UV.x` for `water.gdshader`. Cut
## into [constant TILE] cell tiles, one [MeshInstance3D] each, so a view sees
## only the puddles in front of it.
##
## [b]Presentation only[/b] (architecture rule 3): the waves, the wakes and the
## splash read the racers' [RacerState]s and the surface, and nothing in the
## race reads them. Run at the screen's rate from [method RaceScene._present].
class_name WaterRenderer
extends Node3D

const SHADER_PATH := "res://shaders/water.gdshader"
## Quads per heightmap cell along each edge.
const SUB := 3
## Heightmap cells per tile along each edge.
const TILE := 32
## Ring buffer of ripple drops; `water.gdshader`'s `drops[]`.
const MAX_DROPS := 32
## Wading racers whose trough and bow wave are drawn; `bodies[]`.
const MAX_BODIES := 4
## Metres between the drops of a wake: closer at a crawl, so a slow racer
## still leaves a train of rings, and spaced out with speed, so a fast one's
## 32 drops reach back the second or two its wake is seen for.
const DROP_SPACING_MIN := 0.3
const DROP_SPACING_PER_SPEED := 0.09
## Wading share below which a racer leaves nothing — the wet rim of a puddle.
const MIN_WADE := 0.05
## Wind [method WindField.speed] at which the waves are at their steepest, and
## that steepness. A light crosswind (≈6–26) raises ripples of a few
## millimetres, a strong one (≈25–85) waves of up to a centimetre: still small
## — a puddle has no fetch to grow anything bigger on.
const WIND_FOR_FULL_WAVES := 70.0
const MAX_STEEPNESS := 0.075

var course: CourseData
var surface: HeightmapSurface
## The material every tile draws with. Exposed for the terrain's setters.
var material: ShaderMaterial

## The environment's `[partcol]` for the splash, as the snow spray takes it.
var particle_color: Color = Color(0.85, 0.9, 1.0):
	set(value):
		particle_color = value
		for splash: WaterSplash in _splashes.values():
			splash.set_color(value)

var _tiles: Array[MeshInstance3D] = []
var _time: float = 0.0
var _drops := PackedVector4Array()
var _next_drop: int = 0
## Per racer (instance id): where it last dropped a ring, and whether it was
## wading on the last frame.
var _last_drop: Dictionary[int, Vector3] = {}
var _wading: Dictionary[int, bool] = {}
var _splashes: Dictionary[int, WaterSplash] = {}
var _droplet: ImageTexture
var _puff: ImageTexture

## Build the water's surface for [param p_course] over [param p_surface]. A
## course without water builds nothing; [method has_water] then says so.
func setup(p_course: CourseData, p_surface: HeightmapSurface) -> void:
	course = p_course
	surface = p_surface
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	_drops.resize(MAX_DROPS)
	_drops.fill(Vector4.ZERO)
	_push_drops()
	material.set_shader_parameter("bodies", _empty_bodies())
	_droplet = ImageTexture.create_from_image(WaterSplash.make_droplet_image())
	# The snow spray's puffs, for the splash's white water: one picture, drawn
	# in code, nothing new for the licence audit.
	_puff = ImageTexture.create_from_image(SprayEmitter.make_puff_image())
	if surface != null and surface.has_water():
		_build_tiles()

func has_water() -> bool:
	return not _tiles.is_empty()

func tile_count() -> int:
	return _tiles.size()

# ------------------------------------------------------------------ the mesh

## Which cells have water, by tile, then one mesh per tile.
##
## The grid is scanned by vertex, not by cell: one read each rather than four
## — 17 ms on Forest Trail's 771 000 vertices against 106 — and a wet vertex
## marks the four cells round it.
func _build_tiles() -> void:
	var w: int = surface.size.x
	var h: int = surface.size.y
	var water: PackedFloat32Array = surface.water_grid()
	var cells: Dictionary[Vector2i, PackedInt32Array] = {}
	var seen: Dictionary[int, bool] = {}
	for i: int in water.size():
		if water[i] <= 0.0:
			continue
		var gx: int = i % w
		@warning_ignore("integer_division")
		var gy: int = i / w
		for cy: int in range(maxi(gy - 1, 0), mini(gy, h - 2) + 1):
			for cx: int in range(maxi(gx - 1, 0), mini(gx, w - 2) + 1):
				var c: int = cy * w + cx
				if seen.has(c):
					continue
				seen[c] = true
				@warning_ignore("integer_division")
				var key := Vector2i(cx / TILE, cy / TILE)
				if not cells.has(key):
					cells[key] = PackedInt32Array()
				cells[key].push_back(c)
	for key: Vector2i in cells:
		var mesh: ArrayMesh = _tile_mesh(key, cells[key], water)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Water_%d_%d" % [key.x, key.y]
		mi.mesh = mesh
		mi.material_override = material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The waves and the trough move it a few centimetres either way.
		mi.extra_cull_margin = 0.3
		add_child(mi)
		_tiles.push_back(mi)

## The water's level at grid vertex [param i]: the ground plus the signed
## depth, in local relief (the slope is added by the caller).
func _level(i: int, water: PackedFloat32Array) -> float:
	return surface.heights[i] + water[i]

## The water's normal at grid vertex (gx, gy), from its level's neighbours —
## a neighbour with no puddle near it (its depth at [constant CourseData.NO_WATER])
## is left out rather than read a metre down.
func _normal(gx: int, gy: int, water: PackedFloat32Array, dx: float, dz: float) -> Vector3:
	var w: int = surface.size.x
	var h: int = surface.size.y
	var i: int = gy * w + gx
	var c: float = _level(i, water)
	var xm: int = maxi(gx - 1, 0)
	var xp: int = mini(gx + 1, w - 1)
	var ym: int = maxi(gy - 1, 0)
	var yp: int = mini(gy + 1, h - 1)
	var lxm: float = _level(gy * w + xm, water) if water[gy * w + xm] > CourseData.NO_WATER * 0.5 else c
	var lxp: float = _level(gy * w + xp, water) if water[gy * w + xp] > CourseData.NO_WATER * 0.5 else c
	var lym: float = _level(ym * w + gx, water) if water[ym * w + gx] > CourseData.NO_WATER * 0.5 else c
	var lyp: float = _level(yp * w + gx, water) if water[yp * w + gx] > CourseData.NO_WATER * 0.5 else c
	var hx: float = (lxp - lxm) / (float(maxi(xp - xm, 1)) * dx)
	# +y in the grid is -z in the world, as in [HeightmapSurface._build_normals].
	var hz: float = -(lyp - lym) / (float(maxi(yp - ym, 1)) * dz) + surface.slope
	return Vector3(-hx, 1.0, -hz).normalized()

## The surface over [param cells] (heightmap cell indices, each the index of
## its first corner), all in tile [param key].
func _tile_mesh(key: Vector2i, cells: PackedInt32Array, water: PackedFloat32Array) -> ArrayMesh:
	var w: int = surface.size.x
	var h: int = surface.size.y
	var dx: float = surface.world_size.x / float(w - 1)
	var dz: float = surface.world_size.y / float(h - 1)
	var x0: int = key.x * TILE
	var y0: int = key.y * TILE
	var x1: int = mini(x0 + TILE, w - 1)
	var y1: int = mini(y0 + TILE, h - 1)
	var span := Vector2i((x1 - x0) * SUB + 1, (y1 - y0) * SUB + 1)
	var index_of := PackedInt32Array()
	index_of.resize(span.x * span.y)
	index_of.fill(-1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Corner normals, per grid vertex of the tile, worked out once.
	var corner_n: Dictionary[int, Vector3] = {}
	var corner := func(ci: int) -> Vector3:
		if not corner_n.has(ci):
			@warning_ignore("integer_division")
			corner_n[ci] = _normal(ci % w, ci / w, water, dx, dz)
		return corner_n[ci]

	var vertex := func(sx: int, sy: int) -> int:
		var slot: int = sy * span.x + sx
		if index_of[slot] >= 0:
			return index_of[slot]
		var gxf: float = float(x0) + float(sx) / SUB
		var gyf: float = float(y0) + float(sy) / SUB
		var gx: int = mini(int(gxf), w - 2)
		var gy: int = mini(int(gyf), h - 2)
		var fx: float = gxf - gx
		var fy: float = gyf - gy
		var i00: int = gy * w + gx
		var i10: int = i00 + 1
		var i01: int = i00 + w
		var i11: int = i01 + 1
		var depth: float = lerpf(lerpf(water[i00], water[i10], fx),
			lerpf(water[i01], water[i11], fx), fy)
		var level: float = lerpf(lerpf(_level(i00, water), _level(i10, water), fx),
			lerpf(_level(i01, water), _level(i11, water), fx), fy)
		var z: float = -gyf * dz
		verts.push_back(Vector3(gxf * dx, level + surface.slope * z, z))
		var n: Vector3 = corner.call(i00) * ((1.0 - fx) * (1.0 - fy)) \
			+ corner.call(i10) * (fx * (1.0 - fy)) \
			+ corner.call(i01) * ((1.0 - fx) * fy) + corner.call(i11) * (fx * fy)
		normals.push_back(n.normalized())
		uvs.push_back(Vector2(depth, 0.0))
		index_of[slot] = verts.size() - 1
		return index_of[slot]

	for cell: int in cells:
		var gx: int = cell % w
		@warning_ignore("integer_division")
		var gy: int = cell / w
		for qy: int in SUB:
			for qx: int in SUB:
				var sx: int = (gx - x0) * SUB + qx
				var sy: int = (gy - y0) * SUB + qy
				var a: int = vertex.call(sx, sy)
				var b: int = vertex.call(sx + 1, sy)
				var c: int = vertex.call(sx, sy + 1)
				var d: int = vertex.call(sx + 1, sy + 1)
				# The terrain chunks' winding ([TerrainRenderer._build_chunk]):
				# clockwise seen from above, Godot's front face.
				indices.append_array([a, c, b, b, c, d])
	if indices.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# ------------------------------------------------------------------ the frame

## How steep the waves the wind raises are: 0 in a calm, up to
## [constant MAX_STEEPNESS], following the gusts.
static func wave_steepness_for(wind: WindField) -> float:
	if wind == null or not wind.windy:
		return 0.0
	return MAX_STEEPNESS * clampf(wind.speed() / WIND_FOR_FULL_WAVES, 0.0, 1.0)

## Which way the wind blows, flat, as (x, z) — [method WindField.angle] is
## degrees from `+z` toward `+x`.
static func wind_direction(wind: WindField) -> Vector2:
	if wind == null:
		return Vector2(1.0, 0.0)
	var a: float = deg_to_rad(wind.angle())
	return Vector2(sin(a), cos(a))

## How deep a racer at [param position] wades, 0..1 — the physics' own measure
## ([method RacePhysics.calc_water_force]), from the drawn pose: the point mass
## under the water's surface, over [constant RacePhysics.WATER_FULL_DEPTH].
static func wade_at(ground: HeightmapSurface, position: Vector3) -> float:
	if ground == null:
		return 0.0
	var depth: float = ground.water_depth_at(position.x, position.z)
	if depth <= 0.0:
		return 0.0
	var level: float = ground.height_at(position.x, position.z) + depth
	return clampf(clampf(level - position.y, 0.0, depth) / RacePhysics.WATER_FULL_DEPTH,
		0.0, 1.0)

## One frame of the water: the clock, the wind's waves, and for every racer in
## it a wake and a splash. [param camera] decides which four bodies are drawn
## when more are wading.
func update(racers: Array[Racer], wind: WindField, camera: Vector3, delta: float) -> void:
	if not has_water():
		return
	_time += delta
	material.set_shader_parameter("water_time", _time)
	material.set_shader_parameter("wind_steepness", wave_steepness_for(wind))
	material.set_shader_parameter("wind_dir", wind_direction(wind))

	var wading: Array[Array] = []
	var seen: Dictionary[int, bool] = {}
	for racer: Racer in racers:
		if racer == null or not racer.visible:
			continue
		var id: int = racer.get_instance_id()
		seen[id] = true
		var s: RacerState = racer.view_state()
		var wade: float = wade_at(surface, s.position)
		var splash: WaterSplash = _splashes.get(id)
		if wade < MIN_WADE:
			_wading[id] = false
			if splash != null:
				splash.stop()
			continue
		var at := Vector3(s.position.x,
			surface.height_at(s.position.x, s.position.z)
			+ surface.water_depth_at(s.position.x, s.position.z), s.position.z)
		var speed: float = Vector2(s.velocity.x, s.velocity.z).length()
		_drop_rings(id, at, wade, speed)
		if splash == null:
			splash = WaterSplash.new(_droplet, _puff)
			splash.name = "Splash_%d" % id
			splash.top_level = true
			add_child(splash)
			splash.set_color(particle_color)
			_splashes[id] = splash
		splash.update(at, s.velocity, wade)
		wading.push_back([at.distance_squared_to(camera), at, s.velocity, wade])
	# Racers gone from the hill — a peer who left, an opponent the menu
	# removed — take their splash with them.
	for id: int in _splashes.keys():
		if not seen.has(id):
			_splashes[id].queue_free()
			_splashes.erase(id)
			_last_drop.erase(id)
			_wading.erase(id)

	wading.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var bodies: PackedVector4Array = _empty_bodies()
	var wade_v := Vector4.ZERO
	for k: int in mini(wading.size(), MAX_BODIES):
		var at: Vector3 = wading[k][1]
		var v: Vector3 = wading[k][2]
		bodies[k] = Vector4(at.x, at.z, v.x, v.z)
		wade_v[k] = wading[k][3]
	material.set_shader_parameter("bodies", bodies)
	material.set_shader_parameter("body_wade", wade_v)
	_push_drops()

## Lay a ring wherever [param id] has run [method _spacing] since its last
## one, and a harder one where it first hits the water.
func _drop_rings(id: int, at: Vector3, wade: float, speed: float) -> void:
	var was: bool = _wading.get(id, false)
	_wading[id] = true
	var strength: float = wade * clampf(speed / 8.0, 0.3, 1.6)
	if not was:
		_add_drop(at, minf(strength * 1.8, 2.5))
		_last_drop[id] = at
		return
	var last: Vector3 = _last_drop.get(id, at)
	var spacing: float = DROP_SPACING_MIN + DROP_SPACING_PER_SPEED * speed
	if Vector2(at.x - last.x, at.z - last.z).length() >= spacing:
		_add_drop(at, strength)
		_last_drop[id] = at

func _add_drop(at: Vector3, strength: float) -> void:
	_drops[_next_drop] = Vector4(at.x, at.z, _time, strength)
	_next_drop = (_next_drop + 1) % MAX_DROPS

func _push_drops() -> void:
	# A copy: a packed array handed to a material aliases the caller's
	# (the trap list).
	material.set_shader_parameter("drops", _drops.duplicate())

func _empty_bodies() -> PackedVector4Array:
	var out := PackedVector4Array()
	out.resize(MAX_BODIES)
	out.fill(Vector4.ZERO)
	return out

## Forget every wake and splash: a restart's water is still.
func reset() -> void:
	_drops.fill(Vector4.ZERO)
	_next_drop = 0
	_last_drop.clear()
	_wading.clear()
	for splash: WaterSplash in _splashes.values():
		splash.stop()
	if material != null:
		_push_drops()
		material.set_shader_parameter("bodies", _empty_bodies())
		material.set_shader_parameter("body_wade", Vector4.ZERO)
