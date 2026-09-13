class_name GBuild
## STRUCTURE BUILDER — composes shapes.gd (FORM) + surfaces.gd (SURFACE) into a complete building from ONE
## world.json spec. The profile + cap parameters make a suburban HOUSE, a Vegas TOWER, an Egyptian PYRAMID, a
## temple PYLON, a ziggurat, an obelisk — all from the SAME function, no per-theme generator. Returns a Node3D
## (base at y=0, centred at x=z=0) holding the composed meshes + a solid collider, ready to place on a lot.
##
## SCHEMA (world.json `structures: [ {...} ]`, a cell-level array):
##   pos            [x,z] cell-local placement (like props)
##   footprint      [w,d] base size in metres            (default [8,8])
##   floors         storeys                              (default 1)   -> height = floors*floor_height
##   height         explicit total height                (overrides floors)
##   floor_height   metres per storey                    (default 3.2)
##   profile        "vertical"|"batter"|"taper"|"setback"|"ziggurat"|"pyramid"   (the per-Z form)
##   batter/shrink/steps   profile tuning
##   cap            "flat"|"gable"|"hip"|"pyramid"|"pyramidion"|"dome"|"spire"    (the roof/top)
##   roof_height    explicit cap height
##   facade         "plain"|"windows" (or {type:"windows",glow:[r,g,b],lit:E})   (wall treatment)
##   material       surface preset/spec for the body (surfaces.gd)
##   roof_material  surface for the cap (defaults to material)
##   rot, scale     yaw degrees, uniform scale
##   collider       "box" (default) | "mesh" (walk-into shell)
##   sign_light     optional {color:[r,g,b], energy, range} -> an OmniLight pool at the roofline (neon spill)
##   interior       OPT-IN enterable shell (`"vertical"` profile only): true, or
##                  {door_face:"n"|"s"|"e"|"w" (default "s" = the
##                  -Z face), rooms:0|1|2 (ground-floor partition rooms, default 0), lit:true (default)}.
##                  EVERY enterable interior gets a real openable/closable swinging door (a legacy
##                  `door:"arch"` — a door-less opening — is coerced to a hinged leaf).
##                  -> real doorway + an openable/closable swinging door leaf (node group "gogi_door"),
##                  plastered interior lining, per-storey floor slabs joined by walkable stairs through a
##                  stairwell cutout (floors >= 2), and a budgeted warm interior light. The exterior
##                  footprint/silhouette/facade are unchanged. NO "interior" key -> solid building,
##                  identical to before. (structure(spec, true) = far-PROXY mode: interior ignored.)

const FLOOR_H := 3.2
# interior-shell dimensions (metres)
const WALL_T := 0.3      # exterior wall thickness
const SLAB_T := 0.25     # storey / roof-deck slab thickness
const LINING_T := 0.05   # interior plaster lining (visual-only)
const DOOR_W := 1.4      # doorway width
const DOOR_H := 2.2      # doorway height
const STAIR_W := 1.2     # stair flight width
const MIN_STOREY := 2.6   # minimum floor-to-floor height — interiors never squish below this even when an explicit `height` is short relative to `floors` (keeps ceilings/doorways/stairs human-scale)


