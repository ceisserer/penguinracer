# Photographed prop materials — sources and licences

`props_albedo.png` (colour, roughness in alpha; six 1024² layers) and `props_normal.png` (OpenGL
normal maps; six 512² layers) are packed by `tools/pack_prop_materials.sh` from the 1k JPG maps
below. Every source is **CC0 1.0 (public domain dedication)**: no attribution is required, there is
no share-alike, and nothing conflicts with the project's GPL-2.0-or-later. The authors are named
anyway, because they did the work.

| Layer | Used for | Source | Author | Licence |
|---|---|---|---|---|
| 0 logs | log walls (`PropMesh.Surface.LOGS`) | [Wood Trunk Wall](https://polyhaven.com/a/wood_trunk_wall) (Poly Haven, `wood_trunk_wall`) | Amal Kumar | [CC0](https://polyhaven.com/license) |
| 1 boards | boards, shutters, decks, railings (`BOARDS`) | [Weathered Brown Planks](https://polyhaven.com/a/weathered_brown_planks) (Poly Haven, `weathered_brown_planks`) | Dimitrios Savva (photography), Rico Cilliers (processing) | [CC0](https://polyhaven.com/license) |
| 2 stone | rubble stone plinths and walls (`STONE`) | [Old Stone Wall](https://polyhaven.com/a/old_stone_wall) (Poly Haven, `old_stone_wall`) | Charlotte Baglioni | [CC0](https://polyhaven.com/license) |
| 3 shingles | wooden roof shingles (`SHINGLES`) | [Wood Siding 011](https://ambientcg.com/view?id=WoodSiding011) (ambientCG, `WoodSiding011`) | ambientCG (no individual author published) | [CC0](https://docs.ambientcg.com/license/) |
| 4 rock | boulders and stones (`ROCK`) | [Dark Rock 02](https://polyhaven.com/a/dark_rock_02) (Poly Haven, `dark_rock_02`) | Amal Kumar | [CC0](https://polyhaven.com/license) |
| 5 bark | logs, trunks and stumps (`BARK`) | [Pine Bark](https://polyhaven.com/a/pine_bark) (Poly Haven, `pine_bark`) | Dimitrios Savva | [CC0](https://polyhaven.com/license) |

WoodSiding011 ships no roughness map; the packer fills that layer with a constant 0.9.

Retrieved 2026-10-07. Adding a material: CC0 or CC-BY sources only (CC-BY needs its line here),
never "free for personal use" or anything without an explicit licence; append it to `SOURCES` in
the script, give it a row here, and see `object_prop.gdshader`'s `photo_surface` for the layer.
