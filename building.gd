extends Node3D
## BUILDING — placing and removing pieces as GAMEPLAY. Minecraft-style, on a grid.
##
## THIS IS NOT AN EDITOR. The template's standing rule — "do not add an in-game edit bar" — is about
## changing the GAME'S DESIGN, which happens in chat and nowhere else. This is the opposite thing: a
## mechanic the player operates, like driving a car or swinging a sword. A creator edits the world; a
## player builds in it. Conflating the two is the reason a building game could never get made.
##
## WHY BUILDS LIVE OUTSIDE THE WORLD GRID
## chunk_manager rebuilds a cell from `grid[key]` every time it becomes resident, and a chat edit
## REPLACES `grid` wholesale. Anything player-placed stored in there would be bulldozed by the next
## edit and re-created from stale data on every stream-in. So placements live here, in their own
## store, rendered by nodes this script owns. The creator's world and the player's build are drawn
## together and never share a container — which makes "a chat edit destroyed my castle" structurally
## impossible rather than merely unlikely.
##
## RENDERING: one MultiMeshInstance3D per palette id. Two hundred identical blocks cost roughly one
## block. That is what lets built pieces carry a 2000-piece budget while authored decorative props
## stay capped at 12 per cell — repetition is exactly what batching is good at, and a castle is
## nothing but repetition. Colliders are ONE StaticBody3D per palette id holding many box shapes,
## rather than one body per block, for the same reason.
##
## V1 SCOPE, stated so it is a choice and not a discovery:
##   - pieces are PROCEDURAL SHAPES (box / slab / ramp / cylinder), not downloaded models. Blocks,
##     walls, floors and platforms — which is what block-building actually is. Model-based pieces
##     need the async asset path and are a follow-on.
##   - you can build UP, not DOWN. The ground is a heightmap, not a voxel volume; there is no digging.

const GROUP := "gogi_built"

var main = null
var cfg: Dictionary = {}
var enabled := false

var grid_size := 1.0
var reach := 6.0
var snap_mode := "surface"
var limit_total := 2000
var _palette: Array = []            # [{id, shape, size, material, cost:{var:qty}, locked}]
var _pal_by_id: Dictionary = {}
var _locked: Dictionary = {}

var _placed: Dictionary = {}        # "gx,gy,gz" -> {id, gx, gy, gz}
var _mm: Dictionary = {}            # palette id -> MultiMeshInstance3D
var _bodies: Dictionary = {}        # palette id -> StaticBody3D
var _dirty_render := false

var _mode := false                  # build mode on/off
var _sel := 0                       # selected palette index
var _ghost: MeshInstance3D = null
var _ghost_ok := false
var _ghost_spot := Vector3i.ZERO
var _ui: Array = []
var _pal_btns: Array = []           # palette buttons only, so the selected one can be highlighted
var _hidden_hud: Array = []         # game HUD buttons THIS script hid on entering build mode
var _btn_build: Button = null
var _btn_mode: Button = null        # shows what a world tap does: PLACE or REMOVE
var _removing := false              # tap action


# ---------------- setup ----------------

func configure(m, world: Dictionary) -> void:
	main = m
	var b = world.get("building", null)
	if not (b is Dictionary):
		return
	cfg = b
	enabled = bool(cfg.get("enabled", true))
	if not enabled:
		return
	grid_size = maxf(0.25, float(cfg.get("grid_size", 1.0)))
	reach = maxf(2.0, float(cfg.get("reach", 6.0)))
	snap_mode = String(cfg.get("snap", "surface"))
	var lim = cfg.get("limits", {})
	if lim is Dictionary:
		limit_total = int((lim as Dictionary).get("total", 2000))

	var pal = cfg.get("palette", [])
	if pal is Array:
		for p0 in (pal as Array):
			if typeof(p0) != TYPE_DICTIONARY:
				continue
			var p: Dictionary = p0
			var pid := String(p.get("id", ""))
			if pid == "":
				continue
			_palette.append(p)
			_pal_by_id[pid] = p
			if bool(p.get("locked", false)):
				_locked[pid] = true
	if _palette.is_empty():
		push_warning("[Build] `building` block has no usable palette — building disabled")
		enabled = false
		return

	_restore()
	_build_ui()
	_rebuild_render()
	_wire_net()
	print("GOGI_BUILD ready palette=%d placed=%d snap=%s grid=%.2f" % [_palette.size(), _placed.size(), snap_mode, grid_size])


# ---------------- persistence ----------------
#
# Local backend: the whole placement set rides the normal save blob. Cloud backend: the pieces live
# in `gogi_builds`, one row per spot, because that table's PRIMARY KEY *is* the spot — which is what
# makes two players placing in the same square resolve themselves instead of needing a referee.

func _restore() -> void:
	if Save == null:
		return
	if Save.backend == "cloud":
		_cloud_load()
		return
	var raw = Save.get_value("build.placed", null)
	if raw is Dictionary:
		for k in (raw as Dictionary):
			var rec = (raw as Dictionary)[k]
			if rec is Dictionary and _pal_by_id.has(String((rec as Dictionary).get("id", ""))):
				_placed[String(k)] = rec
		# A palette entry the creator has since REMOVED keeps the pieces already standing — the
		# filter above only drops pieces whose type is gone entirely. You simply cannot place more.


func _persist() -> void:
	if Save == null or Save.backend == "cloud":
		return
	Save.put("build.placed", _placed)


# ---------------- placement maths ----------------

func _key(v: Vector3i) -> String:
	return "%d,%d,%d" % [v.x, v.y, v.z]


func _world_of(v: Vector3i) -> Vector3:
	return Vector3(float(v.x) + 0.5, float(v.y) + 0.5, float(v.z) + 0.5) * grid_size


func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / grid_size), floori(p.y / grid_size), floori(p.z / grid_size))


## Where is the player aiming, and is that a legal spot? Returns [ok, spot].
##
## Surface mode targets the cell ADJACENT to the face you hit — the same rule every block game uses,
## because it is the only one that lets you build outward from what already exists. Aiming at open
## terrain falls back to the cell the ray lands in, so you can start a build on flat ground.
func _aim() -> Array:
	if main == null or main.cam == null:
		return [false, Vector3i.ZERO, Vector3i.ZERO]
	return _aim_from(main.get_viewport().get_visible_rect().size * 0.5)


## Ray through an arbitrary SCREEN POINT. Returns [ok, place_spot, solid_spot] — the empty cell a new
## piece goes into, and the occupied cell that was actually hit, so REMOVE deletes the block you
## touched instead of guessing at neighbours.
##
## The ray is long and the REACH limit is measured from the PLAYER, not from the camera. Casting
## `reach` units from the camera was subtly wrong: the camera orbits well behind the player, so most
## of that budget was spent covering the gap before the ray ever arrived at the ground.
func _aim_from(screen_pos: Vector2) -> Array:
	if main == null or main.cam == null:
		return [false, Vector3i.ZERO, Vector3i.ZERO]
	var cam: Camera3D = main.cam
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var dir: Vector3 = cam.project_ray_normal(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 200.0)
	q.collide_with_areas = false
	var hit: Dictionary = main.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return [false, Vector3i.ZERO, Vector3i.ZERO]
	var pos: Vector3 = hit["position"]
	if main.player != null and pos.distance_to(main.player.global_position) > reach + grid_size:
		return [false, Vector3i.ZERO, Vector3i.ZERO]
	var nrm: Vector3 = hit.get("normal", Vector3.UP)
	var solid := _cell_of(pos - nrm * grid_size * 0.5)
	var spot: Vector3i
	if snap_mode == "grid":
		spot = _cell_of(pos + Vector3(0, 0.01, 0))
	else:
		# step INTO the surface to find the occupied cell, then out along the face normal
		spot = solid + Vector3i(roundi(nrm.x), roundi(nrm.y), roundi(nrm.z))
	return [true, spot, solid]


func _can_place(spot: Vector3i, pid: String) -> bool:
	if _placed.has(_key(spot)):
		return false                        # occupied — the spot key IS the occupancy test
	if _placed.size() >= limit_total:
		return false
	if _locked.has(pid):
		return false
	# cost, charged against rule-layer vars so a build economy is ordinary authoring
	var rules = _rules()
	var cost = (_pal_by_id[pid] as Dictionary).get("cost", {})
	if cost is Dictionary and rules != null:
		for vname in (cost as Dictionary):
			if rules._num(rules._vget(String(vname))) < float((cost as Dictionary)[vname]):
				return false
	return true


func _rules():
	if main != null and main.director != null and main.director.get("rules") != null:
		return main.director.rules
	return null


# ---------------- place / remove ----------------

func place(spot: Vector3i, pid: String, remote := false) -> bool:
	if not _pal_by_id.has(pid):
		return false
	if _placed.has(_key(spot)):
		return false                        # first write wins, locally and over the wire
	if not remote and not _can_place(spot, pid):
		return false
	_placed[_key(spot)] = {"id": pid, "gx": spot.x, "gy": spot.y, "gz": spot.z}
	_dirty_render = true
	if not remote:
		_charge(pid, 1.0)
		_persist()
		_cloud_put(spot, pid)
		_net_send("bp", spot, pid)
		var r = _rules()
		if r != null:
			r.fire("place", {"id": pid, "who": "player"})
	return true


func remove_at(spot: Vector3i, remote := false) -> bool:
	var k := _key(spot)
	if not _placed.has(k):
		return false
	var pid := String((_placed[k] as Dictionary).get("id", ""))
	_placed.erase(k)
	_dirty_render = true
	if not remote:
		_charge(pid, -float(cfg.get("remove", {}).get("refund", 1.0)) if cfg.get("remove", {}) is Dictionary else -1.0)
		_persist()
		_cloud_del(spot)
		_net_send("br", spot, pid)
		var r = _rules()
		if r != null:
			r.fire("remove", {"id": pid, "who": "player"})
	return true


func _charge(pid: String, mult: float) -> void:
	var rules = _rules()
	var cost = (_pal_by_id[pid] as Dictionary).get("cost", {})
	if not (cost is Dictionary) or rules == null:
		return
	for vname in (cost as Dictionary):
		var n := String(vname)
		rules._vset(n, rules._num(rules._vget(n)) - float((cost as Dictionary)[vname]) * mult)


# ---------------- rendering ----------------

func _mesh_for(p: Dictionary) -> Mesh:
	var s: Vector3 = Vector3.ONE * grid_size
	var sz = p.get("size", null)
	if sz is Array and (sz as Array).size() >= 3:
		s = Vector3(float(sz[0]), float(sz[1]), float(sz[2])) * grid_size
	match String(p.get("shape", "box")):
		"slab":     return GShapes.box(Vector3(s.x, s.y * 0.5, s.z)).mesh
		"ramp":     return GShapes.ramp(s.z, s.y, s.x).mesh
		"cylinder": return GShapes.cylinder(s.x * 0.5, s.x * 0.5, s.y).mesh
	return GShapes.box(s).mesh


func _rebuild_render() -> void:
	_dirty_render = false
	# bucket every placement by type so each type becomes ONE multimesh + ONE collision body
	var by_id: Dictionary = {}
	for k in _placed:
		var rec: Dictionary = _placed[k]
		var pid := String(rec.get("id", ""))
		if not by_id.has(pid):
			by_id[pid] = []
		(by_id[pid] as Array).append(rec)

	for pid in _pal_by_id:
		var list: Array = by_id.get(pid, [])
		var p: Dictionary = _pal_by_id[pid]

		if not _mm.has(pid):
			var mi := MultiMeshInstance3D.new()
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = _mesh_for(p)
			var mat := GSurf.surface(p.get("material", "stone"))
			mi.material_override = mat
			mi.multimesh = mm
			add_child(mi)
			_mm[pid] = mi
			var body := StaticBody3D.new()
			add_child(body)
			_bodies[pid] = body

		var inst: MultiMeshInstance3D = _mm[pid]
		inst.multimesh.instance_count = list.size()
		var body2: StaticBody3D = _bodies[pid]
		for c in body2.get_children():
			c.queue_free()
		var half: Vector3 = Vector3.ONE * grid_size * 0.5
		for i in list.size():
			var rec2: Dictionary = list[i]
			var wp := _world_of(Vector3i(int(rec2["gx"]), int(rec2["gy"]), int(rec2["gz"])))
			inst.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, wp))
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3.ONE * grid_size
			cs.shape = bs
			cs.position = wp
			body2.add_child(cs)
		body2.add_to_group(GROUP)


func _process(_delta: float) -> void:
	if not enabled:
		return
	if _dirty_render:
		_rebuild_render()
	if _ghost != null:
		_ghost.queue_free()      # tap-to-place makes a centre-screen preview actively misleading
		_ghost = null