# `proxy=true` = far-proxy mode: ALWAYS the solid body — far proxies must never carry interiors,
# "gogi_door" leaves, or lights (chunk_manager.build_proxy passes true; its strip pass removes the
# collider this mode still adds).
static func structure(spec: Dictionary, proxy: bool = false) -> Node3D:
	var root := Node3D.new()
	var foot := _v2(spec.get("footprint", [8, 8]))
	var floors := maxi(1, int(spec.get("floors", 1)))
	var fh := float(spec.get("floor_height", FLOOR_H))
	var height := float(spec.get("height", float(floors) * fh))
	var profile := String(spec.get("profile", "vertical")).to_lower()
	var cap := String(spec.get("cap", "flat")).to_lower()
	var facade = spec.get("facade", "plain")
	var body_mat := GSurf.surface(spec.get("material", "concrete"))
	var roof_mat := GSurf.surface(spec.get("roof_material", spec.get("material", "concrete")))
	# opt-in enterable interior (vertical profile only; needs a sane footprint to hollow out)
	var idict := {} if (proxy or foot.x < 3.0 or foot.y < 3.0) else _interior_spec(spec)
	# An enterable building with NO explicit cap used to fall through to a bare flat slab (and the
	# "cone" complaints come from world.json authoring cap:"spire"). Give a capless enterable building
	# a clean finished PARAPET roofline instead of a bare deck — never a cone. Explicit caps (incl.
	# spire) and solid non-enterable buildings are untouched.
	if not spec.has("cap") and not idict.is_empty():
		cap = "parapet"
	var shelled := false

	var top_foot := foot   # footprint at the body's TOP, so the cap is sized to it

	match profile:
		"batter", "taper":
			var amt := float(spec.get("batter", 0.18 if profile == "batter" else 0.35))
			top_foot = foot * (1.0 - amt)
			var fr := GShapes.frustum(foot, top_foot, height)
			GShapes.set_material(fr, body_mat)
			root.add_child(fr)
		"pyramid":
			var py := GShapes.pyramid(foot, height)
			GShapes.set_material(py, body_mat)
			root.add_child(py)
			top_foot = Vector2.ZERO
		"setback", "ziggurat":
			var steps := maxi(2, int(spec.get("steps", 3)))
			var step_h := height / float(steps)
			var shrink := float(spec.get("shrink", 0.7 if profile == "ziggurat" else 0.82))
			var cur := foot
			var y := 0.0
			for s in steps:
				var blk: MeshInstance3D
				if profile == "ziggurat":
					blk = GShapes.frustum(cur, cur * 0.92, step_h)   # slight batter per tier
					GShapes.set_material(blk, body_mat)
				else:
					blk = GShapes.box(Vector3(cur.x, step_h, cur.y))
					_apply_facade(blk, facade, body_mat, cur, maxi(1, int(step_h / fh)), spec)
				blk.position.y = y
				root.add_child(blk)
				y += step_h
				cur = cur * shrink
			top_foot = cur / shrink
		_:   # "vertical" (default)
			if idict.is_empty():
				var bx := GShapes.box(Vector3(foot.x, height, foot.y))
				_apply_facade(bx, facade, body_mat, foot, floors, spec)
				root.add_child(bx)
			else:
				_build_shell(root, idict, foot, floors, height, facade, body_mat, roof_mat, spec)
				shelled = true

	_add_cap(root, cap, top_foot, height, roof_mat, spec, shelled)

	# optional sign light-pool at the roofline (the neon-spill / self-illuminated-city lever)
	if typeof(spec.get("sign_light", null)) == TYPE_DICTIONARY:
		var sl: Dictionary = spec["sign_light"]
		var lp := GSurf.sign_light(_col(sl.get("color", [1, 0.4, 0.7])),
			float(sl.get("energy", 2.0)), float(sl.get("range", maxf(foot.x, foot.y))))
		lp.position.y = height
		root.add_child(lp)

	# collider FIRST (root still at identity, so the AABB is clean), THEN transform — the collider rides along.
	# An interior shell owns its colliders PIECEWISE (walls/slabs/stairs/leaf); wrapping it in the
	# whole-AABB box here would seal the doorway shut. Wave 4: a far PROXY shell (proxy=true) is
	# silhouette-only — skip its collider at the source (chunk_manager's strip pass used to free it).
	if not shelled and not proxy:
		GShapes.add_collider(root, String(spec.get("collider", "box")))
	var rot := float(spec.get("rot", 0.0))
	if rot != 0.0:
		root.rotation.y = deg_to_rad(rot)
	var sc := float(spec.get("scale", 1.0))
	if sc > 0.0 and sc != 1.0:
		root.scale = Vector3(sc, sc, sc)
	return root


# ─────────────────────────────── facade + cap ───────────────────────────────

static func _apply_facade(node: Node3D, facade, body_mat: StandardMaterial3D, foot: Vector2, floors: int, spec: Dictionary) -> void:
	GShapes.set_material(node, _facade_mat(facade, body_mat, foot, floors, spec))


# Resolve the facade treatment to its MATERIAL (shared by the solid body and the shell's walls).
static func _facade_mat(facade, body_mat: StandardMaterial3D, foot: Vector2, floors: int, spec: Dictionary) -> StandardMaterial3D:
	var is_windows := false
	var fdict := {}
	if typeof(facade) == TYPE_STRING:
		is_windows = String(facade).to_lower() == "windows"
	elif typeof(facade) == TYPE_DICTIONARY:
		fdict = facade
		is_windows = String(fdict.get("type", "")).to_lower() == "windows"
	if is_windows:
		var bays := clampi(int(round(maxf(foot.x, foot.y) / 3.0)), 1, 8)
		var rows := clampi(floors, 1, 12)
		var glow := _col(fdict.get("glow", spec.get("window_glow", [1.0, 0.92, 0.7])))
		var lit := float(fdict.get("lit", spec.get("window_lit", 1.2)))   # default MUST match GSurf.window_facade's
		return GSurf.window_facade(body_mat.albedo_color, glow, lit, bays, rows)
	return body_mat


static func _add_cap(root: Node3D, cap: String, top_foot: Vector2, height: float, roof_mat: StandardMaterial3D, spec: Dictionary, shelled: bool = false) -> void:
	if top_foot.x <= 0.01 or top_foot.y <= 0.01:
		return   # pyramid body already comes to a point — no cap
	var c: Node3D = null
	match cap:
		"gable":
			c = GShapes.roof_gable(top_foot, float(spec.get("roof_height", maxf(2.0, top_foot.y * 0.45))))
		"hip", "pyramid":
			c = GShapes.pyramid(top_foot, float(spec.get("roof_height", maxf(2.0, minf(top_foot.x, top_foot.y) * 0.5))))
		"pyramidion":
			c = GShapes.pyramid(top_foot, float(spec.get("roof_height", top_foot.x)))
		"dome":
			c = GShapes.dome(minf(top_foot.x, top_foot.y) * 0.5, float(spec.get("roof_height", minf(top_foot.x, top_foot.y) * 0.5)))
		"spire":
			c = GShapes.cylinder(minf(top_foot.x, top_foot.y) * 0.4, 0.0, float(spec.get("roof_height", height * 0.5)), 8)
		"parapet":
			c = _parapet(top_foot, float(spec.get("roof_height", clampf(minf(top_foot.x, top_foot.y) * 0.06, 0.35, 0.8))))
		_:   # "flat" / unknown -> no cap
			return
	if c != null:
		# TRANSLATE, never SET. Every GShapes factory honours ONE contract — the node it returns
		# already has its BASE at local y=0 — but they reach it two different ways: frustum/dome/
		# _parapet author geometry base-at-zero (position.y stays 0), while wedge/cylinder lift a
		# CENTRED primitive (position.y = h/2). Assigning wiped that lift on the second kind, sinking
		# a gable or spire cap by roof_height/2 into the storey below. Cosmetic on a solid building
		# (the whole-AABB box absorbs it) but a SHIP-BLOCKER on an enterable shell, where the cap's
		# own trimesh collider then hung at head height across the doorway (the unenterable-hut bug).
		c.position.y += height
		GShapes.set_material(c, roof_mat)
		# SHELLED buildings skip the whole-AABB box collider (it would seal the doorway), so their
		# decorative cap would otherwise have NO collider and things could clip up into the sloped
		# roof. Give the cap its own trimesh collider (exact slope, not an oversized box) so it's
		# solid. SOLID buildings already enclose the cap in their whole-AABB box (structure() line
		# ~116), so we only pay for this on shells.
		if shelled:
			GShapes.add_collider(c, "mesh")
		root.add_child(c)


# A clean flat roofline for enterable buildings: four thin perimeter walls (a low parapet) around the
# roof deck instead of a bare slab or a cone. N/S run the full width; E/W fit between them. Base at y=0
# so _add_cap lifts the whole thing to the roofline. Reads as a finished building top on any footprint.
static func _parapet(foot: Vector2, h: float) -> Node3D:
	var root := Node3D.new()
	var t := 0.2
	var segs := [
		[Vector3(foot.x, h, t), Vector3(0.0, 0.0, -(foot.y - t) * 0.5)],
		[Vector3(foot.x, h, t), Vector3(0.0, 0.0, (foot.y - t) * 0.5)],
		[Vector3(t, h, foot.y - 2.0 * t), Vector3((foot.x - t) * 0.5, 0.0, 0.0)],
		[Vector3(t, h, foot.y - 2.0 * t), Vector3(-(foot.x - t) * 0.5, 0.0, 0.0)],
	]
	for sd in segs:
		var b := GShapes.box(sd[0])
		b.position.x = (sd[1] as Vector3).x
		b.position.z = (sd[1] as Vector3).z
		root.add_child(b)
	return root


