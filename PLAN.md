# Goal
Regenerate `world.json` from its sources (`tools/world_layout.json` + `tools/gameplay.json` +
`structures.json`) and redeploy Ashford Green. The previous commit changed `tools/gameplay.json`
(looping sunrise → day → sunset → night sky) but never re-ran `tools/build_town.py`, so the deployed
game still shows the fixed cloudy-day sky. Re-sync the engine template first (mandatory on a
continue), then rebuild the data against the current engine and re-export.

# Files to touch
- `*.gd` — engine re-sync (`sync-engine.mjs`): `audio_manager`, `build_structure`, `chunk_manager`,
  `interaction`, `main`, `surfaces`. Template-owned, untouched by hand.
- `tools/build_town.py` — adapt the door wiring to the synced engine: door leaves are now sized from
  the `doors[]` entry (`w`/`h`), the hinge sits half a doorway from the door centre, placement records
  carry `footprint` (engine applies the Mason GSurf materials + far-ring skyline), and the
  `quiet_door_*` rules are dropped (hinged doors now toggle, so a rule that pre-opens the door would
  make the engine handler shut it again).
- `tools/gameplay.json` — explicit `seconds` per sky-cycle segment (day-dominant loop).
- `world.json`, `tools/placements.json` — regenerated (`python3 tools/build_town.py --wire`; the
  compiled Mason GLBs in `models/town/` are unchanged, so no recompile).
- `docs/qa_report.md`, `docs/gamefeel_report.md` — this build's specialist reports.

# Verification approach
- `python3 tools/build_town.py --wire` → `world.json` carries the sky cycle, 21 buildings, 20 doors.
- Headless nothreads export + canonical `verify.mjs` (qgcheck winnability, engine currency, pck size,
  GPU-memory gate, smoke frames) on the exact `out/` deployed.
- Targeted: door leaf spans its doorway (w from the spec, hinge offset w/2); USE on the hall door
  opens it and leaves it OPEN (no `quiet_door_*` toggle regression); sky cycle applied
  (`weather` reads the cycle); Mason materials applied (no `body_*` mesh left on its flat preview colour).
- Independent QA + Game-Feel specialist passes on the content-complete export.

# Out of scope
- New buildings, layout changes, Mason recompiles (window sills, human-scale doorways), new characters.
- Engine changes (the template stays byte-identical to the synced version).
