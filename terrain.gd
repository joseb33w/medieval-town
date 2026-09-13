class_name GTerrain
## TERRAIN — a global noise heightfield + per-cell heightmap mesh + collider, so an open world is ROLLING ground
## (hills, dunes, valleys) instead of a dead flat slab (the #1 illusion-breaker). SEAMLESS by construction:
## the ANALYTIC noise field (_height_analytic) is a PURE function of world (x,z) sampled at mesh vertices, so
## adjacent streamed cells line up at their shared edge with no crack — and height() returns the RENDERED triangle
## surface (interpolated between those vertices), so placement matches what's on screen. OPT-IN per world
## (world.json top-level `terrain: {...}`); without it, cells stay flat (cities/structured worlds want flat).
##
## The chunk streamer calls cell_terrain() for the cell floor and height()/normal_at() to LIFT every placed object
## onto the surface; the player (CharacterBody3D + gravity) walks on the trimesh collider.
##
## world.json:  "terrain": { "amplitude": 8, "frequency": 0.012, "seed": 7, "octaves": 4, "material": "sand",
##                           "resolution": 8, "warp": 0.0, "floor": 0.0 }

var amplitude := 6.0       # peak-to-mid height variation (metres)
var frequency := 0.012     # base noise frequency (LOWER = broader, gentler hills)
var seed_i := 1337
var octaves := 4
var resolution := 8        # heightmap samples per cell EDGE (8 -> 8x8 quads/cell; cheap, 9-cell ring)
var floor_y := 0.0         # baseline the heightfield oscillates around
var warp_amt := 0.0        # optional domain warp (dunes/ridges); 0 = smooth rolling
var material_spec = "grass"

var _noise: FastNoiseLite
var _warp: FastNoiseLite
var _mat: Material
# ---- island + analytic landform features (world.json terrain.island / terrain.features) ----
# All are applied INSIDE _height_analytic so the mesh, collider, height() lifts and far skirt agree.
var _island_r := 0.0            # island radius (0 = no island falloff)
var _island_shore := 60.0       # falloff band width beyond the radius
var _island_depth := 14.0       # how far below floor_y the sea bed settles
var _island_c := Vector2.ZERO
var _features: Array = []       # parsed {type, ...} dicts with Vector2 positions precomputed
var _ready := false
var _mesh_size := 0.0       # cell size the terrain meshes were built with (0 = none built yet -> analytic fallback)
var _mesh_res := 8          # heightmap resolution those meshes used (snapshot at build time)
var _mesh_anchor := Vector2.ZERO   # a known cell CENTRE (x,z) — anchors the vertex lattice height() reconstructs
var _ground_cache := {}            # per-cell "ground" override spec -> resolved Material (asphalt/plaza reuse)


func setup(cfg: Dictionary) -> void:
	amplitude = float(cfg.get("amplitude", 6.0))
	frequency = float(cfg.get("frequency", 0.012))
	seed_i = int(cfg.get("seed", 1337))
	octaves = clampi(int(cfg.get("octaves", 4)), 1, 7)
	resolution = clampi(int(cfg.get("resolution", 8)), 2, 24)
	floor_y = float(cfg.get("floor", 0.0))
	warp_amt = float(cfg.get("warp", 0.0))
	material_spec = cfg.get("material", "grass")
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = seed_i
	_noise.frequency = frequency
	_noise.fractal_octaves = octaves
	if warp_amt > 0.0:
		_warp = FastNoiseLite.new()
		_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_warp.seed = seed_i + 777
		_warp.frequency = frequency * 0.5
	_mat = GSurf.surface(material_spec)
	var isl = cfg.get("island", null)
	if isl is Dictionary:
		var ic = (isl as Dictionary).get("center", [0, 0])
		if ic is Array and (ic as Array).size() >= 2:
			_island_c = Vector2(float(ic[0]), float(ic[1]))
		_island_r = maxf(0.0, float((isl as Dictionary).get("radius", 0.0)))
		_island_shore = maxf(1.0, float((isl as Dictionary).get("shore", 60.0)))
		_island_depth = maxf(0.0, float((isl as Dictionary).get("depth", 14.0)))
	_features = []
	var feats = cfg.get("features", [])
	if feats is Array:
		for f0 in feats:
			if typeof(f0) != TYPE_DICTIONARY:
				continue
			var f := f0 as Dictionary
			var t := String(f.get("type", ""))
			# `tc` = the type as an INT, resolved ONCE here. _height_analytic (the hottest function in
			# the engine — the far skirt alone calls it 54,208 times per rebuild) used to re-derive
			# `String(f["type"])` per feature per sample; with 21 features that is ~1.1M throwaway
			# String allocations on a single frame. Comparing ints costs nothing. Keep "type" too —
			# it stays the readable/debuggable field and nothing hot reads it.
			var rec := {"type": t, "tc": (0 if t == "cone" else (1 if t == "basin" else 2))}
			if t == "cone" or t == "basin":
				var p = f.get("pos", [0, 0])
				if not (p is Array) or (p as Array).size() < 2:
					continue
				rec["pos"] = Vector2(float(p[0]), float(p[1]))
				rec["radius"] = maxf(1.0, float(f.get("radius", 20.0)))
				rec["height"] = float(f.get("height", 10.0))
				rec["depth"] = float(f.get("depth", 6.0))
				rec["crater_radius"] = maxf(0.0, float(f.get("crater_radius", 0.0)))
				rec["crater_depth"] = maxf(0.0, float(f.get("crater_depth", 0.0)))
			elif t == "canyon":
				var a = f.get("from", [0, 0])
				var b = f.get("to", [0, 0])
				if not (a is Array) or not (b is Array) or (a as Array).size() < 2 or (b as Array).size() < 2:
					continue
				rec["a"] = Vector2(float(a[0]), float(a[1]))
				rec["b"] = Vector2(float(b[0]), float(b[1]))
				rec["width"] = maxf(1.0, float(f.get("width", 8.0)))
				rec["depth"] = maxf(0.0, float(f.get("depth", 8.0)))
			else:
				continue
			_features.append(rec)
	_ready = true


static func _smooth(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)


## Surface height at world (x,z) — the height of the RENDERED terrain (the triangle mesh cell_terrain builds),
## the SINGLE ground truth for every placement/lift. The mesh discretizes the noise field into `resolution` quads
## per cell, so BETWEEN vertices the visible triangles deviate from the analytic value (worst on slopes) — lifting
## with the analytic height buried/floated feet by that error. This reconstructs the containing quad with the SAME
## lattice math as cell_terrain, samples the noise at its 4 vertex positions, and interpolates on the triangle the
## mesh actually draws there: placement height == rendered height by construction. Still deterministic + seamless
## (adjacent quads/cells share vertex samples; both triangle formulas agree along the shared diagonal and edges).
## Before the first cell_terrain() call there is no mesh lattice to match — falls back to the analytic field
## (the chunk streamer's pre-build spawn lift hits this, and it drops onto the collider from +y anyway).
func height(x: float, z: float) -> float:
	if not _ready:
		return floor_y
	if _mesh_size <= 0.0:
		return _height_analytic(x, z)   # no terrain mesh built yet — nothing rendered to match
	var half := _mesh_size * 0.5
	var step := _mesh_size / float(_mesh_res)
	# containing CELL on the anchor's lattice (floori = floor division, so negative coords index correctly),
	# then its centre — every streamed cell tiles with spacing _mesh_size, so one anchor reaches them all
	var cix := floori((x - (_mesh_anchor.x - half)) / _mesh_size)
	var ciz := floori((z - (_mesh_anchor.y - half)) / _mesh_size)
	var cx := _mesh_anchor.x + float(cix) * _mesh_size
	var cz := _mesh_anchor.y + float(ciz) * _mesh_size
	# containing QUAD inside the cell — identical lx0/lz0 expressions to cell_terrain's vertex loop
	var lx := x - cx
	var lz := z - cz
	var ix := clampi(floori((lx + half) / step), 0, _mesh_res - 1)
	var iz := clampi(floori((lz + half) / step), 0, _mesh_res - 1)
	var lx0 := -half + float(ix) * step
	var lz0 := -half + float(iz) * step
	var lx1 := lx0 + step
	var lz1 := lz0 + step
	var h00 := _height_analytic(cx + lx0, cz + lz0)   # quad corner a (cell_terrain's naming)
	var h10 := _height_analytic(cx + lx1, cz + lz0)   # b
	var h11 := _height_analytic(cx + lx1, cz + lz1)   # c
	var h01 := _height_analytic(cx + lx0, cz + lz1)   # d
	var fx := clampf((lx - lx0) / step, 0.0, 1.0)
	var fz := clampf((lz - lz0) / step, 0.0, 1.0)
	# the mesh splits every quad along the a→c diagonal (fx == fz): triangle (a,b,c) covers fx >= fz, (a,c,d)
	# the rest. Each branch is that triangle's plane (== barycentric interp); both agree on the diagonal itself.
	if fx >= fz:
		return h00 + fx * (h10 - h00) + fz * (h11 - h10)
	return h00 + fz * (h01 - h00) + fx * (h11 - h01)


