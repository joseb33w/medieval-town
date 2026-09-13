class_name GShapes
## SHAPE VOCABULARY — the FORM axis of the construction system. A small, VETTED, render-tested library of
## parametric solid factories. The agent only PARAMETERIZES these (it never emits raw vertices), so any
## architectural silhouette — house, pyramid, obelisk, pylon, tower, column, dome, spire — composes from the
## SAME vocabulary. Theme-agnostic: a pyramid and a gable house are two parameterizations, not two generators.
##
## Built mostly from Godot built-in primitive meshes (BoxMesh / CylinderMesh with top+bottom radius / PrismMesh /
## SphereMesh hemisphere) + transforms, so there is almost no hand-authored geometry to get wrong. The ONLY
## ArrayMesh shape is the rectangular frustum/pyramid (no primitive covers a rect base tapering to a smaller rect
## or a point); its faces are emitted with outward normals + correct winding computed from the convex centroid,
## so it can never render inside-out. gl_compatibility / WebGL2-safe.
##
## CONTRACT: every factory returns a MeshInstance3D (or Node3D for composed shapes) whose visual BASE sits at
## local y=0 and is CENTERED at local x=z=0 — so callers place a shape by its footprint corner/centre like a
## building. Materials are applied by the caller (surfaces.gd); add_collider() wraps a solid collider.

# ─────────────────────────────── primitive-based solids ───────────────────────────────

## A box. size = (width, height, depth). Base at y=0.
static func box(size: Vector3) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _mi(m, size.y * 0.5)


## A round/cone/n-gon vertical solid. bottom_r/top_r let it taper (top_r=0 -> cone/spire); sides controls the
## cross-section (sides=4 -> a square pier, 6 -> hex column, 8 -> octagon, >=24 -> round column). Base at y=0.
static func cylinder(bottom_r: float, top_r: float, height: float, sides: int = 24) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.bottom_radius = maxf(0.0, bottom_r)
	m.top_radius = maxf(0.0, top_r)
	m.height = height
	m.radial_segments = maxi(3, sides)
	m.rings = 1
	return _mi(m, height * 0.5)


## An n-sided straight prism (column/pier). sides=6 hex, 8 octagon, etc.
static func prism_ngon(sides: int, radius: float, height: float) -> MeshInstance3D:
	return cylinder(radius, radius, height, sides)


## A symmetric wedge / gable cross-section (triangular prism). For a GABLE ROOF: size=(span, ridge_height, depth)
## with the ridge running along Z; the two upper faces are the slopes, the ±Z faces are the gable ends. Base at y=0.
static func wedge(size: Vector3) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = size
	return _mi(m, size.y * 0.5)


## A gable roof spanning footprint (x=span, y=depth) rising to ridge_height. (Alias of a wedge sized for a roof.)
static func roof_gable(footprint: Vector2, ridge_height: float) -> MeshInstance3D:
	return wedge(Vector3(footprint.x, ridge_height, footprint.y))


## A single-slope ramp (right-triangle prism) — for stairs substitutes, shed roofs, embankments. Rises along +X
## across `run`, by `rise`, `width` deep along Z. (PrismMesh with the peak pushed fully to one side.)
static func ramp(run: float, rise: float, width: float) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = Vector3(run, rise, width)
	m.left_to_right = 0.0   # peak at one edge -> a right triangle, i.e. a single slope
	return _mi(m, rise * 0.5)


## A hemispherical / squashed dome. radius = base radius, height = how tall (a clipped/flattened dome if
## height<radius, a stretched one if >). Base at y=0.
static func dome(radius: float, height: float, segments: int = 16) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = height          # for a hemisphere, `height` IS the vertical extent (base at y=0)
	m.is_hemisphere = true
	m.radial_segments = maxi(6, segments * 2)
	m.rings = maxi(3, segments)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	return mi


# ─────────────────────────────── ArrayMesh: rectangular frustum / pyramid ───────────────────────────────

## A rectangular solid that tapers with height: base (x=width, y=depth) at y=0 -> top (x,y) at y=height.
##   top == base  -> a box;  top < base -> battered/tapered (pylon, obelisk shaft, tower setback);
##   top == (0,0) -> a true pyramid (4 triangular faces to an apex). Supports non-uniform taper.
## The ONE hand-built shape — faces emitted with convex-outward normals + Godot-correct winding, so it is solid
## and never inside-out. Base at y=0, centred at x=z=0.
static func frustum(base: Vector2, top: Vector2, height: float) -> MeshInstance3D:
	var bx := base.x * 0.5
	var bz := base.y * 0.5
	var b := [
		Vector3(-bx, 0.0, -bz), Vector3(bx, 0.0, -bz),
		Vector3(bx, 0.0, bz), Vector3(-bx, 0.0, bz),
	]
	var centroid := Vector3(0.0, height * 0.5, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if top.x <= 0.001 and top.y <= 0.001:
		# pyramid: 4 triangular sides to an apex + a base quad
		var apex := Vector3(0.0, height, 0.0)
		for i in 4:
			_emit_face(st, [b[i], b[(i + 1) % 4], apex], centroid)
		_emit_face(st, [b[0], b[1], b[2], b[3]], centroid)
	else:
		var tx := top.x * 0.5
		var tz := top.y * 0.5
		var t := [
			Vector3(-tx, height, -tz), Vector3(tx, height, -tz),
			Vector3(tx, height, tz), Vector3(-tx, height, tz),
		]
		for i in 4:
			_emit_face(st, [b[i], b[(i + 1) % 4], t[(i + 1) % 4], t[i]], centroid)
		_emit_face(st, [b[0], b[1], b[2], b[3]], centroid)   # bottom
		_emit_face(st, [t[0], t[1], t[2], t[3]], centroid)   # top
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	return mi


## A true pyramid (base -> apex). Convenience over frustum().
static func pyramid(base: Vector2, height: float) -> MeshInstance3D:
	return frustum(base, Vector2.ZERO, height)


# ─────────────────────────────── composed: a column ───────────────────────────────

## A column = round shaft + an optional base plinth + an optional capital flare. capital/base are simple
## frustum flares (a Meshy lotus/Doric/etc. capital can be swapped onto the slot by the caller). Returns a Node3D.
static func column(radius: float, height: float, sides: int = 24, capital: bool = true, plinth: bool = true) -> Node3D:
	var root := Node3D.new()
	var cap_h := height * 0.10 if capital else 0.0
	var base_h := height * 0.06 if plinth else 0.0
	var shaft_h := height - cap_h - base_h
	if plinth:
		var p := cylinder(radius * 1.25, radius * 1.1, base_h, sides)
		root.add_child(p)
	var shaft := cylinder(radius * 1.05, radius * 0.92, shaft_h, sides)   # slight entasis taper
	shaft.position.y = base_h
	root.add_child(shaft)
	if capital:
		var c := cylinder(radius * 0.95, radius * 1.3, cap_h, sides)       # flare out at the top
		c.position.y = base_h + shaft_h
		root.add_child(c)
	return root


# ─────────────────────────────── composed: stairs + wall-with-opening ───────────────────────────────

## A straight flight of STAIRS: stacked step-box visuals + ONE hidden RAMP collider (a rotated box
## StaticBody3D spanning the flight — the standard smooth-climb trick: the player walks up via
## move_and_slide with no per-step jitter; the step boxes are VISUAL-ONLY). Base at y=0, ascending
## +Y along -Z: the flight's foot is at z=0 and the top tread surface reaches y=`rise` at z=-`run`,
## width centred on x=0 (the caller rotates/positions the returned Node3D). The ramp plane runs half
## a step ABOVE the y=0->rise diagonal so feet track the tread tops (±half a step at either end).
static func stairs(width: float, rise: float, run: float, steps: int, material: Material = null) -> Node3D:
	var root := Node3D.new()
	var n := maxi(2, steps)
	var step_h := rise / float(n)
	var step_d := run / float(n)
	for i in n:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(width, step_h * float(i + 1), step_d)   # stacked-solid steps: no see-through gaps
		mi.mesh = bm
		mi.position = Vector3(0.0, step_h * float(i + 1) * 0.5, -(float(i) + 0.5) * step_d)
		if material != null:
			mi.material_override = material
		root.add_child(mi)
	# the ONE ramp collider: a thin box tilted to the flight's slope. The top surface runs from
	# GROUND LEVEL at the entry (z=+step_d/2, y=0) to the landing (z=-run, y=rise) — starting AT
	# ground is load-bearing: a surface that begins half a step up presents a small vertical face
	# that move_and_slide treats as a WALL (no step-up in Godot), so the player just stops at the
	# flight's foot instead of climbing (caught by the Wave-2 walk-up probe).
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var z0 := step_d * 0.5                            # entry point (touches ground just before step 1)
	var dz := z0 - (-run)                             # horizontal extent of the ramp surface
	bs.size = Vector3(width, 0.3, sqrt(dz * dz + rise * rise))
	cs.shape = bs
	var ang := atan2(rise, dz)                        # rotation about +X lifts the -Z end
	cs.rotation.x = ang
	var mid := Vector3(0.0, rise * 0.5, (z0 - run) * 0.5)   # ramp-surface midpoint
	var nrm := Vector3(0.0, cos(ang), sin(ang))       # surface normal after the tilt
	cs.position = mid - nrm * 0.15                    # sink the box half its thickness under the surface
	body.add_child(cs)
	root.add_child(body)
	return root


## A WALL SLAB with an optional rectangular OPENING (doorway / arch / stairwell edge): composed from
## 2-3 boxes (left jamb, right jamb, lintel) so the gap is genuinely walkable-through — the primitive
## both doorways and stairwell edges build on. The wall runs along X (`w` wide, `h` tall, `t` thick
## along Z), base at y=0, centred at x=z=0; the opening rises from y=0 and `opening_center_x` slides
## it along the wall. opening_w<=0 (or opening_h<=0) -> ONE solid box (a plain slab). Every box gets
## a matching BoxShape3D on ONE shared StaticBody3D; `solid=false` skips collision entirely (e.g. a
## visual-only interior lining layer). Materials via `material` (or the caller's set_material).
static func wall_with_opening(w: float, h: float, t: float, opening_w: float, opening_h: float, opening_center_x: float, material: Material = null, solid: bool = true) -> Node3D:
	var root := Node3D.new()
	var ow := clampf(opening_w, 0.0, maxf(0.0, w - 0.2))
	var oh := clampf(opening_h, 0.0, h)
	var pieces: Array = []   # [size: Vector3, centre: Vector3] per box
	if ow <= 0.01 or oh <= 0.01:
		pieces.append([Vector3(w, h, t), Vector3(0.0, h * 0.5, 0.0)])
	else:
		var ocx := clampf(opening_center_x, -w * 0.5 + ow * 0.5, w * 0.5 - ow * 0.5)
		var lx1 := ocx - ow * 0.5   # opening's left edge
		var rx0 := ocx + ow * 0.5   # opening's right edge
		if lx1 + w * 0.5 > 0.01:
			pieces.append([Vector3(lx1 + w * 0.5, h, t), Vector3((lx1 - w * 0.5) * 0.5, h * 0.5, 0.0)])
		if w * 0.5 - rx0 > 0.01:
			pieces.append([Vector3(w * 0.5 - rx0, h, t), Vector3((rx0 + w * 0.5) * 0.5, h * 0.5, 0.0)])
		if h - oh > 0.01:
			pieces.append([Vector3(ow, h - oh, t), Vector3(ocx, (oh + h) * 0.5, 0.0)])
	var body: StaticBody3D = null
	if solid:
		body = StaticBody3D.new()
		body.collision_layer = 1
	for pc in pieces:
		var sz: Vector3 = pc[0]
		var ct: Vector3 = pc[1]
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		mi.mesh = bm
		mi.position = ct
		if material != null:
			mi.material_override = material
		root.add_child(mi)
		if body != null:
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = sz
			cs.shape = bs
			cs.position = ct
			body.add_child(cs)
	if body != null:
		root.add_child(body)
	return root


# ─────────────────────────────── colliders + materials ───────────────────────────────

## A LADDER — two vertical side-rail boxes (along X at ±width/2) + horizontal rungs every ~0.3m. Base at y=0,
## centred at x=z=0, rising +Y to `height`; the climb face is the ±Z plane. Returns a Node3D. NO collider ON
## PURPOSE — it is WALK-THROUGH: the player-controller drives the vertical climb along Y (interaction.gd
## registers it as a "Climb" target), and a solid ladder would read as a WALL and block the very ascent it
## exists for. A wood/metal-ish material is baked in (set_material) so a placed ladder is visible without a
## surface pass (a caller may still override via set_material); meta "ladder_h" carries the climb extent so a
## placement/interaction path can read it back off the node.
static func ladder(height: float, width := 0.5) -> Node3D:
	var root := Node3D.new()
	var h := maxf(0.6, height)
	var rail := 0.06                          # side-rail / rung cross-section
	var hw := maxf(0.15, width) * 0.5
	for sx in [-hw, hw]:                       # the two vertical rails, base at y=0 -> top at y=h
		var r := box(Vector3(rail, h, rail))
		r.position.x = sx
		root.add_child(r)
	var gap := 0.3                             # rung spacing (~0.3 m)
	var n := maxi(1, int(h / gap))
	for i in range(1, n):                      # rungs between the rails (skip i=0 -> at the floor)
		var rung := box(Vector3(hw * 2.0 + rail, rail, rail))
		rung.position.y = gap * float(i) - rail * 0.5   # box centres its own y at rail*0.5, so offset back
		root.add_child(rung)
	set_material(root, _ladder_mat())
	root.set_meta("ladder_h", h)
	return root


## Apply a material to every MeshInstance3D under `node` (or to a single MeshInstance3D).
static func set_material(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for c in node.get_children():
		set_material(c, mat)


## Wrap a built shape with a solid STATIC collider so the player can't walk through it. mode "box" (cheap, from
## AABB) or "mesh" (trimesh, exact — for walk-into shells/arches). Returns the same node, collider added as a child.
static func add_collider(node: Node3D, mode: String = "box") -> Node3D:
	if mode == "mesh":
		for mi in _all_meshes(node):
			mi.create_trimesh_collision()
	elif mode == "trunk":
		# TREES: a slim vertical TRUNK column at the canopy centre instead of a canopy-wide box, so the
		# player walks freely through the foliage and only the narrow trunk blocks them. Radius ~ a small
		# fraction of the footprint (bounded), height = the full model so it can't be walked/jumped over.
		var tab := _aabb(node)
		if tab.size.y > 0.01:
			var tbody := StaticBody3D.new()
			tbody.collision_layer = 1
			var tcs := CollisionShape3D.new()
			var cyl := CylinderShape3D.new()
			cyl.radius = clampf(minf(tab.size.x, tab.size.z) * 0.03, 0.03, 0.08)
			cyl.height = tab.size.y
			tcs.shape = cyl
			tcs.position = Vector3(0.0, tab.position.y + tab.size.y * 0.5, 0.0)   # pole at the trunk PIVOT (x=z=0), not the offset canopy AABB centre
			tbody.add_child(tcs)
			node.add_child(tbody)
	else:
		var ab := _aabb(node)
		if ab.size.length() > 0.01:
			var body := StaticBody3D.new()
			body.collision_layer = 1
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = ab.size
			cs.shape = box
			cs.position = ab.position + ab.size * 0.5
			body.add_child(cs)
			node.add_child(body)
	return node


# ─────────────────────────────── internals ───────────────────────────────

# A plain wood/metal-ish material baked into the ladder factory (the ONE built-in that ships a default
# material — a placed ladder must read as a rung structure even without a surface pass; a caller may still
# override via set_material). Kept private + minimal; the surface cookbook (surfaces.gd) owns richer looks.
static func _ladder_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40, 0.27, 0.15)   # weathered wood; a metal ladder overrides via set_material
	m.roughness = 0.8
	return m


static func _mi(mesh: Mesh, base_offset_y: float) -> MeshInstance3D:
	# Built-in primitive meshes are centred at the origin; lift by half-height so the BASE rests at y=0.
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position.y = base_offset_y
	return mi


# Emit one convex, planar face (tri or quad) with an OUTWARD normal (away from the solid's centroid) and
# Godot-correct CLOCKWISE-from-outside winding (Godot's front-face convention) — so it is lit right AND not
# back-culled. Convention-independent: derived from geometry, never from the caller's vertex order.
static func _emit_face(st: SurfaceTool, verts: Array, centroid: Vector3) -> void:
	var v0: Vector3 = verts[0]
	var v1: Vector3 = verts[1]
	var v2: Vector3 = verts[2]
	var g := (v1 - v0).cross(v2 - v0)
	if g.length() < 1e-9:
		return   # degenerate
	var fc := Vector3.ZERO
	for v in verts:
		fc += v
	fc /= float(verts.size())
	var outward := fc - centroid
	var n: Vector3
	var ordered: Array
	if g.dot(outward) > 0.0:
		# current order is CCW-from-outside -> reverse to get CW (front-facing); normal already outward
		n = g.normalized()
		ordered = verts.duplicate()
		ordered.reverse()
	else:
		n = (-g).normalized()
		ordered = verts
	# fan-triangulate the (convex) face
	for ti in range(1, ordered.size() - 1):
		for vert in [ordered[0], ordered[ti], ordered[ti + 1]]:
			st.set_normal(n)
			st.set_uv(_planar_uv(vert, n))
			st.add_vertex(vert)


# Simple world-space planar UV (1 unit = 1 tile). Triplanar materials ignore this; it keeps non-triplanar
# materials from stretching catastrophically.
static func _planar_uv(v: Vector3, n: Vector3) -> Vector2:
	var an := Vector3(absf(n.x), absf(n.y), absf(n.z))
	if an.y >= an.x and an.y >= an.z:
		return Vector2(v.x, v.z)
	if an.x >= an.z:
		return Vector2(v.z, v.y)
	return Vector2(v.x, v.y)


static func _all_meshes(node: Node) -> Array:
	var out: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


static func _aabb(node: Node3D) -> AABB:
	# DETACHMENT-SAFE (mirrors AreaBuilder._world_aabb): accumulates
	# transforms manually — structure parts are measured while still
	# detached, where global_transform is IDENTITY + an error line.
	var merged := AABB()
	var first := true
	var stack: Array = [[node, node.transform]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		for c in n.get_children():
			var cx := xf
			if c is Node3D:
				cx = xf * (c as Node3D).transform
			stack.append([c, cx])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var wa: AABB = xf * (n as MeshInstance3D).get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged
