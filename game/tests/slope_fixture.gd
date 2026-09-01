## Synthetic course fixtures for headless physics tests: a constant-angle slope
## with optional sinusoidal relief, built through the real [HeightmapSurface]
## so the tests exercise the production query path rather than a stub.
class_name SlopeFixture
extends RefCounted

static func flat_slope(angle_deg: float, width: float = 90.0, length: float = 500.0,
		friction: float = 0.35, depth: float = 0.05) -> HeightmapSurface:
	var nx: int = 64
	var ny: int = 256
	var heights := PackedFloat32Array()
	heights.resize(nx * ny)
	heights.fill(0.0)
	var s := HeightmapSurface.new()
	s.build(heights, Vector2i(nx, ny), Vector2(width, length), angle_deg)
	s.set_uniform_terrain(friction, depth, 0, true)
	return s

## Slope with a sine ripple across X and Z — exercises non-trivial normals,
## bilinear height and the airborne/landing path.
static func rolling_slope(angle_deg: float, amplitude: float = 1.5,
		width: float = 90.0, length: float = 500.0) -> HeightmapSurface:
	var nx: int = 64
	var ny: int = 256
	var heights := PackedFloat32Array()
	heights.resize(nx * ny)
	for y: int in ny:
		for x: int in nx:
			var u: float = float(x) / float(nx - 1)
			var v: float = float(y) / float(ny - 1)
			heights[y * nx + x] = amplitude * sin(u * TAU * 2.0) * cos(v * TAU * 6.0)
	var s := HeightmapSurface.new()
	s.build(heights, Vector2i(nx, ny), Vector2(width, length), angle_deg)
	s.set_uniform_terrain(0.35, 0.05, 0, true)
	return s