# ─────────────────────────────── interior shell (enterable buildings) ───────────────────────────────

# Parse the opt-in `interior` key -> a normalized dict, or {} when absent/invalid (solid building).
static func _interior_spec(spec: Dictionary) -> Dictionary:
	var iv = spec.get("interior", null)
	if typeof(iv) == TYPE_BOOL and iv:
		return {"door": "hinged", "door_face": "s", "rooms": 0, "lit": true}
	if typeof(iv) == TYPE_DICTIONARY:
		var d: Dictionary = iv
		var door := String(d.get("door", "hinged")).to_lower()
		var face := String(d.get("door_face", "")).to_lower()
		# TOLERATE a misplaced compass direction: builders sometimes write `door:"n"` meaning the
		# door FACE (the schema key is door_face). If `door` holds a compass letter and door_face
		# wasn't given, treat it as the face rather than silently swallowing it + defaulting south.
		if face == "" and door in ["n", "s", "e", "w"]:
			print("GOGI_DOOR misplaced 'door':\"", door, "\" coerced to door_face (schema key is door_face)")
			face = door
		if not (face in ["n", "s", "e", "w"]):
			face = "s"
		# EVERY interior gets a real openable/closable swinging door — a legacy door:"arch" (a bare
		# door-less opening) is coerced to a hinged leaf so no enterable building is ever door-less.
		return {"door": "hinged", "door_face": face,
			"rooms": clampi(int(d.get("rooms", 0)), 0, 2), "lit": bool(d.get("lit", true))}
	return {}


