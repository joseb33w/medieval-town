# QA report — Ashford Green (Godot 4.7.1 web export, chunk-mode `world.json`)

**VERDICT: PASS — 0 P0 ship-blockers, 5 P1 must-fix, 12 polish notes.**

The user's literal request is met on the deployed export: a walkable medieval town; the town-hall door is a real hinged leaf that blocks when shut and swings open on USE; you walk in, climb a real stair to a real second floor (quest step fires); every window is a genuine hole you can see (and ray-cast) through; 18 enterable houses + tavern + chapel surround the hall. What keeps it from a clean pass is a set of must-fix usability/art items below — none of them makes the request unmeetable or the game unplayable.

> **Build changed under test.** The coordinator re-generated the export while this QA was running (Mason GLBs + `world.json` 22:04–22:07 UTC: stairs widened 1.2→2.0 m / 1.1→1.8 m, steward moved, `hud_trim` + `quiet_door_*` + `steward_met` rules, title `"Ashford\nGreen"`, `attack` hidden, toast text fixed). Everything in this report was **re-verified on the final export** (`/tmp/qa/final*.log`, frames `/tmp/qa/A*.png`, `/tmp/qa/B*.png`, `verify.mjs` re-run → `/tmp/qa/verify_final.log`, PASSED). Findings that the 22:07 update already fixed are listed at the end as "fixed mid-QA" so they are not re-reported.

How I tested: my own Playwright drivers against `/workspace/out` served locally (Chromium + SwiftShader, 960×540 plus 400×860 / 860×400), reading real engine state via `window.gogiGetPlayer()`, `gogiSolids()`, `gogiBoard()` and the `GOGI_RULE_FIRED` console lines; a headless-Godot ray-cast probe over the compiled Mason GLBs (`/tmp/qa/geo_probe.gd`, `geo_stairs.gd`); static checks of all 20 door leaves vs their doorways. Scripts + logs + ~60 frames are in `/tmp/qa/`. Project untouched (nothing written under `/workspace` except this report).

---

## ❗ P1 — must fix (not ship-blocking)