func _update_ghost() -> void:
	var a := _aim()
	_ghost_ok = false
	if not bool(a[0]):
		if _ghost != null:
			_ghost.visible = false
		return
	var spot: Vector3i = a[1]
	_ghost_spot = spot
	var pid := String((_palette[_sel] as Dictionary).get("id", ""))
	_ghost_ok = _can_place(spot, pid)
	if _ghost == null:
		_ghost = MeshInstance3D.new()
		add_child(_ghost)
	_ghost.mesh = _mesh_for(_palette[_sel])
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color = Color(0.4, 1.0, 0.5, 0.45) if _ghost_ok else Color(1.0, 0.35, 0.3, 0.4)
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.material_override = gm
	_ghost.global_position = _world_of(spot)
	_ghost.visible = true


# ---------------- rule-layer API ----------------
#
# The four build ACTIONS in rules.md. Kept public and behind methods (like place/remove_at) so
# rules.gd never reaches into `_locked` / `_placed` directly.
#
# WHY THIS EXISTS AT ALL: `locked: true` was a ONE-WAY DOOR. The lock half worked — a locked piece
# greys out and _can_place refuses it — but unlock_palette was documented, accepted by verify, and
# implemented nowhere. building.md's own worked example (place stone walls, hit a threshold, unlock
# the ramp) therefore shipped a game with a piece the player can see in the palette and can never
# use, with one GOGI_RULES_UNIMPL line in a console nobody reads as the only clue.

## Make a `locked: true` palette piece usable. The palette UI is built when build mode opens, so a
## rule firing mid-session needs it rebuilt or the button stays greyed until the player toggles out
## and back in.
func unlock_piece(pid: String) -> void:
	if not _locked.has(pid):
		return
	_locked.erase(pid)
	if _mode:
		_open_palette()


## Take a piece back out of circulation.
func lock_piece(pid: String) -> void:
	if _locked.has(pid):
		return
	_locked[pid] = true
	# The selection may be sitting on the piece just locked. _can_place already refuses it, but the
	# ghost would keep drawing that shape — a red preview that never resolves. Move to the first
	# piece still available.
	if _sel >= 0 and _sel < _palette.size() \
			and String((_palette[_sel] as Dictionary).get("id", "")) == pid:
		for i in _palette.size():
			if not _locked.has(String((_palette[i] as Dictionary).get("id", ""))):
				_sel = i
				break
	if _mode:
		_open_palette()


## Turn the whole mechanic on or off. Disabling leaves build mode properly rather than freezing it:
## _process early-returns on `enabled`, so flipping the flag alone would strand an open palette and
## a visible ghost on screen with nothing servicing them.
func set_build_enabled(on: bool) -> void:
	if enabled == on:
		return
	if not on and _mode:
		_toggle()                       # closes the palette + fires build_mode_exited
	enabled = on
	if _btn_build != null:
		_btn_build.visible = on
	if not on and _ghost != null:
		_ghost.visible = false


## Wipe every player-placed piece. Renders immediately rather than waiting on the _dirty_render
## pass, because that pass lives in _process behind the `enabled` check — a clear_builds paired with
## set_build_enabled(false) would otherwise leave the old geometry standing.
func clear_all() -> void:
	if _placed.is_empty():
		return
	_placed.clear()
	_rebuild_render()
	_persist()


# ---------------- UI ----------------

func _build_ui() -> void:
	if main == null or main.hud_layer == null:
		return
	_btn_build = _mk_button("BUILD", func() -> void: _toggle())
	_relayout()
	get_window().size_changed.connect(_relayout)


## `sz` is applied to BOTH custom_minimum_size and size. custom_minimum_size alone cannot shrink a
## control that is already larger — it is a floor, not a set — so palette buttons asking for 150x70
## after a 200x96 default stayed 200 wide while being laid out 160 apart, overlapping each other by
## 40px. That was the mangled palette strip: not a spacing bug, a sizing one.
func _mk_button(txt: String, cb: Callable, sz := Vector2(200, 96)) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = sz
	b.size = sz
	b.add_theme_font_size_override("font_size", 26)
	b.pressed.connect(cb)
	main.hud_layer.add_child(b)
	return b


func _toggle() -> void:
	_mode = not _mode
	_btn_build.text = "EXIT BUILD" if _mode else "BUILD"
	_hide_game_hud(_mode)
	if _mode:
		_open_palette()
	else:
		_close_palette()
		if _ghost != null:
			_ghost.visible = false
	var r = _rules()
	if r != null:
		r.fire("build_mode_entered" if _mode else "build_mode_exited", {})


func _open_palette() -> void:
	_close_palette()
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	var x := 20.0
	for i in _palette.size():
		var p: Dictionary = _palette[i]
		var pid := String(p.get("id", ""))
		var idx := i
		var b := _mk_button(String(p.get("label", pid)).to_upper(),
			func() -> void: _select(idx), Vector2(150, 70))
		b.position = Vector2(x, vp.y - 100.0)
		if _locked.has(pid):
			b.disabled = true
		_ui.append(b)
		_pal_btns.append(b)
		x += 160.0
	# ONE button, and it is a MODE indicator rather than a trigger: it says what a tap on the world
	# will DO. Placing is a tap on the spot you want, not aim-then-reach-for-a-button.
	_btn_mode = _mk_button("", func() -> void: _toggle_mode(), Vector2(210, 88))
	_btn_mode.position = Vector2(vp.x - 230.0, vp.y - 108.0)
	_ui.append(_btn_mode)
	_refresh_mode()
	_refresh_sel()


func _toggle_mode() -> void:
	_removing = not _removing
	_refresh_mode()


func _refresh_mode() -> void:
	if _btn_mode == null or not is_instance_valid(_btn_mode):
		return
	_btn_mode.text = "TAP: REMOVE" if _removing else "TAP: PLACE"
	_btn_mode.modulate = Color(1.0, 0.72, 0.68) if _removing else Color(0.75, 1.0, 0.8)


## A tap on the WORLD (never on a control — main._input filters those out first) acts at the tapped
## point. This replaced separate PLACE and REMOVE buttons, which required aiming the camera at a spot
## and then reaching for a button in the corner: the ghost was the only hint that aiming was what
## positioned the block, and nothing on screen said so.
func tap_world(screen_pos: Vector2) -> void:
	if not enabled or not _mode:
		return
	if _removing:
		_remove_at_screen(screen_pos)
	else:
		_place_at_screen(screen_pos)


## Which piece is armed. Selecting used to just assign `_sel` with NO visual change, so the palette
## gave no clue what PLACE would drop — you found out by placing it.
func _select(i: int) -> void:
	_sel = i
	_refresh_sel()


func _refresh_sel() -> void:
	for i in _pal_btns.size():
		var b = _pal_btns[i]
		if not is_instance_valid(b):
			continue
		(b as Button).modulate = Color(1, 1, 1) if i == _sel else Color(0.55, 0.58, 0.63)


func _close_palette() -> void:
	for n in _ui:
		if is_instance_valid(n):
			n.queue_free()
	_ui.clear()
	_pal_btns.clear()


## ATTACK / POTION / USE / SHEATHE / JUMP / WEAPON / STABLE are combat and traversal controls. None
## of them mean anything while you are placing blocks, and they are drawn into the same two corners
## the build controls need — so they were not merely clutter, they were physically on top of PLACE
## and REMOVE.
##
## Restores only what it actually hid. A button already invisible for its own reasons (DISMOUNT is
## hidden on foot, STABLE only appears near a mount) must STAY hidden on the way out — blanket
## `visible = true` would conjure controls the game had deliberately taken away.
func _hide_game_hud(on: bool) -> void:
	if not on:
		for b in _hidden_hud:
			if is_instance_valid(b):
				(b as Button).visible = true
		_hidden_hud.clear()
		return
	_hidden_hud.clear()
	if main == null:
		return
	for k in main._hud_btns:
		var b = main._hud_btns[k]
		if b is Button and (b as Button).visible:
			(b as Button).visible = false
			_hidden_hud.append(b)


func _relayout() -> void:
	if _btn_build == null:
		return
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	_btn_build.position = Vector2(20, vp.y - 420.0)
	if _mode:
		_open_palette()


func _place_at_screen(sp: Vector2) -> void:
	var a := _aim_from(sp)
	var pid := String((_palette[_sel] as Dictionary).get("id", ""))
	if not bool(a[0]) or not _can_place(a[1], pid):
		AudioManager.play_sfx("ui", -6.0, 0.7)     # out of reach, occupied, locked, or unaffordable
		return
	if place(a[1], pid):
		AudioManager.play_sfx("pickup", -4.0, 1.2)


func _remove_at_screen(sp: Vector2) -> void:
	var a := _aim_from(sp)
	if not bool(a[0]):
		return
	# a[2] is the cell the ray actually landed IN — the block under the finger.
	if _placed.has(_key(a[2])):
		if remove_at(a[2]):
			AudioManager.play_sfx("ui", -4.0, 0.9)
		return
	AudioManager.play_sfx("ui", -8.0, 0.6)         # tapped something that isn't player-placed


