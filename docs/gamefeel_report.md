# Ashford Green — Game-Feel / Mobile-UX review

**VERDICT: FAIL (0 P0, 7 P1)** — nothing ship-blocking (touch works end-to-end, no modal damage banners, no debug text), but seven must-fix feel defects, four of which are fixable in `world.json` / `tools/gameplay.json` alone and were **verified fixed** in a sandbox copy of the export (`/tmp/gf/out2`, project untouched).

How this was tested: the deployed export (`/workspace/out`) was driven with **CDP touch events only** (no keyboard) in Chromium/SwiftShader at portrait **400×860** and landscape **860×400** (`hasTouch`, `isMobile`). Scripts + frames live in `/tmp/gf/` (`common.mjs`, `step1_title.mjs`, `step2_play.mjs`, `step4_house.mjs`, `*.png`); the key frames are also copied to `/mnt/session/outputs/gamefeel_evidence/`. The engine's CDN files were served from a local cache because the CDN sends no CORS header to a `127.0.0.1` origin — that is a sandbox detail, not a build defect. Engine `.gd` files were read but not modified; the project was not modified.

Runtime facts observed: HUD grid `vp 720x1548` (portrait) / `1548x720` (landscape) → 1 css px = 1.8 HUD units, so every HUD font is drawn at ~0.56× its nominal size on a 400-px-wide phone. Rules fired: `welcome`, `into_hall`, `upstairs` (+ `hud_trim`, `hall_door_quiet` in the sandbox copy). No script errors.

---

## ❗ P1 — must fix

### P1-1  Title screen breaks the town name mid-word: "ASHFOR / D GREEN" (both orientations)
- **Symptom:** the very first screen shows `ASHFOR` on one line and `D GREEN` on the next. Evidence: `/tmp/gf/port-title.png`, `/tmp/gf/land-title.png`.
- **Root cause (engine, `game_shell.gd:441-448`):** the title `Label` is font 84 with `AUTOWRAP_WORD_SMART` inside a `VBoxContainer` whose width is set by the 360-unit mode button; "ASHFORD" at 84 units is ~364 units wide, so the smart wrap splits the word.
- **Data fix (verified):** set `director.title.name` to `"Ashford\nGreen"` (mixed case — the lowercase glyphs are narrow enough to fit). Renders cleanly: `/tmp/gf/fix-00-title.png`. Do **not** use `"ASHFORD\nGREEN"` — all-caps ASHFORD still doesn't fit and gives three lines (`ASHFOR / D / GREEN`).

### P1-2  "The door swings open." is a persistent modal-style panel that follows you through the whole hall
- **Symptom:** USE on the hall door pops a dark panel at the top ("The door swings open.") plus a yellow "tap dialogue / USE to continue" line over the hero's body. It never fades: it is still up inside the hall, at the stair foot and on the second floor (coordinator frames `verify/town-inside.png`, `town-stair-foot.png`, `town-upstairs.png`; mine `/tmp/gf/port2-07-inside-dialog-still-up.png`). While it is up (a) the panel covers the Lv/HP/Inv block and the minimap's left edge, (b) the `USE >` prompt for anything else is suppressed, and (c) the USE button's next press only dismisses the panel — so the "steward is 2 m away, press USE" flow costs an extra tap for a routine door. This is the "popup on a routine action" class.
- **Root cause (engine):** `interaction.gd:467-482 _open_door()` calls `_show(["The door swings open."])`, and `_advance()` only clears on tap/USE — no timeout. `dlg_box` is `PRESET_TOP_WIDE` at y 40..150 (`interaction.gd:818-823`), which is exactly where the stats block and minimap live.
- **Data fix (verified):** add a rule that opens the door *before* the engine handler runs — `try_use()` fires `interact` first and `_open_door()` early-returns when the leaf is already open:
  ```json
  {"id":"hall_door_quiet","when":{"event":"interact","target":"door_town_hall_0_0_0"},
   "then":[{"open_door":"door_town_hall_0_0_0"}]}
  ```
  Verified: `GOGI_RULE_FIRED hall_door_quiet on=interact`, door swings, no panel (`/tmp/gf/fix-07-inside-dialog-still-up.png` shows a clean HUD inside). Apply the same pattern to the 20 house/tavern doors (ids `door_house_*`, `door_tavern_*`) — one rule each, or fewer if the coordinator uses the `""`-matches-all target on the `open_door` side. A `sound` action is not needed (the swing already plays `door`).

### P1-3  `hide_hud: ["stats","health"]` in gameplay.json is silently ignored — Lv/HP/XP/Gold, an HP bar and an inventory dump ship on a no-combat town
- **Symptom:** every frame shows `Lv 1  HP 100/100  XP 0/30  Gold 0 / Wpn: Rusty Sword / Inv: [Rusty Sword]` and a red HP bar top-left. `Inv: [Rusty Sword]` is a bracketed array dump — it reads as developer text. The author clearly intended to hide these (they're in `hide_hud`), but nothing happened.
- **Root cause (engine, `game_shell.gd:126-131`):** `hide_hud` only consults `main._hud_btns` (buttons). `stats` and `health` are labels/bars, so they are skipped without a warning. The rule action `hud_hide` (`rules.gd:441`) *does* resolve them via `main.hud_targets()`.
- **Data fix (verified):** add a start rule:
  ```json
  {"id":"hud_trim","when":{"event":"start"},"then":[{"hud_hide":"stats"},{"hud_hide":"health"}]}
  ```
  Log confirms `GOGI_HUD hide stats n=1`, `GOGI_HUD hide health n=2`; the block is gone in `/tmp/gf/fix-07-inside-dialog-still-up.png`. Consider adding `{"hud_hide":"minimap"}` too (see polish P-3) and `"attack"` to `hide_hud` (see P1-7).

### P1-4  Standing squarely in front of the hall door, USE talks to the steward instead of opening the door
- **Symptom:** walking straight up the spawn→door corridor (x = 10) and stopping ~2.3 m from the door, the prompt reads **"USE > Talk to Steward Aldric"**, and pressing USE starts his speech (`/tmp/gf/port-05-door-prompt.png`, `port-06-after-use.png`). The door is only offered when you stand off-centre to the *left* (x ≈ 9.0: `/tmp/gf/port2-05-door-prompt.png`) or hug the wall (x 8.8, z 14.9). Coordinator frame `verify/town-door-closed.png` shows the same at the door.
- **Root cause (data):** `interaction._nearest(2.9)` picks the nearest interactable; the door hotspot is registered at cell-local `[1.1, 4.275]` → world (11.1, 14.3) while the steward stands at world (12.5, 16.5), so from the corridor centre the steward (2.5 m) beats the door (2.8 m).
- **Data fix:** move the steward ≥ 4 m from the doorway line, e.g. cell `[0,0]` npc pos `[4.0, 7.5]` (world 14.0, 17.5) or to the other side of the square; optionally also centre the door hotspot on the leaf (`pos [0.0, 4.275]` → world (10, 14.3)) so the prompt appears when the player is centred on the door. Re-verify with `_nearest` from (10, 16.8): door should win.

### P1-5  Toasts, the subtitle and the door panel all collide with other HUD elements on a phone
- **Symptoms (all observed):**
  - The `upstairs` **subtitle** ("The council chamber. Look out through the tall windows…") is drawn straight across the JUMP/DRAW/SHEATHE/USE buttons in portrait (`/tmp/gf/port2-10-upstairs.png`, `port2-11-upstairs-window-back.png`) and landscape (`verify/town-upstairs.png`, `town-upstairs-window.png`).
  - **Toasts** ("The town hall. The stairs…", "Market Square", the welcome line) sit at 16 % height — over the quest text and over the door panel when both are up (`verify/town-inside.png`).
  - Three toasts fire within a second of starting (chain toast "Find Steward Aldric…" 5 s → `welcome` rule toast 3 s → "Market Square" 2.2 s once you walk 4 m); the single toast label is overwritten each time, so the player never gets to read the quest toast.
- **Root cause (engine, `game_shell.gd:848-861`):** `_sub_lbl` is at x 22–78 %, y 72 % — in portrait that band (x 88–312 px, y 619–680 px) overlaps the thumb grid (x ≥ 305 px, y ≥ 591 px) and in landscape it covers SHEATHE/USE outright. `_toast_lbl` is at y 16 % regardless of the quest label (y 140 units) or `dlg_box` (y 40–150).
- **Data mitigation (verified rule fires):** in the `upstairs` rule replace `{"subtitle": …}` with `{"toast": "The council chamber — look out through the tall windows over the square.", "hold": 4.0}` (toast sits in the top band, which is at least clear of the buttons). Drop the `welcome` rule's toast (the chain toast already says the same) so the quest toast survives, or enlarge `Market Square` radius to ≥ 21 so the region toast fires at spawn instead of 1 s into the walk. Engine-side the real fix is a stacked toast queue and a subtitle band that avoids `_relayout_ui`'s button rects.

### P1-6  Camera leaves the building through window openings / collapses onto the hero indoors and in alleys
- **Symptoms (all observed):**
  - Upstairs, standing at the front wall (x 9.6–12, z 13.6): the SpringArm passes out through the tall window / sits inside the wall — the frame is either the *exterior* façade with the hero seen through the arch (`/tmp/gf/port2-11-upstairs-window-back.png`, `verify/town-upstairs-window.png`) or a flat beige wall filling 100 % of the screen with no hero at all (`/tmp/gf/fix-11-upstairs-window-back.png`). Coordinator frame `verify/town-upstairs.png` shows the collapsed variant (hero fills 60 % of the frame, weapon in the lens).
  - Ground floor near the front wall (z ≈ 11): the arm collapses to ~3 m, the hero fills ~40 % of the height and the drawn sword juts into the camera (`/tmp/gf/port2-07-inside-dialog-still-up.png`, `fix-07-…`).
  - Outside a house door, 2 m from it: door + wall fill the top 60 %, hero hidden by the near-camera cull (`/tmp/gf/house-01-house-door.png`); pinned in a lane beside a house: 60 % wall (`/tmp/gf/house-01-house-door.png` from the first attempt, `house-04-house-inside-orbit.png` = camera outside looking in through a window).
  - Mid-stair the west wall fills the left 40 % and the hero walks *toward* the camera (`/tmp/gf/fix-09-mid-stair.png`) — you cannot see where the stair leads.
- **Root cause (engine, `main.gd:28-29, 2966-2969`):** `CAM_DIST 8.5` + `cam_spring.margin 0.3` on a 12×9 m hall / 7×6 m houses with **real** window openings: the arm ray goes through the opening so the camera ends up outside, and against a solid wall it collapses to < 3 m. No data hook exists for camera distance (`spring_length` is a constant).
- **Data mitigations (closest available):** (a) glaze the windows — a thin box part with a semi-transparent material and a collider in each opening stops the arm while staying see-through (the interiors stay "real windows"), authored as `rows`/`part` boxes in `world.json`, or regenerate the town GLBs with pane geometry in `mason/`; (b) if the engine can be touched, an indoor camera distance (e.g. 4.5 m when a zone flag like `hall_ground`/`hall_upper` is set) and `_hero_avatar.visible` threshold are the real fixes. Note the upstairs **look-out** itself works well once the camera is inside (`/tmp/gf/port2-12-upstairs-window-look-out.png`).

### P1-7  Peaceful town, but the traveller walks around with a drawn sword and an ATTACK button in prime thumb space
- **Symptom:** every frame shows the rusty sword drawn (it is what clips into the lens in P1-6) and `ATTACK` as the bottom-right, easiest-to-reach button. There is nothing to attack. Tapping ATTACK in front of an NPC swings a sword at them.
- **Root cause:** `rpg_systems.gd:46-47` starts with `rusty_sword` equipped and `_weapon_stowed := false` (`main.gd:132`); `remove_item` does not un-equip, and there is no `sheathe` rule action.
- **Data mitigation:** add `"attack"` (and, if you don't want the draw/sheathe toggle either, `"weapon"`) to `director.hide_hud` — both are real buttons so `hide_hud` works for them. The sword itself needs an engine hook (`start_weapon: ""` → unarmed, or a `sheathe` action); flag it to the template owners. SHEATHE via touch works (`/tmp/gf/port2-08b-sheathed.png` shows the button flipping to DRAW), so at minimum the player *can* holster.

---

## ⚠️ Polish

- **P-1 Wrong direction in the hall toast.** "The stairs … are along the **east** wall" — the stair is at x ≈ 5.25, i.e. the **west** wall, on the player's **left** when entering (coordinator frame `verify/town-inside.png` shows the stair on the left while the toast says east). Fix the text in the `into_hall` rule: "along the left-hand wall".
- **P-2 Stale quest checkbox after talking to the steward.** `quest.notify_talk()` marks the step done but only emits `objective_changed` when the whole quest completes (`quest.gd:69-79, 111-123`), so "[ ] Speak with Steward Aldric" stays unticked after the talk (`/tmp/gf/port-06-after-use.png`). Engine bug; data mitigation: a rule `{"when":{"event":"talk","target":"steward"},"then":[{"toast":"Steward Aldric greeted — now open the hall door."}]}` gives the missing feedback.
- **P-3 Minimap is a blank green square.** `minimap.gd` draws ground cells and `structures` only; the town's houses are `props` and the hall a `landmark`, so the map shows nothing but the arrow — inside the hall too. Hide it with `{"hud_hide":"minimap"}` in the start rule, or accept.
- **P-4 NPC dialogue is voice-only with a USE lock-out.** After USE on the steward the prompt shows "Steward Aldric is speaking…" and USE is a no-op until the TTS (2 lines + an LLM reply) finishes (`interaction.gd:302, 741-767`). With the phone muted the player gets no text at all. Data mitigation: on `talk`/`steward` add a `subtitle`/`toast` with his key line. (In the sandbox the speech never finished because the audio worklet cannot load — a sandbox artefact, but it shows the lock-out has no timeout.)
- **P-5 HUD text is fine-print on a phone.** Quest text 17 units ≈ 9.4 css px, title hint/caption 14–15 units ≈ 8 css px, the only explanation of the invisible joystick ("Left side: joystick to move…") is that 8-px line. Engine scale (`_fit_ui_scale` fixes the short side at 720 units). Data mitigation: keep quest step descriptions short; put the control hint in the `tagline` (20 units) instead of `hint`.
- **P-6 Pitch extremes.** Dragging up to `CAM_PITCH_MAX` grounds the arm and the hero fills ~25 % of the frame against sky, with the stats text unreadable white-on-grey (`/tmp/gf/port-04-pitch-min.png`); full-down is a top-down scalp view (`port-03-pitch-max.png`). Within the template's deliberately narrowed range, no recentre. Acceptable, noting only.
- **P-7 Landscape default framing is far/top-down** — the hero is ~11 % of the frame height on the square (`/tmp/gf/land-01-spawn.png`, `land-07-…`); fine for orientation, small for a walking-tour game. Engine constant.

---

## ✅ What passed / felt good

- **Touch controls work one-handed, end to end (P0 class clear).** Invisible left-half joystick moves the player (z 30 → 19.6 on a 2.5 s hold, both aspects); right-half drag orbits the camera (−120 px → +1.296 rad, yaw restored on the reverse drag); USE / SHEATHE buttons fire their verb from a touch tap (steward talk, dialogue dismiss, sheathe→DRAW). Button grid: portrait 85×72 css px cells at x ≥ 305 px / y ≥ 591 px; landscape 128×52 px cells at x ≥ 584 px / y ≥ 192 px — all inside the right half, none off-screen or under each other, and `_touch_on_hud` keeps button presses from starting an orbit (`main.gd:2042-2044`).
- **Title screen fits and is tappable** in both aspects (aside from P1-1); the "Tap to play" audio gate is a single tap.
- **No debug text ships** (`hud_debug` off; `GOGI_*` lines are console-only). The one debug-looking string is the inventory dump covered by P1-3.
- **Region names are transient** — "Market Square" is a 2.2 s toast (`/tmp/gf/house-03-house-inside.png`), never pinned.
- **Damage feedback is non-modal by design** (`shake` action, no death dialog) — moot here, no combat.
- **First-run orientation is good:** at spawn the hall door is dead ahead 15 m away and the steward stands beside it (`/tmp/gf/port-01-spawn.png`); it's a 3-second walk to the first interaction. The quest text says exactly where to go.
- **The windows really are openings** — from upstairs you see the square and villagers through the arch (`/tmp/gf/port2-12-upstairs-window-look-out.png`), which is the user's headline ask.
- **Door prompt range** (~2.9 m) is right — "USE > Town Hall Door" appears as you arrive (`/tmp/gf/port2-05-door-prompt.png`).

---

## Could not verify (sandbox limits)

- True simultaneous two-thumb feel (joystick + look at once), notch/home-indicator insets (`_safe_insets` returns zero on web), haptics, and real-device frame pacing — no touchscreen/GPU here. The multi-touch *code path* keys on `event.index` and looks correct, but it was not exercised.
- NPC speech playback and its natural end (audio worklets don't load cross-origin in the sandbox); the TTS endpoint itself answers in ~2.5 s.
- House interior framing was only partly captured: the `door_house_b_0_-1_0` hotspot in `world.json` (`[3.6,-1.9]` → world (−6.4, 8.1)) is ~1.1 m from the architect's door centre (−6.6, 7.0) per `tools/architect_notes.md`, and my walk-in slid along the outside of the south wall instead of entering. QA should confirm house doors line up with their openings; the camera-through-window behaviour was still observed there (`/tmp/gf/house-04-house-inside-orbit.png`).

## Summary for the remediation loop (data-only, in priority order)

1. `tools/gameplay.json` → `director.title.name = "Ashford\nGreen"` (P1-1).
2. Add start rule `hud_trim`: `hud_hide` stats, health (+ minimap); add `"attack"` to `hide_hud` (P1-3, P1-7, P-3).
3. Add `interact → open_door` rules for the hall door and every house/tavern door (P1-2).
4. Move Steward Aldric ≥ 4 m off the door line (P1-4).
5. `upstairs` rule: `subtitle` → `toast`; drop the duplicate `welcome` toast; fix "east wall" → "left-hand wall" (P1-5, P-1).
6. Add `talk/steward` feedback toast or subtitle (P-2, P-4).
7. Camera-through-window / indoor collapse (P1-6) needs either glazed window colliders in the town geometry or an engine-side indoor camera distance — flag to the template owners.
