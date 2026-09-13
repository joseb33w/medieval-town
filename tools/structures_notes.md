# structures.json — design notes & arithmetic

Spec compiled with `/workspace/mason/mason.py` into a scratch dir (`/tmp/struct-check`) and
checked with `verify_walk.mjs` → **7/7 walkable, 0 warnings, 0 failed.** A second ray-cast pass
of my own confirmed: every one of the 92 openings is a through-hole (ray passes the wall band at
the opening centre with zero hits), every ground-floor door head clears the slab underside,
storey slabs are continuous everywhere outside the stairwell, and min headroom is
GF ≥ 3.10 m / 2F ≥ 3.29 m in every 2-storey building.

Frame (Mason): footprint centred on origin, base z=0, **face "s" = front = model +Y**
(→ Godot −Z). On e/w faces `centre` is a Y offset (+ = toward the front). Stairs rise toward +Y.
All entries carry `"profile":"vertical"` and `"collider":"mesh"` (the playbook calls the collider
mandatory on the landmark record — a box collider seals the door). Mason ignores both
geometrically; they are there so the coordinator can carry the record through unchanged.

## Ground-floor DOORS (for hanging the 2.2 × 3.0 leaf)

| id        | face | centre (m) | w   | h / top | kind |
|-----------|------|-----------:|-----|---------|------|
| town_hall | s    |  0.0       | 2.3 | 3.1     | rect |
| house_a   | s    |  0.0       | 2.3 | 3.1     | rect |
| house_b   | s    | −2.0       | 2.3 | 3.1     | rect |
| house_c   | s    |  0.0       | 2.3 | 3.1     | rect |
| house_d   | s    |  0.0       | 2.3 | 3.1     | rect |
| tavern    | s    | −2.5       | 2.3 | 3.1     | rect (see deviation 2) |
| chapel    | s    |  0.0       | 2.3 | arch: springing 2.7 + radius 1.15 = top 3.85 (see deviation 3) |

All door sills 0; interior floor_z 0.06 everywhere (6 cm threshold step, walk gate accepts).

## DEVIATIONS from the delegation (each one forced by arithmetic — please read)

1. **2-storey houses (a, b, d) use floor_height 3.4, not 3.2.** Slabs are 0.25 thick with their
   TOP at floor_z + floor_height, so the underside is at 0.06 + 3.2 − 0.25 = **3.01 < 3.1** door
   head — the slab edge would have shown as a 9 cm "lintel" in the top of every house doorway.
   With 3.4: underside 3.21, 11 cm clear. Houses are now 6.8 m to eaves (tavern is 6.8 too,
   town hall 7.2 + 3.0 roof still dominates). Footprints / floor counts unchanged.
