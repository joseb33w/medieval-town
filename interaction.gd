class_name InteractionSystem extends Node
## INTERACTION + DIALOGUE. Chest / NPC / SEAM, checked against RpgState. A SEAM is the real
## door: when unlocked it calls SceneManager.goto_area() -> the fade + area swap. NPC lines
## get a live in-character hint from the shared brain (npc.myapping.com/chat). Visuals live
## under the current area root (freed on transition); clear() drops the refs.

const NPC_BRAIN := "https://npc.myapping.com/chat"
# SPOKEN NPC dialogue — the shared TTS endpoint synthesizes the line as audio so the
# player HEARS the NPC (distinct per-character voice) instead of reading a text box.
const NPC_SPEAK := "https://npc.myapping.com/speak"
# Distinct stable voices; an NPC is assigned one deterministically from its id, so the
# same character always sounds the same and different characters sound different.
const VOICES := ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

var player: Node3D
var rpg: RpgState
var scene_manager
var quest                      # QuestSystem — for talk_to objective progress
var area_parent: Node          # current area root (set per area by AreaBuilder)
var items: Array = []

# --- sittable furniture (Wave 3 — the pose module's third consumer, after vehicle + NPC) ---
const SEAT_HIP_RATIO := 0.52   # hips ≈ 52% of standing height — the SAME ratio vehicle.gd seats with
const SEAT_SINK := 0.06        # hips rest just above the cushion (vehicle._seat_driver parity)
var player_seated := false     # PUBLIC: main.gd freezes the movement branch while true
var terrain: GTerrain = null   # set by main.gd in chunk mode — grounds the stand-up spot (null = y 0)
var main_ref: Node = null      # main.gd — its active_vehicle gates seats out while driving/riding
var _active_seat = null        # the occupied seat's registry entry (Dictionary ref) while seated

var prompt: Label
var dlg_box: PanelContainer    # ONLY system messages now (chest/door/locked) — moved to the TOP
var dlg_label: RichTextLabel   # so it never covers the bottom touch controls. NPC talk = VOICE.
var dlg_queue: Array = []
var active := false
var talks := 0   # incremented on every NPC talk (deterministic signal for verify/QA)

# --- spoken NPC dialogue ---
var voice_player: AudioStreamPlayer = null
var _speak_queue: Array = []   # Array of {text, voice, name}
var _speaking := false
var _speaker_name := ""


func setup(p: Node3D, state: RpgState, sm, qs, hud: CanvasLayer) -> void:
	player = p
	rpg = state
	scene_manager = sm
	quest = qs
	_build_ui(hud)


func set_area_parent(node: Node) -> void:
	area_parent = node


func clear() -> void:
	# a seated player must never carry a folded pose across an area swap — restore the pose only
	# (NO reposition: the scene manager is about to teleport them to the destination spawn anyway).
	if player_seated:
		player_seated = false
		_active_seat = null
		if player != null and is_instance_valid(player):
			GPose.stand(player)
	# the visual nodes are freed with the old area root — but KEEP vehicles: they live on main's
	# PERSISTENT layer (world-level "vehicles"), so a zone transition must not orphan their entries.
	var kept: Array = []
	for it in items:
		if String(it.get("kind", "")) == "vehicle":
			kept.append(it)
	items = kept
	active = false
	if dlg_box:
		dlg_box.visible = false
	# stop any in-flight spoken dialogue + drain the queue so a voice doesn't bleed
	# across an area transition
	_speak_queue.clear()
	_speaking = false
	_speaker_name = ""
	if voice_player:
		voice_player.stop()


func _physics_process(_d: float) -> void:
	if player == null or prompt == null:
		return
	if scene_manager and scene_manager.transitioning:
		prompt.text = ""
		return
	if _speaking:
		prompt.text = _speaker_name + " is speaking..."
		return
	if active:
		prompt.text = "tap dialogue / USE to continue"
		return
	var it = _nearest(2.9)
	# empty labels render NO prompt at all (a driven vehicle pins itself as the nearest item and
	# returns "" — the HUD stays clean during rides; the USE button still exits, routed by kind)
	prompt.text = ("USE > " + it.label) if (it and String(it.label) != "") else ""


# ---------------- registration (visuals under area_parent) ----------------

func add_chest(pos: Vector3, contents: Array, gold := 0, parent: Node = null, cell_key := "") -> void:
	var node := _box(pos + Vector3(0, 0.45, 0), Vector3(0.9, 0.9, 0.9), Color(0.85, 0.68, 0.22), parent)
	items.append({kind = "chest", pos = pos, node = node, label = "Open Chest",
		contents = contents, gold = gold, opened = false, cell = cell_key})