## True while the mechanic is on AND the player is in build mode — main.gd asks before routing a tap.
func in_build_mode() -> bool:
	return enabled and _mode


## Does this screen point land on one of THIS script's controls? main._touch_on_hud only knew about
## the game's own button dictionary, so a press on a palette button also started a camera orbit.
func ui_hit(p: Vector2) -> bool:
	for n in _ui:
		if is_instance_valid(n) and (n as Control).visible \
				and Rect2((n as Control).position, (n as Control).size).has_point(p):
			return true
	if _btn_build != null and is_instance_valid(_btn_build) and _btn_build.visible \
			and Rect2(_btn_build.position, _btn_build.size).has_point(p):
		return true
	return false


# ---------------- multiplayer ----------------
#
# Broadcasts are the FAST path (everyone sees the block immediately); the Supabase table is the
# DURABLE one (a late joiner reads what already exists, and a dropped packet cannot leave two
# players with different castles). Broadcast alone would be wrong: placement is a one-shot event
# with a permanent consequence, so a lost packet never self-heals the way a position update does.

func _wire_net() -> void:
	var net = get_node_or_null("/root/Net")
	if net != null and not net.message.is_connected(_on_net):
		net.message.connect(_on_net)


func _net_send(kind: String, spot: Vector3i, pid: String) -> void:
	var net = get_node_or_null("/root/Net")
	if net != null and net.has_method("send"):
		net.send({"t": kind, "x": spot.x, "y": spot.y, "z": spot.z, "p": pid})


func _on_net(d: Dictionary) -> void:
	var t := String(d.get("t", ""))
	if t != "bp" and t != "br":
		return
	var spot := Vector3i(int(d.get("x", 0)), int(d.get("y", 0)), int(d.get("z", 0)))
	if t == "bp":
		place(spot, String(d.get("p", "")), true)
	else:
		remove_at(spot, true)


func _cloud_load() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	var url: String = Auth.supabase_url.rstrip("/") + "/rest/v1/gogi_builds?select=gx,gy,gz,palette_id&game_id=eq." + main.build_id.uri_encode()
	if req.request(url, _hdr(), HTTPClient.METHOD_GET) != OK:
		req.queue_free()
		return
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[1]) != 200:
		push_warning("[Build] cloud load HTTP " + str(res[1]))
		return
	var rows = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if not (rows is Array):
		return
	for r0 in (rows as Array):
		if typeof(r0) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = r0
		var sp := Vector3i(int(r.get("gx", 0)), int(r.get("gy", 0)), int(r.get("gz", 0)))
		_placed[_key(sp)] = {"id": String(r.get("palette_id", "")), "gx": sp.x, "gy": sp.y, "gz": sp.z}
	_dirty_render = true
	print("GOGI_BUILD cloud loaded=%d" % _placed.size())


func _hdr() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + Auth.supabase_anon_key,
		"Authorization: Bearer " + Auth.bearer(),
		"Content-Type: application/json",
	])


func _cloud_put(spot: Vector3i, pid: String) -> void:
	if Save == null or Save.backend != "cloud":
		return
	var req := HTTPRequest.new()
	add_child(req)
	var body := {"game_id": main.build_id, "room": String(cfg.get("room", "")), "cell": _cell_key_of(spot),
		"gx": spot.x, "gy": spot.y, "gz": spot.z, "palette_id": pid, "placed_by": Auth.uid}
	req.request(Auth.supabase_url.rstrip("/") + "/rest/v1/gogi_builds", _hdr(),
		HTTPClient.METHOD_POST, JSON.stringify(body))
	await req.request_completed
	req.queue_free()


func _cloud_del(spot: Vector3i) -> void:
	if Save == null or Save.backend != "cloud":
		return
	var req := HTTPRequest.new()
	add_child(req)
	var q := "?game_id=eq.%s&gx=eq.%d&gy=eq.%d&gz=eq.%d" % [main.build_id.uri_encode(), spot.x, spot.y, spot.z]
	req.request(Auth.supabase_url.rstrip("/") + "/rest/v1/gogi_builds" + q, _hdr(), HTTPClient.METHOD_DELETE)
	await req.request_completed
	req.queue_free()


func _cell_key_of(spot: Vector3i) -> String:
	var cs := 32.0
	if main != null and main.chunk_manager != null:
		cs = float(main.chunk_manager.cell_size)
	var w := _world_of(spot)
	return "%d,%d" % [floori(w.x / cs), floori(w.z / cs)]