## Approximate surface normal at (x,z) via finite differences — for orienting props to the slope if wanted.
## Deliberately ANALYTIC (the smooth field, not the triangle mesh): it's the smooth limit of the rendered surface,
## within O(step²·curvature) of any facet normal (sub-degree at default settings) and doesn't pop at triangle
## edges the way facet normals would. It also feeds the mesh's own vertex normals (_t/_ft) for smooth shading.
func normal_at(x: float, z: float) -> Vector3:
	var e := 0.5
	var hl := _height_analytic(x - e, z)
	var hr := _height_analytic(x + e, z)
	var hd := _height_analytic(x, z - e)
	var hu := _height_analytic(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## Build the floor for ONE cell: a heightmap MeshInstance3D (a grid sampling the analytic field at WORLD coords —
## the same vertices height() interpolates between) + a StaticBody3D trimesh collider that exactly matches what's
## rendered (so the player walks on the visible ground).
## Returns a Node3D positioned at the cell's world centre; the mesh is local to it.
func cell_terrain(centre: Vector3, size: float, ground_override = null, collide := true) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(centre.x, 0.0, centre.z)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := resolution
	var step := size / float(n)
	var half := size * 0.5
	# record the mesh lattice so height() can return the RENDERED surface (same quads, same diagonal) everywhere;
	# streamed cells all tile with spacing `size`, so any one cell's centre anchors the whole lattice
	_mesh_size = size
	_mesh_res = n
	_mesh_anchor = Vector2(centre.x, centre.z)
	# vertex grid: local (lx,lz) in [-half, half]; y = analytic height at WORLD coord; UV in [0,1] across the cell
	for iz in n:
		for ix in n:
			var lx0 := -half + float(ix) * step
			var lz0 := -half + float(iz) * step
			var lx1 := lx0 + step
			var lz1 := lz0 + step
			var a := _vert(centre, lx0, lz0)
			var b := _vert(centre, lx1, lz0)
			var c := _vert(centre, lx1, lz1)
			var d := _vert(centre, lx0, lz1)
			# two TOP-FACING triangles. Winding (a,b,c)/(a,c,d) is CW-from-above = Godot front-face (visible from
			# the sky, not culled); normals are set EXPLICITLY to the upward heightfield normal (generate_normals
			# would derive them from winding and point them DOWN — wrong for lighting).
			_t(st, centre, a, b, c, size)
			_t(st, centre, a, c, d, size)
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	# Per-cell GROUND override: a city cell can paint asphalt/plaza over the global terrain material
	# (chunk_manager passes the cell's "ground" spec here when it differs from the world default).
	# The patch conforms to the terrain slope — same mesh, only the material changes. Resolved
	# materials are cached by spec so a whole city of asphalt cells shares one material instance.
	mi.material_override = _resolve_ground(ground_override) if ground_override != null else _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # big ground never casts into its own acne
	root.add_child(mi)
	# Wave 4: FAR PROXIES pass collide=false — proxies are silhouette-only (physics lives in the
	# resident ring), so baking a trimesh collider here only to have chunk_manager strip it later was
	# pure waste (~40 proxies, trimesh bake is the costly part). Resident cells keep collide=true.
	if collide:
		mi.create_trimesh_collision()   # adds a StaticBody3D child whose shape exactly matches the surface
		# put the generated body on the world collision layer so the player/enemies collide with it
		for ch in mi.get_children():
			if ch is StaticBody3D:
				(ch as StaticBody3D).collision_layer = 1
				(ch as StaticBody3D).add_to_group("gogi_terrain")   # Wave 5: gogiSolids() excludes the ground
	return root


# Resolve a per-cell "ground" spec (surfaces.gd preset string, or an [r,g,b] colour array) to a
# Material, cached by spec so a city of asphalt cells shares ONE instance. Falls back to the global
# terrain material on any bad spec so a city cell never renders untextured.
func _resolve_ground(spec) -> Material:
	var key := str(spec)
	if _ground_cache.has(key):
		return _ground_cache[key]
	var mat: Material = GSurf.surface(spec)
	if mat == null:
		mat = _mat
	_ground_cache[key] = mat
	return mat


# The far HORIZON skirt — one coarse, large-radius heightmap mesh covering `radius` metres around `centre`,
# sampling the SAME analytic field as the cells' vertices so it lines up with them. Rendered slightly BELOW them
# (the detailed cells cover it near the player; only the DISTANCE shows the skirt) and recentred on the player as
# they move. NO collider (the player only ever stands on detailed cells). This is what gives a terrain world a
# real landscape stretching to the (fog-faded) horizon instead of an abrupt resident-ring edge.
func far_skirt(centre: Vector3, radius: float, samples: int) -> MeshInstance3D:
	return far_skirt_wrap(far_skirt_mesh(centre, radius, samples))


# MESH-ONLY half of far_skirt(), split out so it can run on a WORKER THREAD.
#
# WHY: measured at 360ms inside chunk_manager's cell-cross rebuild on device — the single biggest
# frame spike in the game. At 44 samples this is 1,936 quads, and every corner calls
# _height_analytic() plus normal_at() (which samples again), so it is on the order of 50k noise
# evaluations in GDScript. Nothing here touches the scene: pure math into a SurfaceTool, which is
# exactly the shape of work that belongs off the frame thread.
func far_skirt_mesh(centre: Vector3, radius: float, samples: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(8, samples)
	var step := (radius * 2.0) / float(n)
	var off := -0.5   # sit just under the detailed terrain so the seam at the ring edge is invisible at distance
	for iz in n:
		for ix in n:
			var x0 := centre.x - radius + float(ix) * step
			var z0 := centre.z - radius + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			var a := Vector3(x0, _height_analytic(x0, z0) + off, z0)
			var b := Vector3(x1, _height_analytic(x1, z0) + off, z0)
			var c := Vector3(x1, _height_analytic(x1, z1) + off, z1)
			var d := Vector3(x0, _height_analytic(x0, z1) + off, z1)
			_ft(st, a, b, c)   # same CW-from-above winding + explicit up normals as cell_terrain
			_ft(st, a, c, d)
	st.generate_tangents()
	return st.commit()


# MAIN-THREAD half: wrap a finished skirt mesh in its instance. Identical properties to the old
# inline version, so a threaded build and a synchronous one produce the same node.
func far_skirt_wrap(mesh: ArrayMesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _ft(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for v in [a, b, c]:
		st.set_normal(normal_at(v.x, v.z))
		st.set_uv(Vector2(v.x * 0.05, v.z * 0.05))
		st.add_vertex(v)   # world-space verts (the MeshInstance sits at the origin)


# ─────────────────────────────── internals ───────────────────────────────

# The underlying ANALYTIC noise field: deterministic + seamless world-space y at (x,z). The mesh builders
# (cell_terrain, far_skirt) sample it AT VERTEX POSITIONS; anything placed BETWEEN vertices must go through
# height() (the interpolated rendered surface) instead, or it sinks/floats by the discretization error.
func _height_analytic(x: float, z: float) -> float:
	if not _ready:
		return floor_y
	var wx := x
	var wz := z
	if _warp != null:
		wx += _warp.get_noise_2d(x, z) * (1.0 / maxf(frequency, 0.0001)) * warp_amt * 0.15
		wz += _warp.get_noise_2d(z, x) * (1.0 / maxf(frequency, 0.0001)) * warp_amt * 0.15
	var h := floor_y + _noise.get_noise_2d(wx, wz) * amplitude
	# ISLAND falloff: beyond the radius the land sinks smoothly below the water into the sea bed,
	# so one landmass ringed by open ocean falls out of the analytic field (beaches at the crossing).
	if _island_r > 0.0:
		var dc := Vector2(x, z).distance_to(_island_c)
		if dc > _island_r:
			h -= _island_depth * _smooth((dc - _island_r) / _island_shore)
	# LANDFORM features: volcano/mountain cones (with optional crater), lake/pit basins, river/gorge canyons.
	for f0 in _features:
		var f: Dictionary = f0
		var t: int = f["tc"]   # int code precomputed at parse — see the `tc` note in the loader
		if t == 0:   # cone
			var p: Vector2 = f["pos"]
			var r := float(f["radius"])
			var d := Vector2(x, z).distance_to(p)
			if d < r:
				h += float(f["height"]) * _smooth(1.0 - d / r)
				var cr := float(f["crater_radius"])
				if cr > 0.0 and d < cr:
					h -= float(f["crater_depth"]) * _smooth(1.0 - d / cr)
		elif t == 1:   # basin
			var pb: Vector2 = f["pos"]
			var rb := float(f["radius"])
			var db := Vector2(x, z).distance_to(pb)
			if db < rb:
				h -= float(f["depth"]) * _smooth(1.0 - db / rb)
		elif t == 2:   # canyon
			var a: Vector2 = f["a"]
			var b: Vector2 = f["b"]
			var w := float(f["width"])
			var ab := b - a
			var tt := 0.0
			var ab2 := ab.length_squared()
			if ab2 > 0.0001:
				tt = clampf((Vector2(x, z) - a).dot(ab) / ab2, 0.0, 1.0)
			var dseg := Vector2(x, z).distance_to(a + ab * tt)
			if dseg < w:
				h -= float(f["depth"]) * _smooth(1.0 - dseg / w)
	return h


func _vert(centre: Vector3, lx: float, lz: float) -> Vector3:
	return Vector3(lx, _height_analytic(centre.x + lx, centre.z + lz), lz)


# Emit one triangle: explicit UPWARD per-vertex normals (smooth heightfield normal) + a planar UV (1 tile per
# cell; the triplanar material ignores UV anyway). Winding is the caller's (CW-from-above = front).
func _t(st: SurfaceTool, centre: Vector3, a: Vector3, b: Vector3, c: Vector3, size: float) -> void:
	for v in [a, b, c]:
		st.set_normal(normal_at(centre.x + v.x, centre.z + v.z))
		st.set_uv(Vector2((v.x + size * 0.5) / size, (v.z + size * 0.5) / size))
		st.add_vertex(v)