func add_npc(pos: Vector3, npc_id: String, npc_name: String, persona: String, lines: Array, model: Node = null, parent: Node = null, cell_key := "", sound := "") -> void:
	var par: Node = parent if parent != null else area_parent
	if model and model is Node3D:
		var m3 := model as Node3D
		m3.position = pos
		par.add_child(m3)
		# SEAT the character so feet rest on the floor. Character GLB origins sit at the hips, so the
		# model sinks to the knees unless we LIFT it (unlike props, which we only ever drop). This is
		# the NPC-side of the player's _seat_avatar — full seat, both lift and drop, no maxf clamp.
		m3.position.y -= _subtree_aabb(m3).position.y
		_idle_animate(m3)
	else:
		_capsule(pos, Color(0.30, 0.78, 0.42), par)
	# SOLID body so the player can't walk THROUGH the NPC
	var npc_body := StaticBody3D.new()
	npc_body.collision_layer = 1
	npc_body.position = pos + Vector3(0, 0.9, 0)
	var npc_cs := CollisionShape3D.new()
	var npc_cap := CapsuleShape3D.new()
	npc_cap.radius = 0.5
	npc_cap.height = 1.8
	npc_cs.shape = npc_cap
	npc_body.add_child(npc_cs)
	par.add_child(npc_body)
	# POSITIONAL character sound (an NPC murmur/voice loop) — localized to THIS NPC, fades
	# with distance. world.json npc: {"model":…, "sound":"chatter"} → res://audio/chatter.ogg.
	if sound != "":
		AudioManager.attach_loop(npc_body, AudioManager.stream_for("res://audio/%s.ogg" % sound), -10.0, 12.0, 4.0)
	items.append({kind = "npc", pos = pos, label = "Talk to " + npc_name, npc_id = npc_id,
		npc_name = npc_name, persona = persona, lines = lines, asked = false, cell = cell_key})


func add_seam(pos: Vector3, to_area: String, spawn: String, lock: String, label: String, id := "") -> void:
	var col := Color(0.35, 0.5, 0.75) if lock == "" else Color(0.55, 0.32, 0.18)
	var node := _box(pos + Vector3(0, 1.6, 0), Vector3(3.0, 3.2, 0.5), col)
	# `id` is what the rule layer addresses (`unlock_seam`). Falls back to the label so a world that
	# never names its seams is still reachable by the words the player sees on the prompt.
	items.append({kind = "seam", pos = pos, node = node, label = label,
		id = (id if id != "" else label), to = to_area, spawn = spawn, lock = lock})


# A PHYSICAL openable door (chunk open worlds) — NOT a seam/teleport. A leaf on a hinge pivot
# with a blocking collider; USE swings it open (Tween) + disables the collider so you walk
# through. Optional `lock` token works like a seam lock (needs the item key or a quest flag).
func add_door(pos: Vector3, facing: float, lock: String, label: String, parent: Node = null, cell_key := "", id := "") -> void:
	var par: Node = parent if parent != null else area_parent
	var pivot := Node3D.new()
	pivot.position = pos
	pivot.rotation.y = deg_to_rad(facing)
	par.add_child(pivot)
	# the door leaf, offset +x of the hinge so it swings about the pivot edge
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.2, 3.0, 0.22)
	mi.mesh = bm
	mi.material_override = _mat(Color(0.46, 0.30, 0.17) if lock == "" else Color(0.30, 0.20, 0.12))
	mi.position = Vector3(1.1, 1.5, 0.0)
	pivot.add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.4, 3.0, 0.4)
	cs.shape = bs
	cs.position = Vector3(1.1, 1.5, 0.0)
	body.add_child(cs)
	pivot.add_child(body)
	items.append({kind = "door", pos = pos, label = label, id = (id if id != "" else label),
		lock = lock, facing = facing, pivot = pivot, shape = cs, open = false,
		closed_yaw = pivot.rotation.y, cell = cell_key})


# Wave 2 (structure interiors): register an ALREADY-BUILT openable door leaf — the swinging panel
# build_structure.gd tags into node group "gogi_door" (meta "door_label") — so USE swings it with
# the SAME mechanism as add_door: open = rotate the hinge pivot's .y ~100 degrees over ~0.4s +
# disable the leaf's collider shape(s); USE again CLOSES it (swing back, colliders re-enabled once
# shut). The leaf IS its own hinge pivot (pivot-at-hinge-edge contract), so the leaf itself rotates.
# Entries are tagged with cell_key and die with the cell via remove_cell (the nodes themselves are
# freed by the cell root's queue_free). Registering the same leaf twice is a no-op. No lock support
# in interiors v1 (locked passage stays the seam/add_door `lock` mechanism).
func add_structure_door(leaf: Node3D, label: String, cell_key := "") -> void:
	if leaf == null or not is_instance_valid(leaf):
		return
	for it in items:
		if String(it.get("kind", "")) == "sdoor" and it.get("node") == leaf:
			return   # already registered (defensive — cell rebuilds register FRESH nodes)
	# every collision shape under the leaf (its own StaticBody3D collider child, per the contract)
	var shapes: Array = []
	var stack: Array = [leaf]
	while not stack.is_empty():
		var nn = stack.pop_back()
		for c in nn.get_children():
			stack.append(c)
		if nn is CollisionShape3D:
			shapes.append(nn)
	var wpos: Vector3 = leaf.global_position if leaf.is_inside_tree() else leaf.position
	items.append({kind = "sdoor", pos = wpos, node = leaf, label = label, open_label = label,
		shapes = shapes, open = false, closed_yaw = leaf.rotation.y, tween = null, cell = cell_key})


# A readable world SIGN (storefront / landmark label). Billboarded so the text
# ALWAYS faces the camera and is NEVER mirrored. DON'T rotate a Label3D by PI to
# "face" a wall — that shows the mirrored BACK face ("APARTMENTS" -> backwards).
# Pair with an enterable building (a chunk prop with collider:"mesh") for a shop.
func add_sign(text: String, pos: Vector3, color: Color = Color(0.95, 0.9, 0.6), parent: Node = null) -> Label3D:
	var par: Node = parent if parent != null else area_parent
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 64
	lbl.pixel_size = 0.012
	lbl.modulate = color
	lbl.outline_size = 12
	lbl.outline_modulate = Color(0, 0, 0, 0.8)
	lbl.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	lbl.position = pos
	par.add_child(lbl)
	return lbl


# A drivable VEHICLE (world-level "vehicles", vehicle.gd) — registered here so the SAME touch/USE
# mechanism chests/NPCs use drives enter/exit. The entry TRACKS the car: _nearest refreshes pos +
# label (Drive/Exit) from the live node each query, so the prompt follows a car that has been
# driven somewhere else. No cell key — vehicles are persistent and never evicted with a cell.
func add_vehicle(v: Node3D) -> void:
	items.append({kind = "vehicle", pos = v.global_position, node = v, label = "Drive"})


# Unregister every vehicle (main.gd rebuilds them when a chat edit changes the "vehicles" list).
func remove_vehicles() -> void:
	var kept: Array = []
	for it in items:
		if String(it.get("kind", "")) != "vehicle":
			kept.append(it)
	items = kept


# Wave 3 (sittable furniture): register a placed prop/populate instance as a USE "Sit" target.
# `seat_y` is the WORLD-space y of the seat surface — the placement path computes it as the
# object's AABB top clamped 0.3–1.2 m above the local ground. Entries share the sdoor lifecycle:
# tagged with cell_key, dropped by remove_cell on eviction (which stands a seated player FIRST,
# so a hot-reload/eviction can never strand a posed player on a freed seat).
func add_seat(node: Node3D, seat_y: float, cell_key := "") -> void:
	if node == null or not is_instance_valid(node):
		return
	var wpos: Vector3 = node.global_position if node.is_inside_tree() else node.position
	items.append({kind = "seat", pos = wpos, node = node, label = "Sit",
		seat_y = seat_y, seated = false, cell = cell_key})


# Wave 2 (ladder climb): register a placed ladder/scaffold as a USE "Climb" target. `pos` is the
# ladder's grounded FOOT (world), `height` the climb extent, `facing` the outward horizontal the
# player steps onto at the top. base_y/top_y bracket the vertical travel the player-controller drives
# (velocity.y between them — the ONE exception to the no-vertical-face rule). Shares the seat/door
# cell lifecycle: tagged with cell_key, dropped by remove_cell on eviction so a ladder never ghosts
# after its cell is freed. Standing at the foot within the normal ~2.9m USE range attaches on USE.
func add_ladder(pos: Vector3, height: float, facing: Vector3, root: Node3D, cell_key := "") -> void:
	var base_y := pos.y
	items.append({kind = "ladder", pos = pos, node = root, label = "Climb",
		height = height, base_y = base_y, top_y = base_y + height, facing = facing, cell = cell_key})


# A PERSISTENT world-anchored custom interactable (map beacons etc.) — never cell-parented,
# so it survives chunk eviction; the callable owns what USE does.
func add_action(pos: Vector3, label: String, cb: Callable) -> Dictionary:
	var it := {kind = "action", pos = pos, label = label, cb = cb}
	items.append(it)
	return it


# Drop a cell's interactables from the registry when the cell is evicted (chunk mode). The
# visual nodes are freed by the cell root's queue_free; this just clears the stale entries so
# no "ghost" door/structure-door/npc/chest/seat lingers in items[]. If the dying cell holds the
# seat the player is sitting ON (eviction or an in-place hot-reload rebuild), stand them safely
# FIRST — pose restored + placed beside the seat — mirroring vehicle._exit_tree's force-restore.
func remove_cell(cell_key: String) -> void:
	if cell_key == "":
		return
	var kept: Array = []
	for it in items:
		if String(it.get("cell", "")) != cell_key:
			kept.append(it)
		elif String(it.get("kind", "")) == "seat" and it.get("seated", false):
			stand_player()   # the entry dies below; restore the player before dropping it
	items = kept


# ---------------- use ----------------

func try_use() -> void:
	if scene_manager and scene_manager.transitioning:
		return
	# While an NPC is speaking, USE is a no-op (the lines play through as audio); this
	# stops a second tap from re-triggering the talk mid-sentence.
	if _speaking:
		return
	if active:
		_advance()
		return
	# Wave 3: while SEATED, USE always means "stand up" — routed here BEFORE _nearest so a seated
	# player can never board a vehicle (or open anything else) without standing first. The seat
	# stays the nearest item anyway (its pos pins to the player at distance 0), this is the guard.
	if player_seated:
		stand_player()
		return
	var it = _nearest(2.9)
	if it == null:
		return
	# `interact` — ONE event for "the player used the thing they were standing at", carrying what
	# it was. Raised before the handler so a rule can react to a chest opening in the same frame,
	# and raised for every kind so an author never has to ask which ones are wired.
	fire("interact", {"id": String(it.get("id", it.get("label", ""))), "kind": String(it.kind)})
	match it.kind:
		"chest": _open_chest(it)
		"npc": _talk(it)
		"seam": _use_seam(it)
		"door": _open_door(it)
		"sdoor": _toggle_structure_door(it)
		"vehicle": _use_vehicle(it)
		"seat": _sit_player(it)
		"ladder": _climb_ladder(it)
		"action": (it.cb as Callable).call()


# ---------------- rule-layer API (`open_door` / `close_door` / `unlock_seam`) ----------------
#
# Addressed by `id` (authored) falling back to `label` (what the prompt says), and "" means every
# door / every seam. Each returns how many entries it touched so rules.gd can report a name that
# matched nothing rather than logging a success for a typo — the same contract as `hud_hide`.


func _addresses(it: Dictionary, key: String) -> bool:
	return key == "" or String(it.get("id", "")) == key or String(it.get("label", "")) == key


## Open or close doors by name. Covers BOTH door kinds: the hinged doors a chunk world places and
## the structure doors a building generates. A rule that says "open the gate" should not have to
## know which subsystem built it.
func set_door_open(key: String, want_open: bool) -> int:
	var n := 0
	for it in items:
		if not (it is Dictionary):
			continue
		var k := String((it as Dictionary).get("kind", ""))
		if k == "door" and _addresses(it, key):
			_swing_door(it, want_open)
			n += 1
		elif k == "sdoor" and _addresses(it, key):
			if bool((it as Dictionary).get("open", false)) != want_open:
				_toggle_structure_door(it)
			n += 1
	return n


## Clear the lock on a seam or door, so it opens without the key. The world-changing half of a
## quest reward: "the guard waves you through" is this, not a hidden item grant.
func unlock(key: String) -> int:
	var n := 0
	for it in items:
		if not (it is Dictionary):
			continue
		var k := String((it as Dictionary).get("kind", ""))
		if (k == "seam" or k == "door") and _addresses(it, key) and String((it as Dictionary).get("lock", "")) != "":
			(it as Dictionary)["lock"] = ""
			n += 1
	return n


## The rule layer's funnel. Null-safe: a world with no rules pays one branch.
func fire(event: String, payload: Dictionary) -> void:
	if main_ref == null:
		return
	var d = main_ref.get("director")
	if d != null and d.has_method("fire"):
		d.fire(event, payload)


func _nearest(rng: float):
	var best = null
	var bd := rng
	for it in items:
		if it.kind == "chest" and it.opened:
			continue
		if it.kind == "door" and it.get("open", false):
			continue
		if it.kind == "sdoor":
			# structure doors TOGGLE — an open one stays targetable so USE can close it; the
			# prompt flips Open<->Close. Skip entries whose leaf was freed (eviction in flight).
			var dn = it.get("node")
			if dn == null or not is_instance_valid(dn):
				continue
			it.label = _door_label(it)
		if it.kind == "vehicle":
			var vn = it.get("node")
			if vn == null or not is_instance_valid(vn):
				continue
			if main_ref != null and main_ref.get("active_vehicle") == vn:
				# PIN the DRIVEN vehicle to the player (distance 0): a tall mount seats the rider
				# >2.9m from the vehicle ORIGIN, so an origin-distance test made the USE-button
				# exit silently dead (QA P1-B: raptor/mirewyrm never dismounted via USE).
				it.pos = player.global_position
			else:
				it.pos = (vn as Node3D).global_position       # the car MOVES — track the live node
				# big hulls (scale-9 ferry): allow USE anywhere along the hull, not only within
				# 2.9m of the origin — credit half the hull length toward the range (QA W-3)
				it.reach = clampf(float(vn.get("hull_len")) * 0.5 - 0.5, 0.0, 6.0)
			it.label = (vn as Vehicle).prompt_label()     # "Drive …" parked / "" while driven
		if it.kind == "seat":
			var sn = it.get("node")
			if sn == null or not is_instance_valid(sn):
				continue   # furniture freed (eviction in flight) — remove_cell drops the entry
			# driving/riding: a seat is never a USE target (you can't sit down from the saddle);
			# main.gd tracks the boarded vehicle/mount as active_vehicle.
			if main_ref != null and main_ref.get("active_vehicle") != null:
				continue
			if it.get("seated", false):
				it.pos = player.global_position   # occupied seat pins to the player -> distance 0
				it.label = "Stand up"
			else:
				it.pos = (sn as Node3D).global_position   # track populate wrappers that were varied
				it.label = "Sit"
		if it.kind == "ladder":
			var ln = it.get("node")
			if ln != null and not is_instance_valid(ln):
				continue   # ladder node freed (eviction in flight) — remove_cell drops the entry
		var d: float = player.global_position.distance_to(it.pos) - float(it.get("reach", 0.0))
		if d < bd:
			bd = d
			best = it
	return best


func _open_chest(it: Dictionary) -> void:
	it.opened = true
	AudioManager.play_sfx("pickup")
	if is_instance_valid(it.node):
		(it.node as MeshInstance3D).material_override = _mat(Color(0.35, 0.28, 0.12))
	var got: Array = []
	for entry in it.contents:
		rpg.add_item(entry)
		got.append(rpg.item_name(entry))
		if rpg.item_type(entry) == "weapon":
			rpg.equip(entry, true)   # a found weapon always equips + draws — the player just picked it up to try it
	if it.gold > 0:
		rpg.add_gold(it.gold)
		got.append("%d gold" % it.gold)
	_show(["You opened the chest.", "Found: " + ", ".join(got) + "."])


func _use_seam(it: Dictionary) -> void:
	# a lock is satisfied by holding the item key OR by a quest flag being set
	if it.lock != "" and not rpg.has_item(it.lock) and not rpg.has_flag(it.lock):
		var need := rpg.item_name(it.lock) if rpg.ITEMS.has(it.lock) else "to clear the dungeon first"
		_show(["The door is locked.", "You need " + need + "."])
		return
	# real transition — fade + free current area + stream the next (door done right)
	scene_manager.goto_area(it.to, it.spawn)


func _open_door(it: Dictionary) -> void:
	if it.get("open", false):
		return
	# locked door: needs the item key OR a quest flag (same rule as a seam lock) — but the lock is
	# ONE-WAY: it bars entry only from the door's FRONT (+Z after facing) side. From the far
	# (inland) side the bar lifts by hand, so a keyless player who got behind the wall some other
	# way (boat, fall, respawn) is never permanently trapped.
	if it.lock != "" and not rpg.has_item(it.lock) and not rpg.has_flag(it.lock):
		var fwd := Vector3(sin(deg_to_rad(float(it.get("facing", 0.0)))), 0.0, cos(deg_to_rad(float(it.get("facing", 0.0)))))
		var from_front: bool = (player.global_position - (it.pos as Vector3)).dot(fwd) >= 0.0
		if from_front:
			var need := rpg.item_name(it.lock) if rpg.ITEMS.has(it.lock) else "a key"
			_show(["The door is locked.", "You need " + need + "."])
			return
	_swing_door(it, true)
	_show(["The door swings open."])


## Open or close a hinged door. Extracted from _open_door so the rule actions `open_door` /
## `close_door` drive the SAME code the player's USE does — a parallel implementation is how the
## two drift until a rule-opened door has no collider change and the player walks into thin air.
##
## Closing re-enables the collider only when the leaf is shut, never mid-swing, so a player standing
## in the doorway is not caught inside a sweeping shape (the rule structure doors already follow).
func _swing_door(it: Dictionary, want_open: bool) -> void:
	if bool(it.get("open", false)) == want_open:
		return
	it.open = want_open
	AudioManager.play_sfx("door")
	var pv = it.get("pivot")
	if want_open and is_instance_valid(it.get("shape")):
		(it.shape as CollisionShape3D).disabled = true   # walk through now
	if pv != null and is_instance_valid(pv):
		var node := pv as Node3D
		var old_tw = it.get("tween")
		if old_tw != null and (old_tw as Tween).is_valid():
			(old_tw as Tween).kill()
		var closed := float(it.get("closed_yaw", node.rotation.y))
		var tw := node.create_tween()
		it["tween"] = tw
		tw.tween_property(node, "rotation:y", closed + (deg_to_rad(95.0) if want_open else 0.0), 0.45)
		if not want_open:
			tw.tween_callback(func() -> void:
				if bool(it.get("open", false)):
					return              # reopened while closing — leave it passable
				if is_instance_valid(it.get("shape")):
					(it.shape as CollisionShape3D).disabled = false)
	elif not want_open and is_instance_valid(it.get("shape")):
		(it.shape as CollisionShape3D).disabled = false


# USE on a structure interior door (Wave 2): TOGGLE. Open = swing the leaf about its hinge-edge
# pivot (~100° over ~0.4s, same feel as _open_door) + disable its collider shapes so the player
# walks through; close = swing back to the registered closed yaw, colliders re-enabled only once
# the leaf is fully shut (never mid-swing, so a player in the doorway isn't trapped inside a
# sweeping shape). The tween is bound to the LEAF (pv.create_tween()) so cell eviction mid-swing
# kills it cleanly instead of tweening a freed node. Re-USE mid-swing retargets from the current
# angle (the old tween is killed first).
func _toggle_structure_door(it: Dictionary) -> void:
	var leaf = it.get("node")
	if leaf == null or not is_instance_valid(leaf):
		return
	var pv := leaf as Node3D
	AudioManager.play_sfx("door")
	var old_tw = it.get("tween")
	if old_tw != null and (old_tw as Tween).is_valid():
		(old_tw as Tween).kill()
	var tw := pv.create_tween()
	it["tween"] = tw
	if it.get("open", false):
		it.open = false
		tw.tween_property(pv, "rotation:y", float(it.get("closed_yaw", 0.0)), 0.4)
		tw.tween_callback(func() -> void:
			if bool(it.get("open", false)):
				return   # reopened while closing — leave the shapes disabled
			for s in it.get("shapes", []):
				if is_instance_valid(s):
					(s as CollisionShape3D).disabled = false)
	else:
		it.open = true
		for s in it.get("shapes", []):
			if is_instance_valid(s):
				(s as CollisionShape3D).disabled = true
		tw.tween_property(pv, "rotation:y", float(it.get("closed_yaw", 0.0)) + deg_to_rad(100.0), 0.4)


