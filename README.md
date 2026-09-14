# Ashford Green — a small medieval town you can walk around in

A data-driven Godot 4.7.1 game built on the Gogi rpg streaming template (chunk mode). The whole
town is `world.json`; the engine scripts are the unmodified template, so the game streams natively
into the Gogi player and also runs in any phone browser (Compatibility renderer, `nothreads` web export).

## What's in the town

- **Town hall** (centre of the square) — a Mason-compiled B-rep building: a hinged front door you open
  with USE, a hollow two-storey interior, a real stair flight along the east wall to the council chamber
  on the second floor, and every window is a true hole in the wall you can see through.
- **Houses** (four variants), a **tavern** with its own stair, and a **chapel** — all with real window
  openings and hollow interiors; the houses have openable doors too.
- Market stalls, a well, carts, lamps, benches, fences, fields, orchards and a windmill on the outskirts.
- Wandering townsfolk plus four named NPCs you can talk to (steward, blacksmith, market seller, gate guard).
- A two-stage quest chain (speak to the steward, climb to the council chamber; then meet the townsfolk).

## Layout of the repo

| path | what |
|---|---|
| `world.json`, `quests.json` | the game (generated — do not hand-edit `world.json`, edit the sources below) |
| `tools/world_layout.json` | the Architect's macro layout (cells, buildings as `MASON:<type>` placeholders, props, crowds) |
| `tools/gameplay.json` | sky, director/title, regions, zones, rules merged into `world.json` |
| `structures.json` | Mason specs for the seven enterable buildings (openings, stairs, mouldings) |
| `tools/build_town.py` | compiles `structures.json` with Mason → `models/town/*.glb`, hangs door leaves, writes `world.json` |
| `tools/pp.mjs` | post-processes a Mason GLB (drops the collision shell, applies the palette, joins primitives) |
| `models/town/` | compiled buildings (streamed at runtime, not packed) |
| `models/meshy/` | rigged Meshy characters: player, steward, blacksmith, market woman, guard, villager |
| `audio/` | CC0 music + ambient beds |
| `*.gd`, `main.tscn`, `project.godot`, `export_presets.cfg` | the engine (template-owned, unmodified) |

## Rebuilding

`world.json` is generated — after editing `tools/gameplay.json` (sky, rules, director) or
`tools/world_layout.json` (placements) it must be regenerated, or the deployed game keeps the old data:

```bash
BUILD_ID=<this build's id> python3 tools/build_town.py --wire   # regenerate world.json only (buildings already compiled)
godot --headless --path . --import
godot --headless --path . --export-release "Web" out/index.html
cp world.json quests.json out/ && cp -R models audio out/
```

To recompile the buildings as well (after a `structures.json` change):

```bash
curl -sfL https://preview.myapping.com/mason/run.sh -o /tmp/run.sh && bash /tmp/run.sh install
BUILD_ID=<this build's id> python3 tools/build_town.py            # compile buildings + regenerate world.json
```

The wiring step gives every building record a `footprint` (the engine textures the `body_/roof_/trim_`
solids with its GSurf surfaces and draws the buildings across the far ring) and every front doorway a
hinged `doors[]` leaf sized to the opening (`w`/`h`), hinge half a doorway from the opening's centre.

Controls: left half of the screen = move joystick, right half = drag to look, USE to open doors and talk.
Keyboard: WASD / arrows, E for USE, Space to jump.