# The ENTERABLE SHELL: perimeter walls (facade outside, plaster lining inside) with a real doorway
# (+ optional swinging leaf), a flat ground slab, per-storey floor slabs joined by walkable stairs
# through a stairwell cutout, optional ground-floor partition rooms, a roof-deck slab the cap sits
# on, and a budgeted warm light. The exterior footprint/silhouette/facade match the solid building.
# Every collider is owned by the parts themselves — the caller must NOT wrap the root in an
# AABB box collider (it would seal the door). v1 simplifications: window facades stay exterior-only
# (no window holes — OmniLights light the inside), and the door wall keeps the plain body material
# so a window grid never lands squished around the doorway.
static func _build_shell(root: Node3D, idict: Dictionary, foot: Vector2, floors: int, height: float, facade, body_mat: StandardMaterial3D, roof_mat: StandardMaterial3D, spec: Dictionary) -> void:
	# Keep storeys human-scale: an explicit `height` overrides `floors` for the EXTERIOR silhouette, so a
	# short-but-many-floors spec would cram N storeys into a low shell -> clamped ceilings and sealed
	# doorways ("interiors squished and wrong"). Reduce the interior floor count so each storey keeps
	# >= MIN_STOREY; the exterior height is untouched, and normal buildings (height ~= floors*fh) are unchanged.
	floors = clampi(floors, 1, maxi(1, int(height / MIN_STOREY)))
	var sh := height / float(floors)              # storey height, reconciled (>= MIN_STOREY)
	var wall_mat := _facade_mat(facade, body_mat, foot, floors, spec)
	# warm interior lining — a faint emissive so walls never read as pure black in the shadowed interior.
	# GSurf.surface() returns a CACHED shared material, so duplicate before mutating (else every plaster
	# surface in the world gets tinted).
	var inner_mat := (GSurf.surface("plaster") as StandardMaterial3D).duplicate()
	inner_mat.emission_enabled = true
	inner_mat.emission = Color(0.95, 0.82, 0.62)
	# interior "glow" (spec-driven, default 1.0): landmark interiors (the finale tower) raise it so
	# storeys between the two budgeted lights never read as a black void on the climb.
	inner_mat.emission_energy_multiplier = 0.06 * clampf(float(idict.get("glow", 1.0)), 0.2, 10.0)
	var floor_mat := GSurf.surface("wood")
	var stair_mat := GSurf.surface("timber")
	var door_face := String(idict["door_face"])
	var iw := foot.x - 2.0 * WALL_T               # interior cavity dimensions
	var idz := foot.y - 2.0 * WALL_T
	var door_h := minf(DOOR_H, sh - SLAB_T - 0.2)   # doorway always fits under the ground ceiling

	# ---- the 4 exterior walls: built in a canonical frame (wall along X, exterior facing -Z), then
	# yawed into place. N/S walls span the full footprint; E/W walls sit BETWEEN them, so corners
	# never overlap and every outside face lands exactly on the solid building's box faces.
	var faces := {
		"s": [0.0, Vector3(0.0, 0.0, -(foot.y - WALL_T) * 0.5), foot.x],
		"n": [PI, Vector3(0.0, 0.0, (foot.y - WALL_T) * 0.5), foot.x],
		"e": [-PI * 0.5, Vector3((foot.x - WALL_T) * 0.5, 0.0, 0.0), foot.y - 2.0 * WALL_T],
		"w": [PI * 0.5, Vector3(-(foot.x - WALL_T) * 0.5, 0.0, 0.0), foot.y - 2.0 * WALL_T],
	}
	for f in faces:
		var fd: Array = faces[f]
		var frame := Node3D.new()
		frame.name = "Face_" + String(f)
		frame.rotation.y = float(fd[0])
		frame.position = fd[1]
		root.add_child(frame)
		var fw := float(fd[2])
		var is_door: bool = String(f) == door_face
		var ow := minf(DOOR_W, fw - 1.0) if is_door else 0.0
		var wall := GShapes.wall_with_opening(fw, height, WALL_T, ow, door_h, 0.0,
			body_mat if is_door else wall_mat)
		frame.add_child(wall)
		# plaster LINING: a visual-only inner layer so rooms read plastered (not glowing windows)
		var lw := (fw - 2.0 * WALL_T) if (String(f) == "n" or String(f) == "s") else fw
		var lining := GShapes.wall_with_opening(lw, height - SLAB_T, LINING_T, ow, door_h, 0.0, inner_mat, false)
		lining.position.z = WALL_T * 0.5 + LINING_T * 0.5 + 0.01
		frame.add_child(lining)
		# EVERY enterable interior gets an openable/closable swinging leaf (node group "gogi_door")
		# so all buildings with an interior have a door to open and close. ow > 0.7 always holds for
		# a valid interior (footprint >= 3m -> ow == DOOR_W == 1.4); the guard is pure defence.
		if is_door and ow > 0.7:
			frame.add_child(_door_leaf(ow, door_h))
		if is_door and ow > 0.0:
			# THRESHOLD RAMP (invisible): the interior ground slab tops out 0.1 above
			# the terrain — a vertical lip that chunk-mode movement (velocity = dir*6,
			# no gravity, move_and_slide) treats as a WALL, stranding the player at the
			# doorway (same lesson as the stairs-foot ramp). A shallow two-sided ramp
			# collider bridges outside <-> slab top with no visual.
			var thr := StaticBody3D.new()
			thr.collision_layer = 1
			var tcs := CollisionShape3D.new()
			var tbs := BoxShape3D.new()
			var t_run := 0.55
			tbs.size = Vector3(ow, 0.08, sqrt(t_run * t_run + 0.1 * 0.1) + 0.3)
			tcs.shape = tbs
			tcs.rotation.x = -atan2(0.1, t_run)   # negative: +Z (interior) end rises
			tcs.position = Vector3(0.0, 0.012, WALL_T * 0.5 + 0.05)
			thr.add_child(tcs)
			frame.add_child(thr)

	# ---- interior core (slabs, stairs, partitions, light), built in a frame yawed so +Z faces the
	# STAIR wall (opposite the door) — one set of placement math serves all 4 door faces.
	var stair_face := String({"s": "n", "n": "s", "e": "w", "w": "e"}[door_face])
	var core := Node3D.new()
	core.name = "InteriorCore"
	core.rotation.y = float({"n": 0.0, "s": PI, "e": PI * 0.5, "w": -PI * 0.5}[stair_face])
	root.add_child(core)
	var cw := iw if (stair_face == "n" or stair_face == "s") else idz   # cavity, core frame
	var cd := idz if (stair_face == "n" or stair_face == "s") else iw
	# ground slab: a clean flat interior floor over whatever the terrain does inside the footprint
	var gslab := GShapes.wall_with_opening(cw, 0.1, cd, 0.0, 0.0, 0.0, floor_mat)
	gslab.name = "GroundSlab"
	core.add_child(gslab)
	# roof-deck slab: closes the shell at the top; the cap sits on it (top face flush at y=height)
	var deck := GShapes.wall_with_opening(cw, SLAB_T, cd, 0.0, 0.0, 0.0, roof_mat)
	deck.name = "RoofDeck"
	deck.position.y = height - SLAB_T
	core.add_child(deck)

	# ---- storeys: every slab above ground gets the stairwell cutout + a flight against the stair
	# wall, so the player can physically walk from ground to top floor (cutouts stack vertically).
	if floors >= 2:
		var can_stair := cw >= 3.4 and cd >= 2.2   # too small to hollow a stairwell -> sealed slabs
		var run := clampf(sh * 1.35, 1.6, cw - 1.8)
		var x_top := cw * 0.5 - 0.6                # top landing edge (0.6m of solid slab beyond it)
		var hole := Rect2()
		if can_stair:
			hole = Rect2(x_top - run * 0.78, cd * 0.5 - STAIR_W - 0.1, run * 0.78 + 0.05, STAIR_W + 0.1)
		var nsteps := clampi(int(round(sh / 0.23)), 8, 12)
		for s in range(1, floors):
			var slab := _slab_with_hole(cw, cd, SLAB_T, hole, floor_mat)
			slab.name = "Slab" + str(s)
			slab.position.y = float(s) * sh - SLAB_T   # top surface exactly at the storey line
			core.add_child(slab)
			if can_stair:
				var flight := GShapes.stairs(STAIR_W, sh, run, nsteps, stair_mat)
				flight.name = "Flight" + str(s)
				flight.rotation.y = -PI * 0.5          # canonical -Z ascent -> core +X, hugging the wall
				flight.position = Vector3(x_top - run, float(s - 1) * sh, cd * 0.5 - STAIR_W * 0.5 - 0.08)
				core.add_child(flight)

	# ---- ground-floor partition rooms: 1|2 plaster walls PERPENDICULAR to the door wall, each with
	# an open archway (no leaves); they stop short of the stair strip so the stairwell stays clear.
	var rooms := int(idict["rooms"])
	if rooms > 0 and cw >= 5.0 and cd >= 3.5:
		var ph := (sh if floors >= 2 else height) - SLAB_T
		var plen := cd - ((STAIR_W + 0.5) if floors >= 2 else 0.0)
		var arch_w := minf(1.2, plen - 1.0)
		var arch_h := minf(2.1, ph - 0.2)
		var offs: Array = [cw / 6.0] if rooms == 1 else [-cw / 6.0, cw / 6.0]
		for po in offs:
			var part := GShapes.wall_with_opening(plen, ph, 0.15, arch_w, arch_h, 0.0, inner_mat)
			part.name = "Partition"
			part.rotation.y = PI * 0.5
			part.position = Vector3(float(po), 0.0, -(cd - plen) * 0.5)
			core.add_child(part)

	# ---- light budget (pinned): ONE OmniLight3D per storey, max 2 per building — ground floor
	# + the top storey when there is one. Warm, modest range, never shadow-casting.
	if bool(idict["lit"]):
		var lrng := clampf(maxf(iw, idz) * 0.75, 6.0, 11.0)   # reach the corners of a wide ground floor
		core.add_child(_room_light(Vector3(0.0, minf(sh - 0.5, 2.6), 0.0), lrng))
		if floors >= 2:
			core.add_child(_room_light(Vector3(0.0, height - 0.7, 0.0), lrng))
		if floors >= 6:
			# a third mid-tower light for real towers: without it the 6+ storeys between the two
			# budgeted lights are a black climb (QA: finale ascent happened in the darkest room)
			core.add_child(_room_light(Vector3(0.0, float(floors) * 0.5 * sh + 2.0, 0.0), maxf(lrng, sh * 1.2)))


