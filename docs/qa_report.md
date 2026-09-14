# QA report — Ashford Green (rebuild, branch `chore/rebuild-world-json`)

> **Coordinator remediation (after this report, re-proven on the shipped export):**
> P1-1 streaming hitch — 11 near-identical library variants consolidated in `tools/world_layout.json`
> (49 -> 37 distinct GLBs); verify.mjs worst frame 1817 ms -> 300 ms. P1-2 unlit interiors — every Mason
> record now carries `openings: []` + `interior`/`floors`/`floor_height`, so the engine hangs its pinned room
> lights (night interior mid-frame luma 38 -> 81 in the targeted probe). Polish 1 (house_b door clamp) fixed
> (`pos` 9.15 -> 8.95). Polish 3-5, 7, 8 are engine/Mason-owned and are listed in the PR body as follow-ups.

**VERDICT: PASS — 0 P0, 2 P1, 9 polish**

Export tested: `/workspace/repo/out` (served locally, wasm MIME, CDN proxy for `/godot-assets`). The deployed
preview at `https://preview.myapping.com/cloud-ahdwaq6ir1exe3c168f9/` serves the **identical** `world.json`
(md5 `50a07558…`) and an `index.pck` of the same size (5 108 448 B), so results transfer.

How it was driven (all scripts/frames in `/tmp/qa/`):
- **Web (real export, headless Chromium + SwiftShader)** — `run1..run6.mjs` + `lib.mjs`: title button click,
  real key input (WASD), right-half mouse drag for the orbit, `window.gogiBoard()` (= `interaction.try_use`,
  the USE path), `gogiSolids()` leaf AABBs, screenshots (`/tmp/qa/*.png`). Portrait 400×860 and landscape
  860×400 (`run4`), 800×500/900×600 for gameplay.
- **Native headless (60 Hz physics, no renderer)** — `/tmp/qa/native/*.gd` run the REAL `main.tscn` against the
  same export (`--world-url http://localhost:5310/world.json --mode=explore`) and drive `main.move_vec` (the
  joystick vector) + `interaction.try_use()`. Used wherever the software-GL frame rate (1–4 fps) made web physics
  unreliable (stairs, door-block from inside, house doors, boundary, sky cycle timing, quest chain). Logs:
  `native/native2.log`, `native/native_sky.log`, `native/native_quest.log`.
- **Headless Godot renders of the raw assets** (`gproj/render.gd`, `gproj/anim.gd`) to separate asset defects
  from engine/lighting ones (`glb-*.png`, `anim-*.png`).
- Static: `world.json` vs `structures.json` door/leaf geometry for all 20 doors; engine source read-through
  (`interaction.gd`, `chunk_manager.gd`, `weather3d.gd`, `surfaces.gd`, `main.gd`).

---

## ❌ P0 ship-blockers
None found.

## ❗ P1 must-fix

### P1-1 · Streaming hitch: a 1 817 ms frame while walking into fresh cells (device-independent) — DATA + ENGINE
- Evidence: `/tmp/verify.log` `FEEL perf: … worst frame 1817ms (REAL — device-independent)` on this exact export;
  the same log flags `world references 47 distinct GLB assets — over the 32-entry streaming cache` (I count 49
  distinct URLs in `world.json`: 6 Meshy + 7 Mason + 36 library props).
- Why it matters: per the QA contract a >250 ms worst frame is real synchronous work, not a container artifact —
  it stalls a phone the same way (a visible hitch every time a new cell ring loads).
- Data fix direction (`tools/world_layout.json` → `world.json`): cut the distinct library set below 32 — the
  outer ring uses many one-off variants (`q_unature` CommonTree_1/3, PineTree_2/4, BirchTree_2, Bush_1/2,
  BushBerries_1, Rock_3/Rock_Moss_1/2, Flowers/Grass/Wheat/Grass_Common_Tall, `q_farmbuild` Fence/OpenBarn/
  SmallBarn/Windmill, `mega_medieval` fence vs `q_farmbuild` fence …). Reuse ~2 trees, 1 bush, 1 rock, 1 fence
  across cells. Engine side (template-owned, not fixable here): the per-cell build slice.

### P1-2 · No light sources at night: interiors are unlit, street lamps and windows never glow — DATA (+ engine gap)
- Evidence (deterministic `gogiSetTime("night")`/`"day"` frames, not wall-clock):
  - `45-hall-inside-night.png` — hall interior at night: only the moonlit floor reads (mid-frame luma 38, 16 %
    near-black); walls/ceiling/stair are black masses. By day the interior walls and ceiling read as **flat
    uniform grey** (`20-hall-look-west.png`, `21-hall-look-east.png`, `44-hall-look-up-day.png`) — the GSurf
    normal relief only shows where sunlight enters a window.
  - `32-night.png`, `43-spawn-night.png` — the square at night: the 8 `Prop_Lamp_Street` posts are black
    silhouettes, hall windows dark. Night IS moonlit-readable (mid luma 24–26, <2 % near-black) so this is not a
    P0, but a medieval town at night with no lamp/candle glow reads unfinished.
- Root cause (read in `chunk_manager.gd:1831-1837, 2338-2372`): `_mason_fittings()` — the code that adds
  `GBuild._room_light` per storey — only runs when the placement record has an `"openings"` key AND an
  `"interior"` key. The `--wire` output carries neither (records have `url,pos,rot,collider,footprint` only),
  so every Mason building ships with **zero interior lights**. Library lamp props have no engine light hook.
- Data fix direction (`tools/build_town.py --wire`): emit on every Mason record
  `"openings": [], "interior": {"floor_z": 0.06}, "floors": <n>, "floor_height": <h>` — the **empty**
  `openings` array keeps the engine from hanging a duplicate `MasonDoor` leaf next to the `doors[]` leaf, while
  the `interior` dict turns on the pinned room lights (1/storey, max 2). For street lamps: the only engine
  light primitive reachable from data is a `structures[]` entry with `sign_light` (geometry.md) — a small
  parametric lantern post with `sign_light:{color:[1,0.8,0.5],energy:2,range:9}` at the 4 square lamp
  positions would give the square a night pool; otherwise note it as an engine gap.

## ⚠️ Polish

1. **house_b door in cell [-1,1] is clamped 0.15 m off its doorway** — DATA. `doors[].pos` is `[9.15, -3.6]`;
   the engine clamps door pos to ±(half−1) = ±9 (`chunk_manager.gd:1201`), so the leaf AABB is
   x −3.30..−1.00 (native + web reads) against a doorway at x −3.15..−0.85 → 15 cm sliver at the hinge jamb,
   15 cm buried in the wall on the other side. Still blocks/opens correctly (native: blocked at z 26.90,
   opened, walked in to z 20.9). Fix: keep every door pos within ±9 — e.g. move house_b in that cell from
   x 6.0 to ≤ 5.85 in `tools/world_layout.json` (all other 19 doors are inside the clamp; static check of all
   20 leaves vs `structures.json` openings: 20/20 centred within the 0.2 m wall-mid offset).
2. **Door leaf renders as a black slab in shadow** — DATA/ENGINE. Sunrise from outside (`10-hall-door-closed.png`)
   and night from inside (`25-door-closed-inside.png`) the timber leaf (GSurf `timber` 0.30/0.20/0.12, no direct
   light) is a black rectangle in the doorway; by day it reads as brown timber (`11-hall-door-open.png`).
   Cheap data mitigation: `doors[].material: "wood"` (lighter preset) — real fix is P1-2's interior light.
3. **HUD text stacks overlap** — ENGINE (`game_shell` toast vs quest tracker vs `interaction` dialogue box).
   `12-hall-inside.png` shows three text layers at once at the top: "The door swings open." panel, the
   into_hall toast, and the QUEST tracker all overlapping; `26-steward.png` the q_town toast over the tracker.
4. **Hero spawns facing the camera** — ENGINE. At spawn the traveler faces +Z (toward the north-looking camera,
   face visible in `30-portrait.png`/`31-portrait-later.png`) until the first movement input turns him.
5. **Drawn Rusty Sword in a peaceful town** — ENGINE default (`rpg_systems.gd` starting item) with the ATTACK
   button hidden by the director but the SHEATHE button left. Reads odd walking into a town hall with a bare
   blade; no data knob found to start sheathed/unarmed.
6. **`villager_man` idle is an arms-spread "shrug" pose** — DATA (Meshy asset). Headless render of the clip at
   t=0/1.5/4/8 s (`anim-villager_man-idle-*.png`) barely changes and holds the arms out; at gameplay distance it
   reads like an A-pose (`42-spawn-look-up-sky.png`, `40-spawn-look-east-day.png`). The rig DOES animate
   (walk clip moves, `anim-villager_man-walk-*.png`), so not a dead T-pose — but a regenerated idle (arms down)
   would help since this model is 2/3 of every `populate` crowd.
7. **Interior plinth ledge is climbable** — Mason compile (out of this rebuild's scope). Pressing into an interior
   wall step-up-assists the player onto the plinth band: native run y=0.62 at the hall north wall, y=0.47 inside
   house_b/house_d (plinth `top_z` 0.6/0.45). Visible pop-up when brushing walls.
8. **Engine GSurf override discards the compiled textures** — ENGINE observation. The Mason GLBs carry baked
   ashlar/brick course textures (see my raw render `glb-outside_sw.png`, `glb-montage.png`); in-game
   `_mason_materials()` replaces them with uniform noise-relief `stone/plaster/brick/timber/slate`. Facades
   still read as textured relief (`10-`, `11-`), but the course pattern is lost.
9. **Streets are undifferentiated cobble** (verify WARN `NO roads[]`) and the sunset tint is heavily saturated
   (`34-sunset.png`, `35-landscape.png`). Acceptable for a village square; optional lanes via `roads[]`.

---

## ✅ Verified working (evidence)

| Check | Result | Evidence |
|---|---|---|
| Boot, canvas, engine | ✅ | `Godot Engine v4.7.1` banner in all 6 web runs; canvas present; `GOGI_WORLD_BOUNDS x=-60..80 z=-60..80` |
| Console clean | ✅ | 0 × `SCRIPT ERROR / Parse Error / GOGI_PLACEHOLDER / GOGI_RULES_UNIMPL / pageerror` across `run1-6-console.log` (1 173 lines) and 4 native runs. Only sandbox noise: `ERR_CERT_AUTHORITY_INVALID` + `Failed to fetch` on the `npc.myapping.com` speech/brain fetch |
| Hall door leaf sized + placed | ✅ | closed leaf AABB `x 8.85..11.15, y 0..3.10, z 14.18..14.36` (=2.3×3.1, hinge at 11.15, mid-wall) — web `run3`, native |
| Closed leaf blocks | ✅ | walking north at x=10 stops at **z=14.77** (web run2/run3/run6 and native), i.e. leaf z 14.18 + 0.18 + capsule 0.4 |
| USE opens, stays open | ✅ | leaf AABB → `x 11.06..11.44, z 14.27..16.57` (swung ~95° outward); still open after 3 s, still open after dismissing "The door swings open." with USE (`run3`); collider `disabled=true` (native) |
| Walk in → `into_hall` | ✅ | `GOGI_RULE_FIRED into_hall on=enter_zone` at z<14 (web ×4, native ×3); toast shown (`12-hall-inside.png`) |
| Toggle close from inside | ✅ | USE at (10.5, 11.8) → leaf back to `x 8.85..11.15` with `open=false disabled=false`; pushing out stops at **z=13.78** (web run3 + native); USE re-opens (mid-swing AABB `x 9.39..11.21 z 14.21..15.9` captured) |
| Stairs → council chamber, no jump | ✅ | native 60 Hz: from (5.5, 0, 7.0) pushing +Z → `(5.50, 3.61, 12.91)` in 1.4 s, `GOGI_RULE_FIRED upstairs`; upper slab walk east → `(15.14, 3.61, 13.01)`. (Web runs stalled mid-flight at y 0.3–3.15 = software-GL physics artifact, not geometry; `upstairs` still fired in web run3.) |
| House doors ([-1,1] house_b, [1,1] house_d) | ✅ | house_d leaf `x 23.35..25.65 z 33.51..33.69` exactly on its doorway; blocks at z=33.11; USE → `x 23.06..23.44 z 31.30..33.61`; walked in to z=40.6. house_b: blocks at z=26.90, USE → `x -1.09..-0.71 z 26.39..28.70`, walked in to z=20.9 (see polish 1 for its 0.15 m clamp) |
| All 20 doors centred on their doorway | ✅ | static: leaf centre vs `structures.json` door opening (with `centre` offsets for house_b/tavern) — 20/20 within 0.25 m (0.2 m = mid-wall depth) |
| Sky cycle runs + loops | ✅ | native `weather.time_state` transitions: `sunrise@0.7s → day/cloudy@25.7s → sunset@115.7s → night@140.7s → sunrise@200.7s` (25/90/25/60 s as authored, `loop:true`); `sun_energy` lerps 0.9→0.71→0.85→0.38→0.87. Web frames across a session agree: warm sunrise (`10-`), grey day (`11-`, `33-`), orange sunset (`14-`, `34-`), starry night (`22-`), day again (`23-`) |
| Night readable / day not blown out | ✅ | `32-night.png` mid luma 24.6, 1 % near-black; `43-spawn-night.png` 26.3 / 2 %; day `33-day.png` luma 116, verify clipped 0.0–0.1 % |
| Mason materials on buildings | ✅ | facades textured relief stone/plaster/brick/timber + slate roofs (`10-`, `11-`, `27-house-b-inside.png`, `40-`, `41-`); roofs and trims distinct; no flat single-colour exteriors, no default-grey primitives |
| Far ring skyline | ✅ | from the square, roofs of cells 2 away are visible on the horizon east and west (`40-spawn-look-east-day.png`, `41-spawn-look-west-day.png`) — buildings render as real geometry to radius 4, not popping at the ring edge |
| World richness / density | ✅ | 7×7 cells (140 m), 21 Mason buildings (hall/tavern/chapel/18 houses) around a cobbled square with well, stalls, carts, benches, lamps, fences, trees, wandering crowds + 4 named NPCs; fields/orchards/pastures with barns + windmill in the outer ring (`02-walk-W.png`, `40-`, `41-`, `35-landscape.png`). Reads as a small town, not a diorama |
| Ground | ✅ | `cobble` preset (textured, not flat colour) + paving `rows`; fields green |
| Hero facing | ✅ | W → back/hood/pack visible (`crop-W-hero.png`); S → face + shirt front (`crop-S-hero.png`); W moved z 30→20.45, S back to 33.45 |
| Camera orbit | ✅ | right-half drag: `cam_yaw 0.00 → 1.16`; pitch clamps (look-up frames `42-`, `44-` show horizon/ceiling, never floor-stare) |
| Feet on floor | ✅ | `foot_raw` 0.035–0.038, `GOGI_HERO_SEAT 0.011`; boots on ground in `26-steward.png`, `40-` |
| Real sky | ✅ | Weather3D time-of-day sky (blue day, starry night `22-hall-look-up.png`); no grey ceiling outdoors (`42-spawn-look-up-sky.png`) |
| Characters Meshy + textured | ✅ | all 6 characters from `models/meshy/*.glb` (1 image, 1 textured material, 24-joint skin, idle/walk/run each; traveler +jump); market woman/steward/traveler clearly textured in frames; no KayKit fallback (the `kk_rig_medium_*` GLBs are the engine's animation libraries, unreferenced by world.json) |
| Clip resolution | ✅ | every referenced clip exists (`anim.gd`: `["idle","run","walk"]` ×5, traveler `+jump`); hero `clip=idle/run` in `gogiGetPlayer`; walk clips move the legs (`anim-*-walk-*.png`) |
| Quest chain | ✅ | web run3: steward talk → `steward_met`, q_hall complete → `GOGI_CHAIN advanced to 1/2` + "Meet the townsfolk" toast. Native: blacksmith → greta → guard talks → q_town `status:"done"` → `GOGI_CHAIN advanced to 2/2` |
| Rules | ✅ | `hud_trim` on start (stats/health/minimap hidden), `into_hall`, `upstairs`, `steward_met` all fired through real paths; no `quiet_door_*` regression (door never auto-shut) |
| Mobile fill portrait 400×860 | ✅ | canvas 400×860 = window; corners tl/tr sky, bl/br ground (no black bars); `GOGI_HUD_GRID vp 720x1548 win 400x860 … rows 1064/1212/1360` — 3 button rows inside; joystick half free (`30-`, `31-portrait-later.png`) |
| Mobile fill landscape 860×400 | ✅ | live resize re-laid out: `vp 1548x720 win 860x400 scale 1.78 … rows 345/457/568`; canvas fills; corners rendered (`35-landscape.png`) |
| Input-binding sanity | ✅ | no `[input]` actions; move = W/A/S/D/arrows + left-half touch, look = right-half drag / mouse-LMB drag guarded by touch indices, USE = E/button, jump = Space/button; ATTACK button hidden by director; no fire on look/move possible |
| World boundary | ✅ | native: walking west from x=−52 stops at **x=−59.1** (`_clamp_to_world`, grid −60..80); 6 resident cells at the edge, world persists |
| Winnability / native tier | ✅ | verify `quest-graph OK — world is winnable (49 areas)`; `manifest.json` `webOnly:false` |
| Audio presence (static) | ✅ | `AudioManager` + `default_bus_layout.tres`; `play_sfx("door"/"ui"/"pickup")` on USE/door/rule; music `calm_town`, ambients `town_crowd`/`forest_birds` per region; 16 files in `out/audio` |
| Engine currency / pck | ✅ | verify: 70/70 template files current; pck 5.1 MB; peak GPU mem 80 MB / 220 budget |

Notes on verify WARNs I checked and consider non-defects: `FEEL collision … INSIDE a solid AABB at [10,20.3]` — that AABB is the cell ground box `[0,-1,20]..[20,0,40]` (y ≤ 0), the player stands on its top face → probe false-positive, not a missing collider. `frames identical` — title screen. `3/4 rules did not fire` — they are gated behind walking into the hall/stairs/steward; all three fired under my drive.

Sandbox timing (not defects): under software GL the resident cells finish ~10–20 s after ENTER — `30-portrait.png` taken ~10 s in shows the bare cobble plane before the hall/props exist; every `ReadPixels` screenshot stalls the engine several seconds; web physics at 1–4 fps stalls on stairs. All stair/door/boundary/cycle conclusions above therefore rest on the 60 Hz native runs plus web state deltas, not on timed screenshots.

## Could not verify (sandbox limits)
- Real audio/music/SFX playback and NPC TTS — the container mutes audio and `npc.myapping.com` is cert-blocked
  (`Failed to fetch`). Side-observation: while a speech request is pending (8 s timeout here) USE on **another**
  NPC is ignored (`interaction.try_use` `_speaking` gate) — on device that window is the spoken line's length.
- True-GPU fidelity (bloom, exact colours, shadow softness), touch feel, real phone frame pacing.
- The Supabase/`wss` path (no multiplayer config in this world).
- On-device time-to-first-cell after ENTER (coordinator states a few frames; here 10–20 s).
