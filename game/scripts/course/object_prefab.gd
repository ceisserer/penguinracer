## A placeable course object: tree, shrub, herring, flag, marker.
##
## Collision is an explicit cylinder proxy rather than the original's 8-face
## polyhedron tested against the character's sphere hierarchy — the same answer
## for a tenth of the work (§3.3).
@tool
class_name ObjectPrefab
extends Resource

@export var id: StringName = &""
@export var mesh: Mesh
@export var material: Material
## Blocks the player and costs speed on impact.
@export var collidable: bool = false
## Picked up on contact (herring).
@export var collectable: bool = false
## Purely decorative — start/finish banners and flags.
@export var decorative: bool = false