# The swinging door panel per the DOOR NODE CONTRACT: a Node3D LEAF whose origin is the HINGE EDGE
# (consumers rotate .y to open), carrying its own StaticBody3D collider child, discoverable ONLY via
# the "gogi_door" node group, labelled through the "door_label" String meta. Local frame = the door
# wall's frame: leaf at the left jamb, panel extending +X across the opening, panel thickness inside
# the wall's depth. Lifted 6cm so an opened door never sinks into the ground slab.
static func _door_leaf(ow: float, oh: float) -> Node3D:
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	leaf.add_to_group("gogi_door")
	leaf.set_meta("door_label", "Open Door")
	leaf.position = Vector3(-ow * 0.5, 0.06, 0.0)
	var panel := GShapes.box(Vector3(ow - 0.06, oh - 0.12, 0.08))
	panel.name = "Panel"
	panel.position.x = (ow - 0.06) * 0.5 + 0.02
	GShapes.set_material(panel, GSurf.surface("timber"))
	leaf.add_child(panel)
	var body := StaticBody3D.new()
	body.name = "LeafBody"
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(ow, oh, 0.16)
	cs.shape = bs
	cs.position = Vector3(ow * 0.5, oh * 0.5, 0.0)
	body.add_child(cs)
	leaf.add_child(body)
	return leaf