# Prompt label for a structure door: the registered label while shut (e.g. "Open Door"), its
# Open->Close counterpart while open, so the USE prompt reads as the toggle it is.
func _door_label(it: Dictionary) -> String:
	var base := String(it.get("open_label", "Open Door"))
	if not it.get("open", false):
		return base
	return base.replace("Open", "Close") if "Open" in base else "Close " + base


# Enter/exit a drivable vehicle (vehicle.gd dispatches on its own driving state). While driving,
# the player is parked ON the car, so the car is always the nearest item -> USE reads "Exit".
# Defensive Wave-3 guard: a SEATED player never reaches here (try_use routes USE to stand_player
# first), but if a future caller dispatches directly, refuse — stand first, then board.
func _use_vehicle(it: Dictionary) -> void:
	if player_seated:
		return
	var v = it.get("node")
	if v != null and is_instance_valid(v) and player is CharacterBody3D:
		if not (v as Vehicle).use(player as CharacterBody3D):
			# boarding guard mid enter/exit choreography: retry once shortly instead of
			# silently eating the press (an eaten USE reads as a broken button on touch)
			var t := get_tree().create_timer(0.45)
			t.timeout.connect(func() -> void:
				if is_instance_valid(v) and player is CharacterBody3D and not (v as Vehicle).driving:
					(v as Vehicle).use(player as CharacterBody3D))


# ---------------- sittable furniture (Wave 3) ----------------

# USE on a free seat: remember where the player came from, park them on the seat point (the
# object's AABB top centre at the registered seat_y), pose them seated (GPose.sit — the same
# reversible bone-override preset the vehicle uses), and freeze movement via player_seated
# (main.gd's movement branch gates on it; any movement input stands them back up). An unrigged
# capsule player is simply PERCHED on the seat top — no hide, a sitting capsule reads fine.
func _sit_player(it: Dictionary) -> void:
	if player_seated or not (player is CharacterBody3D):
		return
	var sn = it.get("node")
	if sn == null or not is_instance_valid(sn):
		return
	var seat_node := sn as Node3D
	# seat point = AABB top CENTRE (the node origin can sit at a corner of odd furniture GLBs),
	# at the placement-computed seat_y (AABB top clamped 0.3–1.2 m above the local ground).
	var sab := _subtree_aabb(seat_node)
	var seat_point := seat_node.global_position
	if sab.size != Vector3.ZERO:
		var sc := sab.get_center()
		seat_point.x = sc.x
		seat_point.z = sc.z
	seat_point.y = float(it.get("seat_y", seat_point.y + 0.5))
	it["return_pos"] = player.global_position
	it["seat_point"] = seat_point
	# hip placement mirrors vehicle._seat_driver: measure the STANDING height first (the pose
	# changes the AABB), drop the character origin so the hips land on the seat surface.
	var dh := _subtree_aabb(player).size.y
	if dh < 0.5:
		dh = 1.7
	var y_off := SEAT_SINK - SEAT_HIP_RATIO * dh
	if not GPose.sit(player):
		y_off = 0.0   # unrigged capsule: base on the seat top, visible (no hide)
	player.global_position = seat_point + Vector3(0.0, y_off, 0.0)
	(player as CharacterBody3D).velocity = Vector3.ZERO
	it["seated"] = true
	it.pos = player.global_position   # pin the occupied seat to the player: distance 0 -> USE = stand
	_active_seat = it
	player_seated = true


# USE on a ladder: hand the player-controller the climb bracket. It drives velocity.y between base_y
# and top_y, pins the player to the ladder xz (climbing.pos), and at the top steps FORWARD onto the
# surface along `facing` (then sets climbing = null). main_ref.climbing is a Dictionary the controller
# reads each physics frame; null when not climbing. Shape matches CONTRACT C exactly (pos/base_y/top_y/
# facing). Zero the velocity so no residual horizontal carry drifts the player off the first rung.
func _climb_ladder(it: Dictionary) -> void:
	if main_ref == null:
		return
	main_ref.climbing = {
		pos = it.get("pos", Vector3.ZERO),
		base_y = float(it.get("base_y", 0.0)),
		top_y = float(it.get("top_y", 0.0)),
		facing = it.get("facing", Vector3.FORWARD),
	}
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO


# Stand up from the occupied seat (PUBLIC — called by try_use, by main.gd when movement input
# arrives while seated, and by remove_cell when the seat's cell dies under the player). Restores
# the pose (GPose.stand — exact pre-sit bone poses + resumed clip), then places the player 0.8 m
# from the seat point back toward where they came from, grounded via GTerrain.height when a
# terrain exists (flat/zone worlds ground at y 0). Safe to call when not seated (no-op).
func stand_player() -> void:
	if not player_seated:
		return
	player_seated = false
	var it = _active_seat
	_active_seat = null
	if player == null or not is_instance_valid(player):
		return
	GPose.stand(player)
	if not (it is Dictionary):
		return
	it["seated"] = false
	var seat_point: Vector3 = it.get("seat_point", player.global_position)
	var back: Vector3 = (it.get("return_pos", seat_point) as Vector3) - seat_point
	back.y = 0.0
	# degenerate approach vector (sat down in place): step out the way the character faces
	var dir := back.normalized() if back.length() > 0.05 else player.global_transform.basis.z
	var spot := seat_point + dir * 0.8
	spot.y = (terrain.height(spot.x, spot.z) if terrain != null else 0.0) + 0.1
	player.global_position = spot
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	# the freed seat's prompt should target the furniture again, not the player's old spot
	var sn = it.get("node")
	if sn != null and is_instance_valid(sn):
		it.pos = (sn as Node3D).global_position


func _talk(it: Dictionary) -> void:
	talks += 1
	fire("talk", {"id": String(it.get("npc_id", "")), "name": String(it.get("npc_name", ""))})
	# VOICE, not a text box: speak the NPC's lines aloud (distinct per-character voice).
	if quest and String(it.get("npc_id", "")) != "":
		quest.notify_talk(it.npc_id)   # advances any talk_to quest objective
	var v := _npc_voice(it)
	for line in it.lines:
		_enqueue_speech(String(line), v, String(it.get("npc_name", "")))
	if not it.asked:
		it.asked = true
		_ask_brain(it)   # the live in-character reply gets SPOKEN when it returns


# ---------------- dialogue ----------------

func _show(lines: Array) -> void:
	dlg_queue = lines.duplicate()
	active = true
	dlg_box.visible = true
	_advance(true)


func _advance(first := false) -> void:
	if not first and not dlg_queue.is_empty():
		dlg_queue.pop_front()
	if dlg_queue.is_empty():
		active = false
		dlg_box.visible = false
		return
	dlg_label.text = str(dlg_queue[0])


func _queue_line(text: String) -> void:
	if active:
		dlg_queue.append(text)


func _ask_brain(it: Dictionary) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	var v := _npc_voice(it)
	req.request_completed.connect(func(_r: int, c: int, _h: PackedStringArray, b: PackedByteArray) -> void:
		if c == 200:
			var d = JSON.parse_string(b.get_string_from_utf8())
			if d is Dictionary and d.has("reply") and str(d["reply"]) != "":
				_enqueue_speech(str(d["reply"]), v, String(it.get("npc_name", "")))
		req.queue_free())
	var payload := JSON.stringify({
		"persona": it.persona,
		"messages": [{"role": "user", "content": "Greet the hero in one short sentence and give a hint."}],
	})
	req.request(NPC_BRAIN, ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)


# ---------------- spoken NPC dialogue (TTS) ----------------

# Queue a line to be SPOKEN. The shared /speak endpoint returns MP3 audio we play through
# voice_player; lines play sequentially (queue drained on each `finished`). A leading
# "Name: " prefix is stripped so the voice doesn't read the speaker's own name aloud.
func _enqueue_speech(text: String, voice: String, name: String) -> void:
	var clean := _strip_speaker(text)
	if clean.strip_edges() == "":
		return
	_speak_queue.append({"text": clean, "voice": voice, "name": name})
	if not _speaking:
		_speak_next()


func _speak_next() -> void:
	if _speak_queue.is_empty():
		_speaking = false
		_speaker_name = ""
		return
	_speaking = true
	var item: Dictionary = _speak_queue.pop_front()
	_speaker_name = String(item.get("name", ""))
	if voice_player == null:
		# no audio device (shouldn't happen) — just drain so we don't wedge
		_speak_next()
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, c: int, _h: PackedStringArray, b: PackedByteArray) -> void:
		req.queue_free()
		if c == 200 and b.size() > 0:
			var stream := AudioStreamMP3.new()
			stream.data = b
			voice_player.stream = stream
			voice_player.play()   # _on_voice_finished advances the queue when it ends
		else:
			# TTS unavailable (rate limit / no key / network) — skip this line so the
			# conversation still advances instead of hanging on a silent gap.
			_on_voice_finished())
	var payload := JSON.stringify({"text": item.get("text", ""), "voice": item.get("voice", "")})
	req.request(NPC_SPEAK, ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)


# Connected to voice_player.finished; also called on a failed fetch — advance the queue.
func _on_voice_finished() -> void:
	_speak_next()


# Deterministic distinct voice per character (stable across a session) from its id/name.
func _npc_voice(it: Dictionary) -> String:
	var key := String(it.get("npc_id", it.get("npc_name", "")))
	if key == "":
		return VOICES[0]
	var h := 0
	for i in key.length():
		h = (h * 31 + key.unicode_at(i)) % 1000000007
	return VOICES[h % VOICES.size()]


# Drop a leading "Name: " label from an authored line so TTS speaks only the words.
func _strip_speaker(text: String) -> String:
	var idx := text.find(": ")
	if idx > 0 and idx < 24:
		return text.substr(idx + 2)
	return text


# ---------------- build helpers ----------------

func _build_ui(hud: CanvasLayer) -> void:
	prompt = Label.new()
	prompt.add_theme_font_size_override("font_size", 26)
	prompt.add_theme_color_override("font_color", Color(1, 1, 0.6))
	# Proportional band at ~58% height, full width, centered text: over the play area and clear
	# of the right-hand button columns at ANY aspect (a CENTER_BOTTOM offset label rendered
	# straight across SHEATHE on phones).
	prompt.anchor_left = 0.0
	prompt.anchor_right = 1.0
	prompt.anchor_top = 0.58
	prompt.anchor_bottom = 0.58
	prompt.offset_top = 0.0
	prompt.offset_bottom = 40.0
	prompt.offset_left = 0.0
	prompt.offset_right = 0.0
	prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(prompt)

	# System-message box (chest opened / door locked / item found) — moved to the TOP so it
	# NEVER covers the bottom touch controls (USE/ATTACK/POTION). NPC talk no longer uses this
	# (it's spoken aloud); this is only for brief world/system notices.
	dlg_box = PanelContainer.new()
	dlg_box.set_anchors_preset(Control.PRESET_TOP_WIDE)
	dlg_box.offset_left = 40
	dlg_box.offset_right = -40
	dlg_box.offset_top = 40
	dlg_box.offset_bottom = 150
	dlg_box.visible = false
	dlg_box.mouse_filter = Control.MOUSE_FILTER_STOP
	dlg_box.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventScreenTouch or e is InputEventMouseButton) and e.is_pressed():
			_advance())
	dlg_label = RichTextLabel.new()
	dlg_label.bbcode_enabled = true
	dlg_label.fit_content = true
	dlg_label.add_theme_font_size_override("normal_font_size", 28)
	dlg_box.add_child(dlg_label)
	hud.add_child(dlg_box)

	# Audio sink for spoken NPC dialogue (created once, lives on this system node).
	voice_player = AudioStreamPlayer.new()
	add_child(voice_player)
	voice_player.finished.connect(_on_voice_finished)


func _box(pos: Vector3, sz: Vector3, col: Color, parent: Node = null) -> MeshInstance3D:
	var par: Node = parent if parent != null else area_parent
	var body := StaticBody3D.new()
	body.position = pos
	body.collision_layer = 1
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = _mat(col)
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = sz
	cs.shape = bs
	body.add_child(cs)
	par.add_child(body)
	return mi


func _capsule(pos: Vector3, col: Color, parent: Node = null) -> void:
	var par: Node = parent if parent != null else area_parent
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.7
	mi.mesh = cm
	mi.position = pos + Vector3(0, 0.85, 0)
	mi.material_override = _mat(col)
	par.add_child(mi)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


# Idle-animate an NPC model IN PLACE. Self-animated models (a Meshy character ships a merged
# AnimationPlayer with idle/walk/...) loop their idle so generated people don't stand frozen.
# KayKit library models import an EMPTY AnimationPlayer (no clips) -> this no-ops and they stay
# static, exactly as before (zero regression). No external rig libraries required.
func _idle_animate(model: Node) -> void:
	var ap := _find_anim_player(model)
	if ap != null and not ap.get_animation_list().is_empty():
		var clips := ap.get_animation_list()
		var pick := String(clips[0])
		for n in clips:
			if "idle" in String(n).to_lower():
				pick = String(n)
				break
		var a := ap.get_animation(pick)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		ap.play(pick)
		return
	# NO clips (KayKit/Kenney library rigs import an EMPTY AnimationPlayer) -> a PROCEDURAL idle so
	# the character subtly breathes/sways instead of standing dead-frozen (frozen crowds read as
	# lifeless cardboard). A real walk/idle clip from the rig always wins over this.
	_procedural_idle(model)


# A tiny looping breathe bob so unanimated library characters feel alive instead of dead-frozen.
func _procedural_idle(model: Node) -> void:
	if not (model is Node3D):
		return
	var m := model as Node3D
	var base_y := m.position.y
	var phase := randf() * TAU   # desync crowds so they don't bob in lockstep
	var bob := create_tween().set_loops()
	bob.tween_method(func(t: float) -> void:
		if is_instance_valid(m):
			m.position.y = base_y + sin(t) * 0.025,
		phase, phase + TAU, 2.4).set_trans(Tween.TRANS_LINEAR)


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null


# Merged world-space mesh bounds of a subtree — for grounding a character so its feet rest at y=0.
func _subtree_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged
