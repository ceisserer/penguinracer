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
## Drawn as a 3D conifer by [Forest] rather than as [member mesh]'s crossed
## quads, which stay the fallback and the editor's picture. Set by the importer
## for the one conifer picture ETR ships, `snowy_tree1.png`.
@export var conifer: bool = false
## Drawn as a 3D leafless tree ([BareTreeMesh]) by [Forest], likewise. Set by
## the importer for ETR's bare-tree picture, `tree_barren2.png`.
@export var bare: bool = false