### P1-1 Any ground-floor window can be jumped through — the door is optional
- **Repro (3×, incl. final build):** stand outside the hall at (6.5, 16.6) facing the south window (sill 1.3 m), hold W + one Space. Result: player passes through the opening and ends inside at (6.19, 0, 12.06) (`final.log:194`); earlier runs (13.5, 16.4)→(13.54, 0, 6.36) and (7.0, 15.07)→(6.44, 1.25, 5.96) — the last one landed *standing in* the far north window (`/tmp/qa/28-window-jump-mid.png` shows the hero already inside mid-jump). Walking without jumping is correctly blocked (z stays 14.9).
- **Why:** `architect_notes`/coordinator brief say sills at 1.3 m > 1.2 m step-up "so you cannot climb in" — but the jump (`JUMP_SPEED`) clears 1.3 m easily and the 1.2–1.3 m wide openings fit the 0.8 m capsule. Same applies to all 21 buildings (house_c's 0.75 m windows are the only ones too narrow).
- **Also:** upper-floor sills are 4.66 − 3.66 = **1.0 m above the slab (< 1.2 m step-up)**, so walking into an upstairs window pops the hero up *into* the opening (ends at y 4.61, z 5.96, standing in the wall — `hall3.log:128`, `/tmp/qa/25-upper-window-walkpush.png`). They don't fall out (head hits the 1.6 m window head), but it reads as a glitch.
- **Fix direction (data, `structures.json`):** raise ground-floor sills to ≥ 2.0 m *or* narrow windows to ≤ 0.75 m *or* add an invisible collider (glazing/bars) inside each opening (a thin box part with a transparent material keeps them see-through); raise upper sills to ≥ 1.25 m above the slab. If you decide window-hopping is a feature, downgrade this to polish but still fix the upper-sill pop-up.

### P1-2 Stair can only be mounted from its foot; the foot sits in a 1.1 m slot against the back wall
- **What works (final build, wider 2.0 m flight, world x 4.55–6.55, rises toward +Z):** from the slot between the north wall and the first step (z ≈ 6.4–6.6) the climb succeeds along the wall lane x=4.9/5.0, the centre x=5.55 and going *down* the open-edge lane x=6.45 (`final2.log:76,116,131`; `/tmp/qa/B1-upstairs-new-stair.png`). Upper slab swept at 7 points, no gaps.
- **What fails:** the flight's open (east) side is a wall — approaching from the room (the natural path from the door) at x≈7.1 pins the player at x=7.08, y bobbing 0/0.28, and **jumping does not help** (`final2.log:43`, A + 2×Space → still x=7.08). Grazing the edge with the capsule centre just past x=6.55 also stops dead (x=6.59, z=6.50, S does nothing — `final.log:94`). Before the widening the usable lane was ~0.5 m of a 1.2 m flight (`stairedge.log`: x=5.89 and x=4.85 both stuck at the foot) and the tavern flight hard-wedged the player under the well edge at (46.52, 1.99, 22.07) with **no sideways escape** (`houses.log:192`).
- **Why:** `main._step_up_assist` probes one ray at the capsule centre 0.6 m ahead; a 0.2 m riser under the capsule's *edge* is never lifted, so the side of the flight behaves like a wall; the foot is only 1.1 m from the north wall (flight 7.06–11.74, wall face 5.95), so lining up means walking past the stair into the corner slot and turning round.
- **Fix direction (data):** give the foot ≥ 2.5 m of clear floor (shift `stair.cy` toward the door, or flip the flight so it rises toward the back wall and the foot faces the entrance), keep the 2.0 m width, and/or add a low ramp/wedge collider along the open side so a sideways approach slides up onto the treads. Move the tavern chest (`[2,1] chest pos [-3.5,-6.5]` → world (46.5, 23.5)) out from under the tavern flight (45.55–47.35 × 20.0–24.4) — it is currently inside the stair.

### P1-3 Buildings and interiors are flat single-colour, untextured geometry
- **Evidence:** `models/town/*.glb` carry no textures/images — one `baseColorFactor` per part (`body:stone` 0.52/0.50/0.46, `roof:slate`, `trim:*`); nothing in the runtime maps those names to `GSurf` triplanar surfaces (grep `body:`/`mason` in `*.gd` → none). Frames: hall façade `/tmp/qa/06-pitch-up-sky.png`, `A3-after-use-at-door.png`; interiors `/tmp/qa/70-hall-interior-level-west.png`, `41-house_b-interior-lookback.png`, `B2-upstairs-far-corner.png` — bare monochrome rooms, no floor/ceiling material, no furniture (the "council chamber" is an empty slab; the tavern has no bar, no sign outside).
- **Judgement:** this is *not* the gray-box anti-pattern (plinth, courses, cornice, gables, arched windows, real openings, shadows all present), but against the "medieval town" ambition every wall reads as flat plaster-grey next to textured Quaternius/Meshy props and characters.
- **Fix direction:** bake triplanar stone/plaster/slate/timber textures into the Mason export (or post-map material names → `GSurf` presets in `tools/pp.mjs` / a loader hook), add a floor material distinct from the walls, and dress the hall/tavern interiors with a handful of props (council table + benches upstairs, bar/kegs in the tavern) and a hanging sign on the tavern.

### P1-4 NPC speech locks USE with no timeout
- **Evidence:** USE on the steward → prompt "Steward Aldric is speaking…" and `try_use()` early-returns while `_speaking` (`interaction.gd:302`). In this sandbox the TTS fetch never completed, so USE stayed dead for the rest of the session (screenshots every 8 s for 2 min, `/tmp/qa/31-steward-t0..t7.png`, all still "speaking"; a subsequent USE at the hall door did nothing, `hall2.log:24`). In production the endpoint answers, but 2 authored lines + a brain reply still mean ~10–20 s in which the game's *only* verb (the door) is dead, with no on-screen text.
- **Fix direction:** engine-owned (`HTTPRequest.timeout`, or don't gate USE on `_speaking`) — flag to the template owners; data mitigation now: one short line per NPC, and keep the `steward_met` toast (present in the final build) so the player gets text feedback.

### P1-5 A 1.45 s frame while walking into fresh cells (verify `FEEL perf`)
- **Evidence:** `/tmp/qa/verify_final.log:27` `worst frame 1450ms (REAL — device-independent)`; the coordinator's earlier run measured 233 ms, so it is intermittent. Likely suspects: inline trimesh bake of the Mason GLBs on web (`chunk_manager._add_mesh_collision`, 972-tri hall / 1176-tri chapel), the chapel yard's ~57 wall modules, and the 51-distinct-GLB working set over the 32-entry cache (verify WARN → re-download/re-parse hitches).
- **Fix direction:** reuse fewer distinct kit GLBs (trees/flowers/fences), keep ≤ 32 distinct models, and check the chapel cell's build is time-sliced.

---

## ⚠️ Polish (worth fixing, not blocking)

1. **Doors are open-once.** `interaction._nearest` skips a `kind=="door"` entry once `open` (`interaction.gd:391`), so USE at an open leaf does nothing — verified: leaf AABB identical before/after a second USE (`hall.log:100-102`). Answer to "does the door close/re-open?": **no**. Acceptable for the request; note it.
2. **Toast collides with the quest label.** `upstairs` toast draws across "QUEST: The Council Chamber…" (`/tmp/qa/B1-upstairs-new-stair.png`); q_town toast likewise (`B4-hud-after-quest.png`). Engine layout; shorten toasts or accept.
3. **Quest checkbox doesn't tick after talking** — `quest.notify_talk()` never emits `objective_changed` (`quest.gd:69-73`), so "[ ] Speak with Steward Aldric" stays unticked until the whole quest completes (`/tmp/qa/20-after-steward-talk.png`). Template bug; the `steward_met` toast now covers the feedback gap.
4. **Indoor camera hugs the ceiling.** The 8.5 m spring collapses against the 3.4 m ceiling/walls so interior frames are steep top-down or wall-filled with the hero hidden (`/tmp/qa/23-upstairs-look-south.png`, `24-upstairs-look-east.png`, `21-stair-from-foot.png`). Physics is fine (ray probe: spring-arm rays from head height hit the slab/walls at 2.9–3.8 m); it is a `CAM_DIST` constant, engine-owned.
5. **Player bobs onto the plinth when pushing into a façade** (y 0.35→0.62→0 jitter at the hall wall, `hall2.log:26-29`) — the 0.12 m plinth ledge at 0.6 m is within step-up reach.
6. **Plaza crowd is 5 identical red market-women** (populate for `[0,1]` picked `market_woman` 4/4 by deterministic seed + Greta is the same model; `/tmp/qa/04-spawn-yaw270.png`). Weight `villager_man` or add a third cast model.
7. **`Canopy_Full` (scale 2.5) reads as a 3 m beige block** on the plaza (`/tmp/qa/03-spawn-yaw180.png`); tavern has no sign or identifying dressing; sky is a flat white sheet ("cloudy"); the world edge shows as a flat dark-green wall on the horizon (`/tmp/qa/80-east-edge-lookback-west.png`).
8. **Lane strips are 6 cm solids above the analytic ground** — the player is pinned to y=0 so feet sit 6 cm inside the cobbles and verify reports "wedged spawn" / "position INSIDE a solid AABB at [10.0,14.9]" (both are the strips, not a missing collider). Make the strip parts `collider:"none"` or lift the ground.
9. **Talking through walls:** the steward could be triggered from inside the hall at 3 m (`hall2.log`, before he was moved) — `_nearest` is distance-only.
10. **Sword drawn at start in a peaceful town** (SHEATHE works; ATTACK is now hidden). Engine `start_weapon` default.
11. **verify WARNs to keep an eye on:** 51 distinct GLBs > 32 cache; `hud_fit` none; "FLAT-TINT" lint is a false positive (`GCast.recolor` duplicates materials — crowd textures are intact in frames).
12. **Chapel** has no door (open archway) and was not entered — the request didn't ask for it; fine.

---

## ✅ Verified working (final export)

| Check | Evidence |
|---|---|
| Boot, canvas, clean console (no SCRIPT ERROR/Parse Error/uncaught), no asset 404s | `verify_final.log` PASS; my runs `http>=400: 0`; only my-harness worklet noise |
| Spawn on the square (10, 0, 30) facing the hall 15 m north; steward now beside the door at (14, 17.5) | `/tmp/qa/A1-spawn-hud.png` |
| Closed hall door **blocks**: push W from z 16.7 → stops at z 14.88 (leaf AABB x 8.8–11.2, z 14.07–14.47) | `final.log:19`, `hall.log:21-23` |
| USE from the corridor centre (x=10, z≈16.7) opens the **door** (`quiet_door_town_hall_0_0_0` fired, not `steward_met`), leaf swings 95° outward (AABB → x 10.9–11.5, z 14.16–16.58), collider disabled, **no modal panel** | `final.log:21`, `/tmp/qa/A3-after-use-at-door.png` |
| Walk in; `into_hall` fires; interior walls solid on all sides (x≥4.3/≤15.7, z≥5.8) | `hall.log:29-55` |
| Stair to the **second floor without jumping**: y 0→3.61 over z 6.5→11.99; `upstairs` fires → `hall_upper` flag | `final2.log:76-77`, `B1-upstairs-new-stair.png` |
| Upper slab continuous (7–10 sweep points, y ≥ 3.3, no fall-through at walls/edges); upper walls solid | `final2.log:105`, `hall3.log:106,118` |
| Back **down** the stair and **out** through the open door | `final2.log:116,158` |
| **Windows are real openings**: headless ray-cast through every probed opening passes, walls hit at exactly 14.5/14.05/5.5 (`geo_probe.gd`); frames show the outside through windows from inside and the hero through the arch from outside | `/tmp/qa/41-house_b-interior-lookback.png`, `22-upstairs-arrival.png`, `verify/town-upstairs-window.png` |
| Quest chain end-to-end: upstairs flag + steward talk → `q_hall` completes, `GOGI_CHAIN advanced to 1/2`, HUD switches to "Meet the Townsfolk" | `final2.log:169`, `/tmp/qa/B4-hud-after-quest.png` |
| Houses: house_b [-1,1], house_d [1,1], house_c [1,1], tavern [2,1] — closed leaf blocks, USE opens, walk in, hollow interior reachable to the far corner, exit again; 3.1 m head clearance under the house slabs | `houses.log`, `/tmp/qa/41-44-*.png` |
| All **20 door leaves** centred on their doorways (offset 0.20–0.23 m = mid-wall), correct facing | static check vs `structures.json` + `world.json` (this report's session) |
| Tavern stair reaches its upper floor (y 3.41 at z 24.67) along the centre lane | `tavern.log:53` |
| World boundary: walked east along High Street to x=79.0 — contained at the grid edge, 176 solids still resident, town visible behind | `edge.log`, `/tmp/qa/81-east-edge-look-east.png` |
| Camera orbits with right-half drag/touch (yaw 0→1.30), pitch clamps (never floor-stares); WASD camera-relative; hero shows its BACK on W, FACE on S | `mobileP/L.log`, `/tmp/qa/42-house_d-interior-lookback.png` |
| Mobile fill 400×860 and 860×400: canvas == viewport, no letterbox, HUD (JUMP/USE/SHEATHE, quest text) inside the frame, joystick moves 7.8 m, no debug text | `/tmp/qa/5P-game.png`, `5L-game.png` |
| Title renders "Ashford / Green" (no mid-word break) at 960×540 | `/tmp/qa/A0-title-960x540.png` |
| Characters all Meshy (traveler hero, steward, blacksmith, market_woman, guard, villager_man), textured, animated, feet on the ground (`GOGI_HERO_SEAT 0.011`) | manifest + frames |
| `manifest.json` `webOnly:false` (native-playable data world); qgcheck winnable; audio infra + music/ambient present | `verify_final.log` |

## Fixed mid-QA by the 22:07 update (confirmed on the final export, not re-reported)
Title mid-word wrap ("ASHFOR / D GREEN" on all viewports → now "Ashford / Green"); `hide_hud: stats/health` no-op (now `hud_trim` rule: stats, health, minimap hidden; ATTACK hidden); "The door swings open." modal panel (now `quiet_door_*` rules → silent swing); USE at the door talking to the steward (steward moved to (14, 17.5); door wins from the corridor); `into_hall` toast saying "east wall" (now "left-hand wall"); stair widened.

## Could not verify (sandbox limits)
Real audio/TTS playback and speech end (npc.myapping.com fetch hangs here — P1-4 is sandbox-amplified), true GPU fidelity/colour, real touch feel and two-thumb play, the remaining 14 houses individually (door leaves verified statically, 4 buildings entered), the chapel interior.