# A floor slab with a rectangular stairwell CUTOUT — the wall_with_opening composition lying flat:
# 2-4 boxes around the hole, each with a matching shape on ONE shared StaticBody3D. The slab spans
# w x d centred at x=z=0, thickness t rising from y=0; `hole` is an XZ-plane Rect2 in the same frame
# (an empty/degenerate hole -> one solid slab).
static func _slab_with_hole(w: float, d: float, t: float, hole: Rect2, mat: Material) -> Node3D:
	var hx0 := clampf(hole.position.x, -w * 0.5, w * 0.5)
	var hx1 := clampf(hole.position.x + hole.size.x, -w * 0.5, w * 0.5)
	var hz0 := clampf(hole.position.y, -d * 0.5, d * 0.5)
	var hz1 := clampf(hole.position.y + hole.size.y, -d * 0.5, d * 0.5)
	if hx1 - hx0 < 0.05 or hz1 - hz0 < 0.05:
		return GShapes.wall_with_opening(w, t, d, 0.0, 0.0, 0.0, mat)   # solid slab
	var pieces: Array = []   # [size: Vector3, centre: Vector3] per box
	if hz0 + d * 0.5 > 0.01:   # front strip (full width)
		pieces.append([Vector3(w, t, hz0 + d * 0.5), Vector3(0.0, t * 0.5, (hz0 - d * 0.5) * 0.5)])
	if d * 0.5 - hz1 > 0.01:   # back strip (full width)
		pieces.append([Vector3(w, t, d * 0.5 - hz1), Vector3(0.0, t * 0.5, (hz1 + d * 0.5) * 0.5)])
	if hx0 + w * 0.5 > 0.01:   # left piece beside the hole
		pieces.append([Vector3(hx0 + w * 0.5, t, hz1 - hz0), Vector3((hx0 - w * 0.5) * 0.5, t * 0.5, (hz0 + hz1) * 0.5)])
	if w * 0.5 - hx1 > 0.01:   # right piece beside the hole
		pieces.append([Vector3(w * 0.5 - hx1, t, hz1 - hz0), Vector3((hx1 + w * 0.5) * 0.5, t * 0.5, (hz0 + hz1) * 0.5)])
	var root := Node3D.new()
	var body := StaticBody3D.new()
	body.collision_layer = 1
	for pc in pieces:
		var sz: Vector3 = pc[0]
		var ct: Vector3 = pc[1]
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		mi.mesh = bm
		mi.position = ct
		mi.material_override = mat
		root.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = sz
		cs.shape = bs
		cs.position = ct
		body.add_child(cs)
	root.add_child(body)
	return root


# One warm interior room light, inside the pinned budget (max 2 per building, range ~6, no shadows).
static func _room_light(pos: Vector3, rng: float = 6.0) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.87, 0.66)
	l.light_energy = 1.35
	l.omni_range = rng
	l.shadow_enabled = false
	l.light_specular = 0.25
	l.position = pos
	return l


# ─────────────────────────────── helpers ───────────────────────────────

static func _v2(a) -> Vector2:
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return Vector2(8, 8)


static func _col(a) -> Color:
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(0.7, 0.7, 0.72)
