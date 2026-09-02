## One terrain material: gameplay parameters migrated verbatim from ETR's
## `data/terrains/terrains.lst`, plus the shading parameters the original never
## had — it drew every terrain as flat textured diffuse.
##
## Up to 8 layers per course (2 RGBA splat textures). Surveyed ETR courses use
## 3–8 distinct terrain types, so the cap is not binding in practice — and it
## fixes the original's worst rendering bug, which re-rendered the whole terrain
## once per terrain type present (etracer.md §4.3).
@tool
class_name TerrainLayer
extends Resource

@export var id: StringName = &""

@export_group("Gameplay")
## 0.2 ice .. 0.7 rock. Migrated from `[friction]`.
@export_range(0.0, 1.0, 0.01) var friction: float = 0.35
## Metres the point mass sinks before the terrain spring engages. `[depth]`.
@export_range(0.0, 0.3, 0.001) var compression_depth: float = 0.05
## Whether carving throws up snow spray. `[part]`.
@export var emits_particles: bool = true
## Whether the surface deforms and holds a trench. `[trackmarks]`.
@export var takes_trackmarks: bool = true
## The looping slide effect this terrain plays under the player, named against
## [SoundBank]. ETR `[sound]`, which is a cue name there too — `TerrList[i].sound`
## is `Sound.GetSoundIdx` of it, resolved once at course load.
##
## Empty for 12 of the 43 records, including `snow` itself: the original rides
## the commonest surface in the game in silence, and only `dirty_snow` ever
## reaches `snow_sound`. `ice2` is silent while `ice1` is not. Migrated as it
## stands — it is one string per terrain to change, and inventing the missing
## ones is a design decision, not a port.
@export var slide_sound: StringName = &""

@export_group("Rendering")
## The only per-layer [b]texture[/b] the terrain shader has, and the only one it
## can have. WebGL2 guarantees 16 fragment texture units and `terrain.gdshader`
## already binds 13 — two splat maps, eight albedos, the trail map, the detail
## map and the sparkle noise. A per-layer normal or roughness map would need
## eight more units each, so neither is implementable under Compatibility; both
## used to be declared here as unread `Texture2D` slots that silently did
## nothing when assigned. Relief comes from the shared procedural detail field
## instead, and roughness from [member roughness] below.
@export var albedo: Texture2D
## Surface roughness, blended across layers into the shader's `layer_roughness`
## table. ETR has no equivalent — its terrain is flat textured diffuse — so this
## is authored here rather than migrated: the importer seeds it from
## [method is_ice] (0.25 for ice, 0.85 for everything else), which is exactly
## the split the renderer used to hardcode.
@export_range(0.0, 1.0, 0.01) var roughness: float = 0.85
## World units per texture repeat, per layer. ETR generated UVs at 1/6 world
## scale for the whole course; the shader keeps a table so a coarse rock can
## tile at a different rate from the snow beside it.
@export var uv_scale: float = 6.0
## Snow deforms; rock does not.
@export var is_deformable: bool = true
## Migrated `[shiny]` flag — drives the specular/sparkle term.
@export var shiny: bool = false
## Original RGB colour key from terrain.png, kept for re-import diffing only.
##
## This, not [member id], is what identifies a terrain in the original: a course
## paints colours and `CCourse::GetTerrainIdx` resolves them within ±30.
@export var legacy_color: Color = Color.MAGENTA
## The `[name]` this record carries in `terrains.lst`. Differs from [member id]
## only where the file declares one name twice — `pave04`, three times — which
## is legal there because nothing looks a terrain up by name.
@export var legacy_name: StringName = &""
## Position of the record in `terrains.lst`, which is the original's real terrain
## index (`TerrList[i]`). Kept for re-import diffing; nothing here indexes by it.
@export var legacy_index: int = -1

@export_group("Provenance")
## Hash of everything above, as the importer last wrote it. See
## [method fingerprint].
@export var import_fingerprint: String = ""

## Hash of the authored fields, for detecting an edit the importer did not make.
##
## Nothing in Godot reliably tells a resource "a human just changed you":
## `_set` is never called for script-declared exports, a property setter cannot
## distinguish an Inspector edit from a `.tres` being loaded, and this project
## has no `EditorPlugin`. So provenance runs the other way round — the importer
## records what it wrote in [member import_fingerprint], and on the way back in
## compares this against it. A mismatch means something other than the importer
## changed the file, and re-import leaves it alone without `--force`.
##
## Deliberately excludes [member import_fingerprint] itself, and deliberately
## includes everything else: a layer whose friction *or* whose albedo path was
## edited is equally a layer somebody meant to keep.
##
## Comparing the file against a freshly imported record instead would need no
## stored field, but it cannot tell an edit from a change to the importer's own
## migration logic — every improvement to `import_terrains` would make all 43
## layers look hand-edited. The stored hash separates the two cases.
func fingerprint() -> String:
	return "|".join([
		String(id),
		"%.6f" % friction,
		"%.6f" % compression_depth,
		str(emits_particles),
		str(takes_trackmarks),
		String(slide_sound),
		albedo.resource_path if albedo != null else "",
		"%.6f" % roughness,
		"%.6f" % uv_scale,
		str(is_deformable),
		str(shiny),
		str(legacy_color),
		String(legacy_name),
		str(legacy_index),
	]).sha256_text()

## Whether this resource still holds what the importer wrote.
##
## An empty fingerprint is unknown provenance — a layer written before the field
## existed — and counts as unedited, so the first re-import adopts it rather
## than refusing to touch the whole library.
func edited_since_import() -> bool:
	return not import_fingerprint.is_empty() and fingerprint() != import_fingerprint

## Whether this layer should be shaded as ice rather than as snow or rock.
##
## ETR has no such flag: `[shiny]` is the closest thing, but the data only sets
## it on three of the seven ice terrains — `ice1`, `ice2` and `greenice`.
## `hockey_ice`, `snowy_ice`, `snowy_greenice` and `snowy_hockey_ice` are ice by
## every other measure and ship without it, so the friction clause is carrying
## the majority of the set, not a pair of stragglers. It works because ETR gives
## all seven `[friction] 0.2` and the next lowest terrain in the file is 0.3.
## `icy_pave`/`icy_grass03` sit at 0.4 and are correctly excluded — they are
## frozen ground, not a frozen surface.
func is_ice() -> bool:
	return shiny or (friction <= 0.25 and not is_deformable)
