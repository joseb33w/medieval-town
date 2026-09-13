extends Control
## In-game MINIMAP — a north-up top-down schematic of the world around the player. The control is SQUARE
## and the world->map transform uses the SAME scale on X and Z, so it can NEVER look squished. Reads the
## ChunkManager grid (cells / ground / structures / lava) + water level; the player is a facing arrow at
## the centre. Display-only (mouse ignored), redrawn at ~10 fps (the map does not need per-frame updates).

var main: Node = null
var _t := 0.0

var _look_cache := {}   # "gx,gz" -> {col, peak}; terrain is static so this never needs invalidating
const VIEW_M := 120.0                        # world metres shown across the whole map (zoom)
const BG := Color(0.08, 0.10, 0.09, 0.62)
const FRAME := Color(0.92, 0.83, 0.55, 0.95)
const FRAME_IN := Color(0.0, 0.0, 0.0, 0.5)
const LAND := Color(0.27, 0.35, 0.22)
const WATER := Color(0.15, 0.29, 0.44)
const HIGHLAND := Color(0.40, 0.33, 0.22)   # mid-elevation (hills)
const PEAK := Color(0.62, 0.60, 0.56)       # mountain tops
const STRUCT := Color(0.82, 0.75, 0.58)
const LAVA := Color(1.0, 0.45, 0.12)
const ENEMY := Color(0.96, 0.26, 0.20)      # live creature near the player
const ENEMY_CELL := Color(0.85, 0.30, 0.28, 0.45)  # authored creature spawn (distant)
const VEHICLE := Color(0.30, 0.86, 0.96)    # car / boat / plane
const BOSS := Color(0.90, 0.15, 0.60)       # large creature / boss
const PLAYER := Color(1.0, 0.96, 0.35)

func _process(delta: float) -> void:
	_t += delta
	if _t >= 0.16:   # ~6x/sec instead of 10 — a map this small reads identically and it is 40% fewer full redraws
		_t = 0.0
		queue_redraw()