2. **Tavern front door is RECT 2.3 × 3.1, not an arch.** The requested arch (springing 2.2 +
   1.15 = 3.35) would have punched 14 cm into the first-floor slab (underside 3.21). Also a
   2.2 × 3.0 rectangular leaf physically cannot hang in a w-2.3 semicircular arch unless the
   springing is ≥ 3.0 − √(1.15² − 1.1²) = 2.67 (the leaf's top corners clip the arch head) —
   that would put the arch top at 3.82, above the slab. Tavern keeps its character via the
   deep stone plinth, string course and wide ground-floor windows. If the coordinator prefers
   the arch anyway, it needs floor_height ≥ 4.1 (height 8.2), which I judged too tall.
3. **Chapel door arch springing raised 2.4 → 2.7** (top 3.85) for the same leaf-corner reason
   (arch height at x = ±1.1 is 2.7 + 0.335 = 3.03 ≥ 3.0 leaf). No slab in the chapel so it's
   free. Also added a small arch window over the door (sill 4.5, springing 0.4, r 0.5, top 5.4).
4. **Chapel lancets: in Mason, `springing` for a window is measured FROM THE SILL** (the jamb
   box is `springing` tall and the whole cutter is then lifted by `sill`). So sill 1.6 +
   springing 3.0 + radius 0.55 → head at **5.15**, i.e. 3.55 m tall lancets — reads well on a
   6.5 m nave wall and stays under the cornice (6.1). If a shorter window was intended, drop
   springing to ~1.5 (head 3.65).
5. **More windows than the minimum asked** on side/back faces (a ground + an upper window per
   face on the 2-storey houses, two per face on house_d's long sides). Pure see-through
   intent: light comes through every building from every direction.
6. **Pier widths under the 0.9 m guideline on the small fronts.** A fixed 2.3 m door on a 6–7 m
   face leaves 1.85–2.35 m each side; flanking windows there can't have 0.9 m both to the door
   and to the corner. house_c: w 0.75 windows at ±2.1 (0.58 m to the door, 0.53 m to the corner).
   house_a: w 0.9 at +2.3 (0.70 / 0.75). house_d: w 0.8 at −2.2 (0.65 / 0.65). house_b's
   right-hand ground window: 0.85 m to its neighbour, 0.9 to the corner. All piers ≥ 0.5 m in
   0.4 m walls — fine for masonry, and the compile shows no sliver faces.
7. **Mason observation, not a spec issue (coordinator's call):** the stairwell cutout is
   `(run + 0.5)` long centred on `cy`, but the treads are boxes CENTRED at `y0 + i·tread`, so the
   flight really spans `cy − run/2 − tread/2 … cy + run/2 − tread/2`. Result: a **0.38 m gap in
   the slab between the top tread's front edge and the well's front edge** (measured by ray:
   town_hall y = 1.7–1.9 → surface 0.06 instead of 3.66; tavern y = 1.7–2.0). A 0.30 m-radius
   capsule spans it (edge contact ≈ 39°, under the 45° floor angle; dips ~7 cm) so the climb
   still works and the gate passes, but it is ugly and a smaller capsule would drop through.
   One-line fix in `mason.py::_interior`: make the well `n*tread + 0.25` long and centre it at
   `cy0 − tread/2 − 0.125` (flush with the top tread, 0.25 headroom margin at the bottom).

## Per-building arithmetic

### town_hall  [12 × 9], 2 floors × 3.6 = 7.2, wall_t 0.45
- Inner void x ±5.55, y ±4.05 (front wall inner face y = +4.05). Slab top 3.66, underside 3.41.
- Stair: 3.6 / 0.2 = **18 risers** exactly, tread 0.26 → run 4.68. width 1.2.
  cx = 6 − 0.45 − 0.6 − 0.2 = **4.75** → flight x 4.15…5.35 (0.2 m off the east wall).
  cy = **−0.6** → flight y −2.94…+1.74 (tread boxes −3.07…+1.61); well 1.55 × 5.18 →
  x 3.98…5.53, y −3.19…+1.99 (inside the void).
  Landing rule: −0.6 + 2.34 + 0.25 + 1.3 = 3.29 ≤ 4.05 ✓ → **2.06 m of slab** from well edge
  to the front wall (measured 2.0). Behind bottom tread: 4.05 − 3.07 = 0.98 m to approach.
- Headroom: GF 3.41 − 0.06 = 3.35; 2F 7.2 − 3.66 = **3.54** ✓. Door head 3.1 < 3.41 ✓.
- Path: door (0, +4.05) → walk back to the rear-east corner → climb toward the front → arrive
  near the front-east corner of the 2nd floor, upper east/front windows right there.
- East ground window only at y +2.6 (front half; flight ends at 1.61 → never under a window).
- Front: door 0 (±1.15); GF windows ±3.5 w 1.3 (edges 2.85…4.15: 1.7 to door, 1.85 to corner),
  sill 1.0 h 1.8 → head 2.8 < course 3.66. Upper: 3 ARCHES at −3.5/0/3.5, w 1.2, sill 4.66,
  springing 1.2, r 0.6 → head 6.46 < cornice 6.8 ✓ (eaves − 0.35 = 6.85).
- Back n: 3 + 3 rect, ±3.5/0, w 1.2 (gaps 2.3, corner 1.9). Sides: ±2.6 w 1.2 (corner 1.3,
  gap 4.0). Upper sill 4.66 h 1.6 → head 6.26 ✓.
- Trims: plinth 0.12 / top 0.6 / chamfer 0.08; course z 3.66 h 0.25; cornice z 6.8 h 0.4.

### tavern  [10 × 8], 2 × 3.4 = 6.8, wall_t 0.45
- Inner void x ±4.55, y ±3.55. Slab top 3.46, underside 3.21 (> 3.1 door ✓).
- Stair: 3.4 / 0.2 = **17 risers**, tread 0.26 → run 4.42, width 1.1.
  cx = 5 − 0.45 − 0.55 − 0.2 = **3.8** (flight x 3.25…4.35). cy = **−0.4** → flight y
  −2.61…+1.81 (treads −2.74…+1.68); well 1.45 × 4.92 → y −2.86…+2.06.
  Landing: −0.4 + 2.21 + 0.25 + 1.3 = 3.36 ≤ 3.55 ✓ → **1.49 m** (measured 1.4).
  Behind bottom tread 3.55 − 2.74 = 0.81 m.
- Headroom GF 3.15, 2F 6.8 − 3.46 = **3.34** ✓.
- Front: door −2.5 (edges −3.65…−1.35, 1.35 to corner); GF windows 0.8 and 3.2, w 1.5, sill 1.1
  h 1.5 (0.05…1.55 / 2.45…3.95: 1.4 to door, 0.9 between, 1.05 to corner). Upper −3/0/3 w 1.2
  sill 4.46 h 1.5 → head 5.96 < cornice 6.4 ✓.
- East GF window at +2.5 w 1.1 (edges 1.95…3.05, corner 0.95) — clear of the flight (ends 1.68).
  East upper ±2.4; west ±2.4 both floors; back −3/0/3 both floors, w 1.2.
- Trims: plinth 0.12 / 0.55 / 0.06; course z 3.46 h 0.25; cornice z 6.4 h 0.4.

### house_a  [7 × 6], 2 × 3.4 = 6.8, wall_t 0.4, plaster, slate gable ridge x rh 2.4
- Front: door 0; GF window +2.3 w 0.9 sill 1.1 h 1.4; upper ±1.9 w 1.1 sill 4.46 → head 5.86
  < cornice 6.45 ✓. Sides & back: 1 GF + 1 upper at centre 0, w 1.1. Hollow, slab at 3.46.

### house_b  [8 × 6.5], 2 × 3.4 = 6.8, wall_t 0.4, brick, slate gable ridge x rh 2.5
- Front: door −2.0 (edges −3.15…−0.85, 0.85 to corner); GF windows 0.6 & 2.55 w 1.1
  (0.05…1.15 / 2.0…3.1: 0.9 to door, 0.85 between, 0.9 to corner); upper −2.4/0/2.4 w 1.1.
  Sides: centre 0 both floors; back ±2.0 both floors. Hollow.

### house_c  [6 × 5.5], 1 floor, height 3.6, wall_t 0.4, stone, timber gable ridge x rh 2.4
- Front: door 0; windows ±2.1 w 0.75 sill 1.1 h 1.3 → head 2.4 < 3.25 ✓. Sides centre 0 w 1.0,
  back centre 0 w 1.1. Cornice z 3.3 h 0.3 p 0.15. Interior ceiling 3.54.

### house_d  [6.5 × 8], 2 × 3.4 = 6.8, wall_t 0.4, timber, slate gable **ridge y** rh 2.6
- Gable end faces the street. Front: door 0; small GF window −2.2 w 0.8; upper ±1.6 w 1.0
  (1.1…2.1, corner 1.15). Long sides e/w: ±2.2 w 1.1 both floors (corner 1.25, gap 3.3).
  Back: GF centre 0 w 1.1; upper ±1.6 w 1.0. Hollow.

### chapel  [7 × 12], 1 floor, height 6.5, wall_t 0.5, stone, slate gable **ridge y** rh 3.2
- Front (short side): arch door w 2.3 springing 2.7 r 1.15 (top 3.85); arch window over the door
  sill 4.5 spr 0.4 r 0.5 (top 5.4, 0.65 m of masonry above the door head).
- Long sides: 3 lancets each at −3.3/0/3.3, w 1.1, sill 1.6, springing 3.0, r 0.55 → head 5.15
  < cornice 6.1 ✓ (gaps 2.2, corner 2.15).
- Back: round-headed window w 1.4, sill 3.9, springing 0.4, r 0.7 → top 5.0.
- Trims: plinth 0.15 / 0.7 / 0.08; sill band course z 1.35 h 0.25; cornice z 6.1 h 0.4.
- Interior: one hall, floor 0.06, ceiling 6.5 (measured 6.39 clear).

## Compile stats (scratch compile, lod0)
town_hall 324 faces / 1812 tris · tavern 320 / 1316 · chapel 158 / 2208 (arches) · houses
112–206 faces / 412–828 tris. All well under the 1000-tri collision-hull threshold once the
collision spec strips trims (collision shells are the massing only).
