# Godot RPG Streaming Starter (`godot-tmpl-rpg`)

**The base for every 3D game.** Not only multi-area worlds — a single-area game belongs here too.
The flat `godot-templates/3d` base has no `world.json`, and the verifier hard-fails a 3D build
without one as NOT NATIVE-PLAYABLE, because the iOS player has nothing to stream into its bundled
engine. Reach for `3d/` only as the source of the shared modules it shares with this one.

Render config is Compatibility / WebGL2 / `nothreads` / 720×1280 portrait, identical to `3d/` and
asserted by `check-template-render-parity.mjs`.

## The one idea

The exported `.pck` binds **only scripts and shaders**. `world.json` and `quests.json` are served
**loose** next to `index.html`, and every model streams from R2 at runtime. That split is why:

- a chat edit can rewrite an entire game with **no re-export** — `main.gd` re-polls `world.json`
  every ~4s and hot-reloads it;
- **one** iOS binary plays every game the agent builds;
- a generated game is *content*, not software.

Anything that bakes game content into the engine breaks all three at once.

## Two streaming modes, one façade

`world.mode` picks, and nothing else changes:

| | `"chunk"` | anything else (default) |
|---|---|---|
| driver | `chunk_manager.gd` | `scene_manager.gd` |
| shape | resident RING of cells around the player, 4 outward LOD tiers | exactly ONE area resident |
| data key | `cells: [{cell: [gx,gz], …}]` | `areas: [{id, …}]` |
| for | open worlds, terrain, roads, traffic, weather | dungeons, rooms joined by seams |

A hot-reload poll is **discarded** unless the incoming body carries the key for its mode — a chunk
world must still have `cells`, a zone world `areas`. That is deliberate: a truncated or wrong-shaped
fetch must not blank the world.

## Behaviour is data too

`rules.gd` is a when/if/then interpreter: **36 events, 62 actions, 20 conditions**. Timers, score,
waves, phases, win conditions and the HUD are `world.json` entries, not code. `game_shell.gd` is the
shared director that renders a `director` block.

**The engine is the source of truth for that vocabulary**, and the failure modes are asymmetric —
which is why `functions/scripts/check-rule-vocab.mjs` exists:

- a dead **action** hits `_unimpl` and prints `GOGI_RULES_UNIMPL` — there is a trace;
- a dead **event** is **silent**: the rule parses, registers, and waits forever for a message
  nothing sends;
- a dead **condition** **fails open** — an unknown key returns `true`, so its rule fires
  unconditionally.

Docs and the verifier may name FEWER names than the engine implements. They may never name more.

## The modules

35 `.gd` + 3 `.gdshader`. Grouped by what they do:

| group | files |
|---|---|
| **boot / orchestration** | `main.gd` (3.8k lines — fetches world+quests+manifest, wires everything, owns the player, HUD and the hot-reload poll) |
| **streaming** | `chunk_manager.gd` (3.0k), `scene_manager.gd`, `area_builder.gd` (streams a `.glb` via `GLTFDocument.append_from_buffer`, shared cache, named-prop `PALETTE`) |
| **world building** | `terrain.gd`, `surfaces.gd`, `shapes.gd`, `layout.gd`, `building.gd`, `build_structure.gd`, `water.gd`, `weather3d.gd`, `traffic.gd`, `cast.gd`, `minimap.gd` |
| **behaviour layer** | `rules.gd`, `game_shell.gd`, `quest.gd`, `rpg_systems.gd`, `wander.gd` |
| **characters / combat** | `enemy.gd`, `equip.gd`, `projectile.gd`, `interaction.gd`, `anim_rig.gd`, `hero_anim.gd`, `pose.gd` |
| **vehicles** | `vehicle.gd` (2.5k — cars, boats, planes, tanks, mounts; reverse on every profile) |
| **multiplayer** | `netsync.gd`, `net.gd`, `peer_body.gd` |
| **platform** | `audio_manager.gd`, `save.gd`, `auth.gd`, `auth_gate.gd` |
| **shaders** | `water`, `lava`, `waterfall` |

### Autoloads, and why they are autoloads

`AudioManager`, `Net`, `Auth`, `Save`. All four exist because **a game cannot bring its own** —
the native player runs the engine that ships inside the app, so netcode, auth and persistence have
to already be there. Each is inert until a world asks: `Net` until a `multiplayer` block,
`Auth` until `"auth": true`, `Save` until a var is marked `persist` or building is enabled. A
single-player game with no saves pays nothing for any of them.

## Adding an engine module

Three consumers have to agree, and two of them are hand-maintained lists that have now drifted the
same way twice (`peer_body.gd`, then `hero_anim.gd` — which hard-failed **every** rpg 3D build):

1. `godot-templates/verify/verify.mjs` → `ENGINE_GD`
2. `godot-templates/tools/nettest/run.sh` → the copy list, if anything copied preloads it
3. `godot-templates/tools/engine-pack.sources.json` → self-corrects, it walks the directory

Do not verify this by hand. Run **`node functions/scripts/check-engine-modules.mjs`**, which walks
the real `preload` graph and fails naming the gap. It is in the predeploy chain and in the stager.

## Winnability is gated

`qgcheck` proves the goal is reachable through the lock-and-key graph over `world.json` +
`quests.json`. A FAIL (`UNREACHABLE_GOAL`, `CONSUMED_KEY_SOFTLOCK`, `UNSATISFIABLE_REQUIRE`) blocks
the build, and the same validator gates chat edits server-side — so an edit can never make a
shipped world unwinnable either. Fix the graph; the witness names the blocking token.

## Schema

Documented in full in the `world-streaming` playbook, fetched every session. In short: each area or
cell carries `ground`/`ambient`, `props`, `enemies`, `npc`, `chest`, and `seams` with a
`lock`/`requires` gate. `props[].kind` must be one of the `PALETTE` kinds in `area_builder.gd` — an
unknown kind renders nothing, silently.

## Shipping a change

```bash
node functions/scripts/zip-rpg-template.mjs     # or let the stager do it
node functions/scripts/stage-godot-r2.mjs       # runs every gate BEFORE zipping, then uploads
```

The stager is the single supported path: it re-zips from the tree so what ships is what is in the
tree, and it refuses to stage if qgcheck, render parity, cp-sync or the engine-module lists fail.

**A change here does NOT reach the iOS native player.** That runs `Gogi/Gogi/gogi-engine.pck`,
rebuilt only by `godot-templates/tools/export-engine-pack.sh` followed by an Xcode rebuild. Until
both happen the phone runs the old engine — and a rules-driven game streamed into a stale one
renders a world where nothing happens.