func _draw() -> void:
	if main == null or not is_instance_valid(main):
		return
	var cm = main.get("chunk_manager")
	var pl = main.get("player")
	if cm == null or not is_instance_valid(cm) or pl == null or not is_instance_valid(pl):
		return
	# Do NOT draw until the world is actually up (at least one cell is resident). Before that the terrain
	# heightfield is not built, and calling _ground_y()->terrain.height() then faults the web build ("out of
	# bounds memory access"). This mirrors the pre-marker map, which only touched the terrain once water was set.
	var res = cm.get("resident")
	if not (res is Dictionary) or res.is_empty():
		return
	var w := size.x                          # SQUARE control -> size.x == size.y (set by main)
	var scl := w / VIEW_M                     # px per world metre — identical on both axes (no squish)
	var ctr := Vector2(w * 0.5, w * 0.5)
	var pc: Vector3 = pl.global_position
	var csz: float = cm.cell_size
	if csz <= 0.5 or w <= 0.0:
		return                                # guard div-by-zero / not-yet-sized
	var has_water: bool = cm.water_cfg != null
	var wl: float = cm.water_level

	draw_rect(Rect2(Vector2.ZERO, Vector2(w, w)), BG)

	var reach := clampi(int(VIEW_M / csz) + 2, 1, 24)   # clamp so a bad cell size can never blow up the loop
	var pcx := int(floor(pc.x / csz))
	var pcz := int(floor(pc.z / csz))
	var cell_px := csz * scl
	var grid = cm.grid
	for gx in range(pcx - reach, pcx + reach + 1):
		for gz in range(pcz - reach, pcz + reach + 1):
			var key: String = cm._key(gx, gz)
			if not grid.has(key):
				continue
			var rec = grid[key]
			var cwx := (float(gx) + 0.5) * csz
			var cwz := (float(gz) + 0.5) * csz
			var mp := ctr + Vector2(cwx - pc.x, cwz - pc.z) * scl
			# CACHED per-cell look. `gy` comes from _ground_y(), which walks every landform feature in
			# the world (often 20+) — and it was being recomputed for ~360 cells, ~10x a second, to
			# produce a colour that CANNOT change: terrain is static. That is ~75k feature iterations
			# per second for a constant. Compute once per cell, keep it. Bounded so a long roam can't
			# grow it without limit; the cost of a rare refill is one redraw.
			var look = _look_cache.get(key, null)
			if look == null:
				var g: float = cm._ground_y(cwx, cwz)   # explicit type: cm is untyped -> Variant
				var c: Color
				if has_water and g < wl - 0.3:
					c = WATER
				else:
					# HEIGHT gradient -> MOUNTAINS read as brown/grey highland; lowland stays green
					var ht := clampf(g / 34.0, 0.0, 1.0)
					c = LAND.lerp(HIGHLAND, smoothstep(0.12, 0.6, ht)).lerp(PEAK, smoothstep(0.62, 1.0, ht))
				if _look_cache.size() > 4000:
					_look_cache.clear()
				look = {"col": c, "peak": g > 24.0}
				_look_cache[key] = look
			var col: Color = (look as Dictionary)["col"]
			draw_rect(Rect2(mp - Vector2(cell_px, cell_px) * 0.5, Vector2(cell_px, cell_px)), col)
			# MOUNTAIN peak marker on tall cells (a little grey triangle)
			if bool((look as Dictionary)["peak"]):
				var ps := maxf(3.0, cell_px * 0.30)
				draw_colored_polygon(PackedVector2Array([mp + Vector2(0.0, -ps), mp + Vector2(-ps * 0.9, ps * 0.65), mp + Vector2(ps * 0.9, ps * 0.65)]), PEAK)
			# CREATURE spawn cell (authored) -> faint dot so distant creatures still show on the map
			if int(rec.get("enemies", 0)) > 0:
				draw_circle(mp, maxf(1.5, cell_px * 0.12), ENEMY_CELL)
			var structs = rec.get("structures", [])
			if structs is Array:
				for st in structs:
					if typeof(st) == TYPE_DICTIONARY:
						var sp := _xz(st.get("pos", [0, 0]))
						var fp := _xz(st.get("footprint", [6, 6]))
						var smp := ctr + Vector2(cwx + sp.x - pc.x, cwz + sp.y - pc.z) * scl
						var ss := Vector2(maxf(fp.x, 2.0), maxf(fp.y, 2.0)) * scl
						draw_rect(Rect2(smp - ss * 0.5, ss), STRUCT)
			var lava = rec.get("lava", [])
			if lava is Array:
				for lv in lava:
					if typeof(lv) == TYPE_DICTIONARY:
						var lp := _xz(lv.get("pos", [0, 0]))
						var lmp := ctr + Vector2(cwx + lp.x - pc.x, cwz + lp.y - pc.z) * scl
						draw_circle(lmp, maxf(3.0, float(lv.get("radius", 5.0)) * scl * 0.5), LAVA)

	# LIVE creatures near the player (loaded cells) -> bright red dots; a large creature/boss reads bigger + pink
	var enemies = cm.enemies
	if enemies is Array:
		for e in enemies:
			if e == null or not is_instance_valid(e) or bool(e.get("dead")):
				continue
			var ep: Vector3 = e.global_position
			var emp := ctr + Vector2(ep.x - pc.x, ep.z - pc.z) * scl
			if emp.x < -4.0 or emp.y < -4.0 or emp.x > w + 4.0 or emp.y > w + 4.0:
				continue
			var mh = e.get("max_h")
			var boss := (typeof(mh) == TYPE_FLOAT or typeof(mh) == TYPE_INT) and float(mh) > 3.5
			draw_circle(emp, 6.0 if boss else 3.5, BOSS if boss else ENEMY)
	# VEHICLES / PLANES (persistent) -> cyan squares; the one you're driving gets a ring
	var vroot = main.get("vehicle_root")
	var active = main.get("active_vehicle")
	if vroot != null and is_instance_valid(vroot):
		for v in vroot.get_children():
			if not (v is Node3D):
				continue
			var vp3: Vector3 = (v as Node3D).global_position
			var vmp := ctr + Vector2(vp3.x - pc.x, vp3.z - pc.z) * scl
			if vmp.x < -4.0 or vmp.y < -4.0 or vmp.x > w + 4.0 or vmp.y > w + 4.0:
				continue
			draw_rect(Rect2(vmp - Vector2(4.0, 4.0), Vector2(8.0, 8.0)), VEHICLE)
			if v == active:
				draw_arc(vmp, 8.0, 0.0, TAU, 14, VEHICLE, 1.5)
	# OTHER PLAYERS -> a dot in that peer's own body colour, so the blip and the body on screen
	# agree about who is who. There were NO peer blips at all before this: in a 48m arena you can
	# see everyone anyway, but the moment a multiplayer world gets big, a map with no opponents on
	# it turns a deathmatch into a hiking simulator.
	#
	# Fed from netsync RECORDS, so peers past the interest radius (no avatar) still show — drawn
	# HOLLOW, because "we know where they are" and "you can see them" are different claims and the
	# map should not make the stronger one.
	var ns = main.get("netsync")
	if ns != null and is_instance_valid(ns) and ns.has_method("peer_blips"):
		for b: Variant in ns.peer_blips():
			var bp: Vector3 = (b as Dictionary).get("pos", Vector3.ZERO)
			var bmp := ctr + Vector2(bp.x - pc.x, bp.z - pc.z) * scl
			if bmp.x < -4.0 or bmp.y < -4.0 or bmp.x > w + 4.0 or bmp.y > w + 4.0:
				continue
			var bc: Color = (b as Dictionary).get("color", Color(1, 1, 1))
			if bool((b as Dictionary).get("far", false)):
				draw_arc(bmp, 5.0, 0.0, TAU, 14, bc, 2.0)
			else:
				draw_circle(bmp, 5.0, bc)
				draw_arc(bmp, 5.0, 0.0, TAU, 14, Color(0, 0, 0, 0.8), 1.5)
	# frame (double line for a crisp "map" edge)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, w)), FRAME_IN, false, 4.0)
	draw_rect(Rect2(Vector2.ONE, Vector2(w - 2.0, w - 2.0)), FRAME, false, 2.0)

	# PLAYER arrow at centre, pointing where the player faces (camera-forward on the world plane)
	var yaw: float = main.get("cam_yaw")
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var rgt := Vector2(fwd.y, -fwd.x)
	var s := maxf(8.0, w * 0.055)
	var tip := ctr + fwd * s
	var bl := ctr - fwd * s * 0.55 + rgt * s * 0.62
	var br := ctr - fwd * s * 0.55 - rgt * s * 0.62
	draw_colored_polygon(PackedVector2Array([tip, bl, br]), PLAYER)
	draw_circle(ctr, s * 0.16, Color(0.1, 0.1, 0.1, 0.9))


func _xz(a) -> Vector2:
	if a is Array and a.size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO
