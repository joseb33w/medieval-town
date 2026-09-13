extends CharacterBody3D
## Enemy: CharacterBody3D + NavigationAgent3D chase with RVO avoidance so enemies ENCIRCLE
## the player (distinct slot angle per index) instead of clumping. Melee w/ cooldown,
## health, death. The streamed KayKit skeleton GLBs carry NO embedded clips, so the
## animations are RETARGETED from the packed kk_rig_medium_* libraries via AnimRig
## (anim_rig.gd) — see animation.md. Falls back to no-anim if those libs aren't packed.

var world: Node
var player: Node3D
var anim: AnimationPlayer
var agent: NavigationAgent3D
var mesh_root: Node3D

var _hp_marks: Array = []   # hp fractions the rule layer watches for THIS kind (see _report_hp_crossing)
var hp := 120.0             # base pool. Raised from 90 for clearer multi-hit feel; combined with the
                            # per-hit cap in take_hit (a single blow can never exceed HIT_CAP_FRAC of
                            # hp_max) this GUARANTEES no weapon one-shots an enemy — always 2+ clean
                            # hits, regardless of weapon upgrades. Per-region/tier scaling: playbook #16.
var hp_max := 120.0         # spawn pool, captured in setup(); the never-one-shot cap is relative to it
const HIT_CAP_FRAC := 0.55  # a single hit removes at most this fraction of hp_max -> min 2 hits to kill
var speed := 3.3
var kind := "skeleton"      # reported on death -> kill_count quest match (honors cell.enemy_type)
var dead := false
var atk_cd := 0.0
var flash_t := 0.0
var slot_angle := 0.0       # distinct approach angle so enemies encircle, not clump
var surround_radius := 1.7
var attack_range := 2.0

var c_idle := ""
var c_walk := ""
var c_swim := ""            # swim/tread clip (empty -> GPose.swim fallback pose)
var c_fly := ""             # fly/flap clip for aerial creatures (bat/pterodactyl); empty -> falls back to walk
var c_attack := ""
var c_die := ""
var c_hurt := ""
var hurt_t := 0.0           # brief flinch hold so locomotion doesn't override the hurt clip
var _cur := ""


const MAX_ENEMY_H := 3.0    # cap absurdly-large Meshy enemy models so a giant can't fill the frame ("monster popup" / full-screen mass); normal enemies are untouched. 4.0 still walled a portrait frame at melee range (gamefeel P1)
const CAM_FADE_NEAR := 1.6  # hide the enemy mesh when this close to the CAMERA so a body pressed against the lens can't wall the view
const ANIM_LOD_DIST := 26.0 # past this many metres from the player, FREEZE the skinned pose (stop the per-frame AnimationMixer skeleton update — the dominant main-thread cost when a camp packs dozens of skinned bodies); the close attacking cluster stays fully animated
static var _spawn_seq := 0  # monotonic across ALL enemies -> golden-angle encircle bearings that stay distinct ACROSS cells (a per-cell index repeats bearings between cells, so RVO agents fought the same point = blob vibration)
var _cam_hidden := false    # near-camera fade state (hysteresis) so a body hovering at the fade threshold doesn't flip visible/hidden every frame = flicker
var _walk_phase := 0.0      # procedural-walk gait phase for CLIPLESS creatures (anim == null) so they stride instead of sliding
var _moving := false        # dir-hysteresis (0.15/0.35): RVO jostle at the slot can't flip walk/idle/desired/velocity-hold every frame = jitter
var _gwalk := false         # true while GPose.walk drives the legs -> walk_stop runs ONCE on the stop edge (no per-frame WALK_META rebuild)
var _ground_stuck := false  # ground-stick latch (mirrors the player's main.gd fix): pinned to the heightmap this tick, so gravity doesn't re-fire and yo-yo the body over a not-yet-streamed collider = the FPS-independent vertical buzz
var _lod_far := false        # cached distance>ANIM_LOD_DIST (set in _physics_process, read by _process for the render-rate procedural walk)
# PARK-LOCK: the enemy-only "whole body vibrates, even standing still" buzz was ROOT-CAUSED by an
# A/B pair of freeze tests — freezing the ANIM (body still moving) was smooth, AND freezing the BODY (anim still
# playing) was smooth (user-confirmed A/B). So the buzz is neither the clip nor the movement alone: it is
# the per-PHYSICS-TICK body transform being micro-noisy (move_and_slide's collision/gravity re-solve on uneven
# island terrain + damped _face yaw) while the render-rate skinned ANIMATION amplifies that base-transform noise
# out at the limbs — worst on big creatures (colossus/snake/dino) where the lever arm magnifies a sub-degree wobble.
# FTI faithfully interpolates THROUGH the noisy per-tick waypoints; it can't denoise them. Fix: when a creature
# has ARRIVED and is holding its slot on the ground, hold its transform byte-stable (skip _face + move_and_slide)
# so FTI sees prev==curr = zero base wobble = smooth skin — the passive-child hero's exact no-buzz regime. Full
# physics resumes the instant it chases (position stays continuous, so no snap/reset needed). Parked creatures
# also do zero move/nav/collision work -> the same near-camp lag cut that A/B showed.
var _parked := false
# INTERPOLATED-MESH DRIVE: the moving-creature "only the creature vibrates, scene is smooth" jitter is
# the skinned mesh rendering at the RAW 60Hz physics-tick position (an active skeleton animation defeats the mesh
# subtree's own physics interpolation) while the FTI-smooth world glides -> a translating creature jumps ~speed/60
# per tick RELATIVE to the smooth scene. Freeze the anim (no skeleton update -> FTI works) or the body (no motion)
# -> smooth; interpolation on/off was a no-op because the anim overrode it either way; the hero is camera-locked to
# its own interpolated xform so it's masked. Fix: make mesh_root TOP-LEVEL + interp-OFF and set its global_transform
# from the body's get_global_transform_interpolated() every render frame -> the skin rides the SAME smooth path.
var _mesh_local := Transform3D.IDENTITY   # mesh_root's captured local offset (usually identity), preserved in the drive
var _mesh_driven := false                  # true once mesh_root is top-level-driven from the interpolated body xform
# VISUAL POSITION SMOOTHING: the confirmed moving-creature "shakes in place" is the BODY's per-tick
# position being noisy — move_and_slide sliding over the bumpy terrain trimesh + nav-path chatter + the analytic
# ground-snap produce a few-mm back-and-forth wobble every physics tick, which interpolation faithfully reproduces
# (drawing the mesh on the interpolated body path did NOT fix it — it still shook). The player/hero is smooth because it
# moves from clean joystick velocity, not nav-over-terrain. Fix: low-pass ONLY the RENDER position of the mesh
# (the invisible physics body keeps its exact collision position) -> erases the high-freq tremble, keeps the motion.
var _vis_pos := Vector3.ZERO               # exponentially-smoothed render position for mesh_root
const VIS_SMOOTH_TAU := 0.04               # LIGHT backstop now that direct-chase removes the nav-path wobble at the source; higher = smoother but more visual lag behind the body
const GRAVITY := 22.0       # match the player (main.gd): pull a chasing enemy DOWN onto the terrain each airborne frame so it can't ratchet up rolling hills and float into the sky
const FLOAT_WADE := 0.6     # water this deep over the seabed -> a land animal floats/swims instead of walking the bottom
const SWIM_MAX := 2.6       # HARD cap on a creature's in-water horizontal speed; player SWIM_SPEED=4.2 (main.gd) -> the player always out-swims every creature regardless of index desync / per-cell speed multiplier
const SWIM_KEEP := 3.5      # in-water stand-off radius: swimmers approach on their OWN bearing and hold >= this far out (no distributed ring) so they TRAIL the swimmer, never encircle/blob onto it
var _aquatic := false       # true -> rides ANY water (shark/croc/serpent); false land animal floats only when forced in
var _floating := false      # currently floating at the water surface (swim), not on the ground
var _submerge := 0.45       # how far below the surface the body rides (0.2 for aquatic so a fin shows)
var _aerial := false        # FLIES/hovers at altitude instead of walking (bat/pterodactyl/bird); no gravity, tracks terrain+hover_alt
var hover_alt := 4.0        # target flight altitude above the terrain below (per-type default; opts "hover" overrides)
var _air_keep := 1.0        # per-flyer stand-off multiplier — a shared radius reads as a formation
var _air_orbit := 0.0       # per-flyer slow orbit drift (rad/s, signed) so the flock rearranges in flight
var _bob_t := 0.0           # hover bob phase (advanced in _physics_process)
var _swoop := 0.0           # >0 = mid attack-dive: dips toward the player then rises so the flyer is reachable
var _stagger := 0           # per-enemy physics-frame offset so nav path re-solves spread across frames (not all on one)
const AERIAL_BOB := 0.5     # hover bob amplitude
const AERIAL_MAX_CLIMB := 45.0   # how high above the terrain a flyer will climb to chase a flying/high player (plane)
var body_h := 1.8           # model height after the MAX_ENEMY_H cap — the near-camera fade scales with it
var atk_damage := 9.0       # per-hit damage on the player — per-cell "enemy_damage" overrides (boss/creature tiers)
var max_h := MAX_ENEMY_H    # per-cell "enemy_height" raises the scale cap for a genuine BOSS (a colossus)

func setup(p: Node3D, model: Node, w: Node, index := 0, total := 1, etype := "skeleton", opts: Dictionary = {}) -> void:
	player = p
	world = w
	kind = etype
	# Per-cell creature tuning (all optional; authored on the cell record):
	#   enemy_hp / enemy_damage / enemy_speed / enemy_range / enemy_height — lets one enemy.gd serve
	#   a raptor (fast, light) and a colossal boss (huge, heavy) from DATA, no subclasses.
	hp = maxf(10.0, float(opts.get("hp", hp)))
	atk_damage = maxf(1.0, float(opts.get("damage", atk_damage)))
	attack_range = maxf(1.0, float(opts.get("range", attack_range)))
	max_h = clampf(float(opts.get("height", MAX_ENEMY_H)), 1.0, 14.0)   # per-cell "height" can scale a genuine boss up to this cap
	# AQUATIC (data flag or inferred from the type) rides any water; land animals only float when forced
	# into deep water. Drives the water/swim behavior in _on_safe_velocity.
	_aquatic = bool(opts.get("aquatic", false))
	if not _aquatic:
		var akl := etype.to_lower()
		for akw in ["shark", "croc", "gator", "sea_serpent", "serpent", "eel", "piranha", "marlin", "squid", "octopus", "manta", "ray", "dolphin", "whale", "fish", "crab"]:
			if akw in akl:
				_aquatic = true
				break
	_submerge = 0.2 if _aquatic else 0.45
	# AERIAL (data flag or inferred): flies/hovers at altitude instead of walking, so bats/pterodactyls/
	# birds command the air. "enemy_aerial": true OR "enemy_hover": <altitude> on the cell also enables it.
	_aerial = bool(opts.get("aerial", false)) or opts.has("hover")
	if not _aerial:
		var lkl := etype.to_lower()
		for lkw in ["bat", "pterodactyl", "ptero", "pteran", "wyvern", "bird", "eagle", "hawk", "vulture", "wasp", "bee", "dragonfly", "moth", "harpy", "imp", "fairy", "griffin", "phoenix", "raven", "crow", "gargoyle"]:
			if lkw in lkl:
				_aerial = true
				break
	if _aerial:
		var lkl2 := etype.to_lower()
		var def_alt := 6.0 if ("ptero" in lkl2 or "pteran" in lkl2 or "wyvern" in lkl2 or "dragon" in lkl2) else 3.5
		hover_alt = clampf(float(opts.get("hover", def_alt)), 1.5, 20.0)
		# DESYNC THE FLOCK. Every flyer started _bob_t at 0, took the same hover_alt and the same zero
		# attack cooldown, so five bats rose together, bobbed together and swooped on the SAME frame —
		# reading as one object with ten wings rather than five creatures. Per-instance phase, altitude
		# and stagger is the whole difference between a flock and a formation.
		_bob_t = randf() * TAU
		hover_alt = clampf(hover_alt + randf_range(-0.9, 0.9), 1.5, 20.0)
		atk_cd = randf() * 0.9
		# A RIGID RING IS STILL A FORMATION. Distinct angles alone only look varied while the player
		# stands still; the instant they move, every flyer chases a slot anchored to them at an
		# IDENTICAL radius and speed, so the whole flock glides along holding its shape. Give each one
		# its own stand-off and a slow orbit drift (own direction and rate) so the group keeps
		# rearranging instead of translating as one body.
		_air_keep = randf_range(0.75, 1.7)
		_air_orbit = randf_range(0.18, 0.5) * (1.0 if randf() < 0.5 else -1.0)
		# A FLYER MUST NOT SNAP TO THE FLOOR. floor_snap_length (set below for walkers, so feet stick to
		# descents) pulls the body down inside every move_and_slide when velocity.y <= 0 — which is
		# always true for a flyer, since aerial motion is horizontal velocity plus a direct y lerp.
		# The altitude code ran correctly the whole time and the snap simply undid it each frame:
		# measured target 3.77, actual y 0.38, forever. Bats walked.
		floor_snap_length = 0.0
	var spd_mul := clampf(float(opts.get("speed", 1.0)), 0.2, 2.5)
	hp_max = hp   # capture spawn pool so the never-one-shot cap tracks any region/tier hp scaling
	# Ask the rule layer ONCE what thresholds matter for this kind, so take_hit stays a cheap compare.
	if is_instance_valid(w) and w.get("director") != null and w.director.get("rules") != null:
		_hp_marks = w.director.rules.hp_marks_for(etype)
	collision_layer = 4   # enemy layer
	collision_mask = 1    # world only; RVO avoidance handles enemy separation
	floor_max_angle = deg_to_rad(55)   # match the player: climb steep terrain instead of stalling at 45°
	floor_snap_length = 0.0 if _aerial else 0.8   # walkers: feet stick to descents. Flyers: never — the snap cancels the hover lerp.
	_spawn_seq += 1
	slot_angle = fmod(float(_spawn_seq) * 2.399963229728653, TAU)   # golden-angle: globally-distinct approach bearings so index-i enemies in DIFFERENT cells don't share a slot and RVO-fight the same point (blob vibration)
	_stagger = index % 3   # spread nav re-solves across frames
	speed = (3.0 + float(index % 4) * 0.3) * spd_mul   # desync so they don't move as one blob
	surround_radius = maxf(surround_radius, attack_range * 0.85)   # a big-reach boss circles wider, not inside the player

	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.5
	cs.shape = cap
	cs.position.y = 0.75
	if max_h > MAX_ENEMY_H:
		# an authored BOSS height also grows the body/agent so the collider matches the colossus
		cap.radius = clampf(0.2 * max_h, 0.4, 2.4)
		cap.height = maxf(1.5, 0.72 * max_h)
		cs.position.y = cap.height * 0.5
	add_child(cs)

	agent = NavigationAgent3D.new()
	agent.radius = clampf(0.55 * (max_h / 1.8), 0.55, 2.6) if max_h > MAX_ENEMY_H else 0.55
	agent.height = cap.height
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.4
	# RVO AVOIDANCE OFF: enemies don't collide with each other (collision_mask=1, world-only), so avoidance was
	# PURELY cosmetic spacing — but in a tight cluster it shoved each body off its spot every physics frame =
	# the "whole body vibrates" jitter that survived every velocity/interp fix. The encircle comes from the
	# DISTINCT golden-angle slots (slot_angle), not from avoidance, so dropping it keeps the ring but kills the
	# buzz; bodies now follow the STABLE nav path straight to their bearing and the hold-gate parks them still.
	agent.avoidance_enabled = false
	agent.neighbor_distance = 2.5
	agent.max_neighbors = 5
	agent.max_speed = speed
	add_child(agent)
	agent.velocity_computed.connect(_on_safe_velocity)

	if model:
		mesh_root = Node3D.new()
		add_child(mesh_root)
		mesh_root.add_child(model)
		# scale-normalize (#6): cap a giant Meshy enemy so it can't fill the screen when it attacks.
		# Only shrinks models taller than MAX_ENEMY_H, then re-grounds the feet — normal enemies untouched.
		if model is Node3D:
			var m3 := model as Node3D
			# SKINNING-AWARE height: a Meshy rig parks its skinned mesh under a 0.01-scale Armature,
			# so the merged mesh AABB under-measures (~0.02m) and the boss branch over-scaled the root
			# ~550x (a boss rendered as an invisible ~1000m sky-colossus). Measure a RIGGED model from
			# its skeleton's global-rest bone span x cumulative node scale (main.gd _char_height
			# idiom); unrigged models keep the mesh AABB.
			var rig_h := _char_height(m3)
			var mh := rig_h
			var mab := _model_aabb(m3)
			if mh <= 0.05:
				mh = mab.size.y
			if mh > 0.01 and absf(mh - max_h) > 0.01 and (opts.has("height") or mh > MAX_ENEMY_H):
				# normal enemies: shrink-only to the cap. A cell that AUTHORED a bigger enemy_height
				# (a boss) is scaled TO that height, up or down, so a colossus is colossal by data.
				m3.scale *= max_h / mh
				if rig_h <= 0.05:
					# mesh-AABB re-ground is only trustworthy for UNRIGGED models; rigged Meshy
					# characters keep their feet-at-origin convention (the AABB is the wrong frame).
					mab = _model_aabb(m3)
					m3.position.y -= mab.position.y
				mh = max_h
			body_h = clampf(mh, 0.8, max_h)
		anim = _find_anim(model)
		if anim == null and model is Node3D:
			# clipless KayKit skeletons: retarget the packed clips (a foreign Meshy rig won't match -> null -> the
			# clipless GPose path in _process animates the legs procedurally).
			anim = AnimRig.attach(model as Node3D, {
				"idle": "Idle_A", "walk": "Walking_A",
				"attack": "Melee_1H_Attack_Chop", "death": "Death_A", "hurt": "Hit_A",
			}, ["idle", "walk"])
		_resolve_clips()
		_play(c_idle)   # play the model's OWN clean embedded clips, exactly like the hero (main.gd) does — these
		#                 anims are verified clean (identical structure to hero_jack); the enemy-only anim.active LOD
		#                 toggle that USED to fight them here has been removed (it was the jitter).
		# FAR-DISTANCE CULL: a high-poly Meshy creature is expensive to DRAW on a mobile GPU. Stop drawing one
		# that's beyond the immediate action, so a camp only renders the creatures near the player instead of the
		# whole spread pack. Hard cutoff (no dither). Scaled by body size so a big BOSS stays visible far
		# while small creatures cull near. AI/attack are unaffected (this only gates rendering).
		_set_far_cull(mesh_root, maxf(22.0, body_h * 6.0))
		# INTERPOLATED-MESH DRIVE (see _mesh_driven doc): detach mesh_root from the body's raw transform and
		# render it on the body's SMOOTH interpolated path every frame, so the animated skin can't defeat
		# interpolation and jump in per-tick steps against the smooth world. Body still does all physics/collision.
		_mesh_local = mesh_root.transform
		mesh_root.top_level = true
		mesh_root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_vis_pos = global_position   # seed the smoothed render position
		mesh_root.global_transform = global_transform * _mesh_local   # seed so frame 0 doesn't streak from origin
		_mesh_driven = true
	else:
		var mi := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.4
		cm.height = 1.5
		mi.mesh = cm
		mi.position.y = 0.75
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.55, 0.57, 0.6)   # neutral "loading" gray, not a jarring red — the model hot-swaps in when its fetch lands (#9)
		mi.material_override = m
		add_child(mi)
		mesh_root = mi
		print("GOGI_PLACEHOLDER enemy ", kind)   # verify.mjs asset-fail gate: a gray enemy box is visible


func _physics_process(delta: float) -> void:
	if dead or not is_instance_valid(player):
		return
	atk_cd = max(0.0, atk_cd - delta)
	flash_t = max(0.0, flash_t - delta)
	hurt_t = max(0.0, hurt_t - delta)
	# ANIM-LOD: freeze the skinned pose of a FAR character (stop the per-frame AnimationMixer skeleton
	# update — the dominant main-thread cost when a dense camp packs dozens of skinned bodies). Guarded
	# on `_cur != ""` so a body that SPAWNED beyond the gate (a 3x3-ring corner reaches ~22-34m) is never
	# frozen in its bind/T-pose before its first clip plays; it re-animates the instant you close in.
	_lod_far = global_position.distance_to(player.global_position) > ANIM_LOD_DIST
	# (anim-LOD anim.active toggle REMOVED — it was the enemy-only manipulation the hero didn't have, and toggling
	# a playing AnimationMixer's `active` was the source of the creature "vibrate". The far-cull already stops
	# DRAWING distant creatures; the animation just plays cleanly like the hero's.)
	if _aerial:
		_bob_t += delta * 3.0
		_swoop = maxf(0.0, _swoop - delta * 1.4)
		slot_angle = fmod(slot_angle + _air_orbit * delta, TAU)   # circle the player at our own rate

	var ppos: Vector3 = player.global_position
	var to: Vector3 = ppos - global_position
	to.y = 0.0
	var dist := to.length()
	_report_detection(dist)
	var desired := Vector3.ZERO

	# attack when in range, INDEPENDENT of movement (so they don't stop and pile up)
	if dist <= attack_range and atk_cd <= 0.0:
		atk_cd = 1.3
		_play(c_attack, false)
		if _aerial:
			_swoop = 1.0   # dive toward the player on this attack, then rise back to hover
		if player.has_method("take_damage"):
			player.call("take_damage", atk_damage)
		elif is_instance_valid(world) and world.has_method("take_damage"):
			world.call("take_damage", atk_damage)   # the code-built player body carries no script — main owns HP

	# ON LAND: a distinct slot AROUND the player -> enemies encircle, not bunch. IN WATER *or AIR*: hold on
	# our OWN approach bearing at a WIDE stand-off so swimmers/flyers TRAIL the player instead of ringing it.
	var slot: Vector3
	if _floating:
		# SWIMMERS trail on their OWN bearing — deliberate, so they never encircle a swimmer.
		var bear := global_position - ppos
		bear.y = 0.0
		if bear.length() < 0.05:
			bear = Vector3(cos(slot_angle), 0.0, sin(slot_angle))
		slot = ppos + bear.normalized() * maxf(SWIM_KEEP, surround_radius)
	elif _aerial:
		# FLYERS take their DISTINCT golden-angle slot, exactly as ground enemies do. Sharing the
		# swimmers' own-bearing rule was the clumping: after a swoop every bat came out on nearly the
		# same bearing, and nothing in the loop ever pushed them apart again, so the flock merged into
		# a single point and stayed there.
		slot = ppos + Vector3(cos(slot_angle), 0.0, sin(slot_angle)) * (maxf(SWIM_KEEP, surround_radius) * _air_keep)
	else:
		slot = ppos + Vector3(cos(slot_angle), 0.0, sin(slot_angle)) * surround_radius
	# CHASE THE SLOT DIRECTLY — no NavigationAgent path re-solve. ROOT CAUSE of the "all creatures
	# shake back-and-forth while moving": the staggered path re-solve (every 3rd frame) + get_next_path_position()
	# fed a small PERIODIC direction kick into `dir` each time the path rebuilt to the moving target, and the
	# damped velocity carried that as a per-frame wobble. Proven to be MOVEMENT (not the models/rig/anim) because
	# the rig-less STATIC meshes (centipede/scorpion/crab — no skeleton at all) shake identically. The slot is a
	# smooth function of the player position, so aiming straight at it gives a smooth heading. move_and_slide
	# still resolves collision; on the open island, direct chase is fine (a stuck body slides along structures).
	var dir := slot - global_position
	dir.y = 0.0
	# MOVING is HYSTERETIC (0.15 off / 0.35 on): the RVO slot-jostle makes dir chatter across a bare 0.2
	# threshold every frame, which flip-flopped desired/walk/idle = vibration. One latched state gates them all.
	# HOLD once arrived at the assigned encircle slot (not just at the player): a packed melee ring otherwise
	# never latches _moving=false, so RVO keeps shoving each body off its golden-angle slot every physics frame
	# = the residual cluster buzz interpolation can't cancel. Gating on slot-arrival (any bearing) holds the
	# FULL 360 ring still while attacking; chase resumes only when the (player-anchored) slot pulls away again.
	var slot_d := (slot - global_position).length()
	if _moving:
		if dir.length() < 0.15 or slot_d < 0.35:
			_moving = false
	elif dir.length() > 0.35 and slot_d > 0.7:
		_moving = true
	if _moving:
		desired = dir.normalized() * speed
	# PARKED = arrived + holding slot on the ground: once parked we HOLD the transform byte-stable so
	# an idle creature's skin has zero base-transform change (fixes the standing-still buzz, user-confirmed).
	# Rotation is NOT the moving-creature buzz (zero body yaw still buzzed — proven by A/B), so a non-parked
	# creature just faces the player naturally.
	_parked = (not _moving) and _ground_stuck and (not _aerial) and (not _floating)
	if not _parked:
		_face(to)
	# anim: aerial holds a flap/fly clip; grounded uses walk/idle (float pose is held by _enter_float)
	if _aerial:
		if _cur != c_attack and hurt_t <= 0.0:
			var fclip := c_fly if c_fly != "" else c_walk
			if fclip != "" and _cur != fclip:
				_play(fclip)
	elif not _floating and _cur != c_attack and hurt_t <= 0.0:
		_play(c_walk if _moving else c_idle)

	# CLIPLESS creature (no embedded clips + a foreign rig -> AnimRig returned null, so `anim` is null): the
	# NOTE: the procedural leg-swing now runs in _process (render rate) — see _process() — so it matches the
	# physics-INTERPOLATED mesh. Driving it here (60Hz physics) lagged the interpolated body = the jitter.

	# avoidance is OFF, so the velocity_computed callback never fires — drive the move DIRECTLY with the stable
	# desired velocity (the same _on_safe_velocity path: damp/hold + gravity + water/aerial + fall-catcher). No
	# RVO in the loop = no per-frame shove = no cluster vibration.
	_on_safe_velocity(desired)


# PROCEDURAL WALK at RENDER RATE. For a clipless creature (its noisy embedded clips are frozen -> anim==null),
# swing the legs HERE in _process, not in _physics_process — so the bone poses update at the SAME cadence as the
# physics-INTERPOLATED mesh. Bones stepped at the 60Hz physics tick under a render-rate interpolated body is what
# read as the per-frame skinned "vibrate". Movement/gravity stay in _physics_process; this is render-only cosmetics.
func _process(delta: float) -> void:
	# INTERPOLATED-MESH DRIVE (see _mesh_driven doc): render the skinned mesh on the body's SMOOTH interpolated
	# path every frame, so an active skeleton animation can't make it snap to the raw per-tick physics position
	# and jump against the interpolation-smoothed world = the moving-creature vibrate. Runs for ALL creatures,
	# every state (incl. death) so the mesh never detaches from the body.
	if _mesh_driven and is_instance_valid(mesh_root):
		var _bt := get_global_transform_interpolated()
		# low-pass ONLY the position (rotation follows directly — rotation is not the noise). Frame-rate
		# independent exponential smoothing toward the true body position; the invisible body keeps exact collision.
		var _k := clampf(delta / VIS_SMOOTH_TAU, 0.0, 1.0)
		_vis_pos = _vis_pos.lerp(_bt.origin, _k)
		mesh_root.global_transform = Transform3D(_bt.basis, _vis_pos) * _mesh_local
	if dead or not is_instance_valid(player):
		return
	# CLIPLESS creature (anim == null): swing the legs procedurally at render rate.
	if anim != null or _aerial or _floating:
		return
	if _moving and not _lod_far:
		_walk_phase += delta * (5.0 + speed)
		GPose.walk(self, _walk_phase)
		_gwalk = true
	elif _gwalk:
		GPose.walk_stop(self)
		_gwalk = false


func _on_safe_velocity(safe: Vector3) -> void:
	if dead:
		return
	# GRAVITY + floor-snap so the enemy HUGS the terrain on descents. The old forced
	# y=0 velocity (no gravity) kept the body's height as the ground fell away, and the
	# up-only fall-catcher below never pulls DOWN — so across rolling terrain an enemy
	# RATCHETED upward (climbing every hill via slope-collision, never descending) until
	# it floated. Invisible on foot; glaring from the air — chasing a FLYING player,
	# enemies climb hill after hill and "pop up into the sky". Airborne -> accumulate
	# gravity so move_and_slide lands the body on the next collider BELOW (terrain OR a
	# structure roof, so it's never yanked off an elevated platform — the reason the
	# fall-catcher stayed up-only); on the floor -> flat run.
	var cm = world.get("chunk_manager") if is_instance_valid(world) else null
	if cm != null and not is_instance_valid(cm):
		cm = null
	# AERIAL: FLY at hover_alt above the terrain, chase horizontally, gently bob. No gravity / no fall-catcher
	# (a flyer must never be pulled to the ground). On attack a SWOOP dips it toward the player then rises,
	# so it's reachable mid-dive instead of parked untouchably overhead.
	if _aerial:
		var adt := get_physics_process_delta_time()
		var agy: float = cm._ground_y(global_position.x, global_position.z) if cm != null else 0.0
		# CRUISE altitude homes toward the player's height (bounded), so flyers CLIMB to chase a plane / a
		# high player instead of hugging the ground far below. Grounded player -> hovers at hover_alt overhead.
		var cruise := agy + hover_alt
		if is_instance_valid(player):
			cruise = clampf(player.global_position.y, agy + hover_alt, agy + AERIAL_MAX_CLIMB)
		var alt_y := cruise
		if _swoop > 0.0 and is_instance_valid(player):
			var dive := sin(_swoop * PI)   # 0 at the swoop's ends, 1 at its middle -> dive toward the player
			alt_y = lerpf(cruise, player.global_position.y - 0.3, dive)
		var tgt_y := alt_y + sin(_bob_t) * AERIAL_BOB
		velocity = Vector3(safe.x, 0.0, safe.z)
		move_and_slide()
		# KEEP-AWAY (except mid-swoop): hold a horizontal stand-off so flyers don't ring/surround the player
		# in the air — they trail at distance and only dart in on a swoop.
		if _swoop <= 0.0 and is_instance_valid(player):
			var off := Vector2(global_position.x - player.global_position.x, global_position.z - player.global_position.z)
			var keep := maxf(SWIM_KEEP, surround_radius) * _air_keep
			var d := off.length()
			if d > 0.001 and d < keep:
				var push := off / d * (keep - d)
				global_position.x += push.x
				global_position.z += push.y
		global_position.y = lerpf(global_position.y, tgt_y, minf(1.0, 6.0 * adt))
		return
	# WATER: float at the surface (swim) in deep water instead of walking the submerged seabed or sinking
	# out of view. Land animals float only past a wade; aquatic creatures ride any water.
	if cm != null and cm.water_cfg != null:
		var wgy: float = cm._ground_y(global_position.x, global_position.z)
		var st: Dictionary = GWater.float_state(cm.water_level, wgy, global_position.y, (0.0 if _aquatic else FLOAT_WADE), _submerge)
		if bool(st["float"]):
			if not _floating:
				_enter_float()
			# CAP in-water horizontal speed strictly below the player's SWIM_SPEED (RVO 'safe' otherwise
			# carries the full land speed up to 3.9+), so the player can always out-swim every creature.
			var sv := Vector2(safe.x, safe.z)
			if sv.length() > SWIM_MAX:
				sv = sv.normalized() * SWIM_MAX
			velocity = Vector3(sv.x, 0.0, sv.y)
			move_and_slide()
			# KEEP-AWAY: RVO ignores the player and (floating) we share its exact surface plane, so the
			# chase/attack steering would pile every swimmer ONTO the player — the "stuck to the character"
			# blob. Hold at least our encircle ring out from it so swimmers RING the player, never overlap.
			if is_instance_valid(player):
				var off := Vector2(global_position.x - player.global_position.x, global_position.z - player.global_position.z)
				var keep := maxf(SWIM_KEEP, surround_radius) * _air_keep
				var d := off.length()
				if d > 0.001 and d < keep:
					var push := off / d * (keep - d)
					global_position.x += push.x
					global_position.z += push.y
			global_position.y = float(st["y"])
			return
		elif _floating:
			_exit_float()
	var adt := get_physics_process_delta_time()
	var vy := 0.0 if (is_on_floor() or _ground_stuck) else velocity.y - GRAVITY * adt
	if _moving:
		# damp toward the avoidance 'safe' instead of snapping to it -> the frame-to-frame RVO direction flip
		# (worst in a dense pack) is filtered out while the body still converges on its slot.
		velocity = Vector3(lerpf(velocity.x, safe.x, minf(1.0, 14.0 * adt)), vy, lerpf(velocity.z, safe.z, minf(1.0, 14.0 * adt)))
	else:
		# parked at the slot: 'safe' still carries the neighbours' avoidance push, and enemies don't inter-collide
		# (mask=1), so writing it would shove the body off the slot -> re-steer back = vibrate. Decelerate to a
		# true stop and hold, so a parked creature (incl. the legless snake) sits rock-still.
		velocity = Vector3(move_toward(velocity.x, 0.0, speed * 6.0 * adt), vy, move_toward(velocity.z, 0.0, speed * 6.0 * adt))
		# PARK-LOCK: once actually stopped AND grounded, HOLD the transform byte-stable — skip
		# move_and_slide entirely so the per-tick collision/gravity re-solve on uneven terrain can't wobble the
		# base transform that the render-rate skinned anim amplifies into the whole-body buzz (root-caused by the
		# the body-freeze A/B). Position is already at the slot with Y pinned, so holding it is continuous ->
		# no snap when it later un-parks. Any residual/knockback velocity (>0.05) falls through to move_and_slide.
		if _parked and absf(velocity.x) < 0.05 and absf(velocity.z) < 0.05:
			velocity.y = 0.0
			return
	move_and_slide()
	# GROUND-STICK (ports the player's main.gd fix): over a cell whose trimesh collider hasn't streamed in yet,
	# is_on_floor() reads FALSE, so gravity accumulated velocity.y, the body sank, and the OLD up-only catcher
	# snapped Y back but left velocity.y large-negative and is_on_floor() still false -> it sank again next tick
	# -> a per-PHYSICS-TICK vertical sawtooth (interpolation renders it as a smooth constant buzz; FPS-independent;
	# untouched by any render-side lag cut = the exact jitter). Pin to the analytic heightmap AND zero velocity.y
	# AND latch grounded so gravity can't re-fire -> the root Y is constant tick-over-tick -> no buzz. The
	# y <= gy + 0.1 guard preserves "never yank a creature off an elevated structure" (a roof has y >> gy).
	_ground_stuck = false
	if cm != null:
		var gy: float = cm._ground_y(global_position.x, global_position.z)
		if velocity.y <= 0.5 and global_position.y <= gy + 0.1:
			global_position.y = gy
			velocity.y = 0.0
			_ground_stuck = true


func _enter_float() -> void:
	_floating = true
	# At the surface we ride the SAME plane as a swimming player, whose collision_mask includes L_ENEMY —
	# but we don't yield (our mask is world-only) and RVO ignores the player, so that solidity GLUES the
	# swimmer to us, fusing player+creatures into one blob. Drop mutual collision with the player WHILE
	# FLOATING so the swimmer passes freely through/around us; surround_radius still holds our encircle ring.
	if is_instance_valid(player) and player is PhysicsBody3D:
		add_collision_exception_with(player)
	if c_swim != "":
		_play(c_swim)
	else:
		GPose.swim(mesh_root)

func _exit_float() -> void:
	_floating = false
	if is_instance_valid(player) and player is PhysicsBody3D:
		remove_collision_exception_with(player)   # solid again on land (on-land encircle/no-pass-through unchanged)
	if c_swim == "":
		GPose.stand(mesh_root)
	_cur = ""


## THE one damage door (Wave-4 contract): melee (main._attack) AND projectiles
## (GProjectile's per-tick sphere-cast hit test) both land here — nothing else writes hp.
## The param stays FLOAT (not the draft int): rpg.weapon_damage() is float, and an int
## caller (a projectile passing the schema's damage) converts losslessly, so both fit.
func take_hit(d: float) -> void:
	if dead:
		return
	d = minf(d, hp_max * HIT_CAP_FRAC)   # never one-shot: cap a single blow so a kill always takes 2+ hits
	var frac_before := hp / maxf(1.0, hp_max)
	hp -= d
	_report_hp_crossing(frac_before, hp / maxf(1.0, hp_max))
	flash_t = 0.12
	AudioManager.play_sfx("hit")
	if hp <= 0.0:
		_die()
	else:
		hurt_t = 0.3
		_play(c_hurt, false)   # brief flinch (rig-lab/library "hurt"/"Hit_A" clip; "" -> silent no-op)


## HEALTH CROSSING -> the rule layer. Health was always tracked correctly here; nothing ever
## ANNOUNCED it, so a boss rule waiting on `enemy_hp_crossed` sat in the dispatch table forever and
## the playbook's own two-phase example could not work.
##
## The thresholds come FROM the rules (cached at setup), so this stays a report rather than a policy:
## the enemy does not decide what "half health" means, it just says when a line was crossed. Fires
## only on a DOWNWARD crossing — a heal should not re-trigger a phase change.
# DETECTION IS REPORTED, NOT ENFORCED.
#
# These creatures have always chased from any distance — `player` is assigned at spawn and the AI
# never asks how far away it is. Adding a real aggro radius would change how every existing game
# plays, which is not what a "make the event fire" pass is for. So this is purely observational:
# it raises `enemy_detected_player` when the gap closes past DETECT_RANGE and `enemy_lost_player`
# when it opens past DETECT_RANGE * DETECT_HYSTERESIS. Behaviour is identical; the game can now
# hear about it (a stinger, reinforcements, a boss line) instead of being unable to tell.
#
# The hysteresis band is the point: without it, a player pacing the threshold would machine-gun the
# pair of events every frame, and a rule chained to either would fire dozens of times a second.
const DETECT_RANGE := 18.0
const DETECT_HYSTERESIS := 1.6
var _detected := false


func _report_detection(dist: float) -> void:
	if _detected:
		if dist <= DETECT_RANGE * DETECT_HYSTERESIS:
			return
		_detected = false
	else:
		if dist > DETECT_RANGE:
			return
		_detected = true
	# Same back-reference the hp-crossing reporter uses. A get_node("Main") lookup would work today
	# and break the first time the scene root is renamed, with no error — just an event that stopped.
	if not is_instance_valid(world) or world.director == null or not world.director.has_method("fire"):
		return
	world.director.fire("enemy_detected_player" if _detected else "enemy_lost_player",
		{"id": String(get_meta("gogi_id", "")), "kind": String(kind)})


func _report_hp_crossing(before: float, after: float) -> void:
	if _hp_marks.is_empty() or not is_instance_valid(world):
		return
	for m0 in _hp_marks:
		var m := float(m0)
		if before > m and after <= m:
			if world.director != null and world.director.has_method("fire"):
				world.director.fire("enemy_hp_crossed", {"id": kind, "kind": kind, "at": m})


func _die() -> void:
	dead = true
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	if is_instance_valid(world) and world.has_method("on_enemy_killed"):
		world.on_enemy_killed(kind)   # -> XP + quest kill progress (authored enemy_type)
	_play(c_die, false)
	var t := create_tween()
	t.tween_interval(1.1)
	t.tween_callback(queue_free)


# ---------------- anim ----------------

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


func _resolve_clips() -> void:
	c_idle = _pick(["idle"])
	c_walk = _pick(["walk", "run", "move"])
	c_attack = _pick(["attack", "melee", "swing", "slash", "punch", "bite", "strike"])
	c_die = _pick(["death", "die", "dead"])
	c_hurt = _pick(["hurt", "hit", "flinch", "pain"])
	c_swim = _pick(["swim", "paddle", "tread", "float"])
	c_fly = _pick(["fly", "flap", "flying", "hover", "glide", "wing"])


func _pick(keys: Array) -> String:
	if anim == null:
		return ""
	for n in anim.get_animation_list():
		var l := n.to_lower()
		for k in keys:
			if k in l:
				return n
	return ""


func _play(clip: String, loop := true) -> void:
	if anim == null or clip == "" or _cur == clip:
		return
	_cur = clip
	if anim.has_animation(clip):
		var a := anim.get_animation(clip)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		anim.play(clip)


func _set_far_cull(n: Node, vis_end: float) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		gi.visibility_range_end = vis_end
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED   # hard cutoff -> no dither shimmer on a moving creature
	for c in n.get_children():
		_set_far_cull(c, vis_end)


func _face(dir: Vector3) -> void:
	if dir.length() < 0.05:
		return
	# DAMPED: the old per-frame look_at() hard-set yaw from an RVO-noisy position -> a few-degrees swing that a
	# long snake / colossal boss lever-arm-amplifies into visible vibration. atan2(dir.x, dir.z) is the SAME yaw
	# (+Z toward the player, matching the old look_at and wander.gd), but a deadzone + lerp filter the noise.
	var tgt := atan2(dir.x, dir.z)
	if absf(wrapf(tgt - rotation.y, -PI, PI)) < 0.05:
		return   # ~2.9deg deadzone: already facing -> don't re-snap to sub-degree RVO bearing noise
	rotation.y = lerp_angle(rotation.y, tgt, minf(1.0, 12.0 * get_physics_process_delta_time()))


# Hide the enemy mesh when the CAMERA is pressed against its BODY (fed by main._process): a body
# against the lens reads as a "popup". Distance is measured to the body CENTRE and the threshold
# scales with model height — measured to the feet origin, a 4m model legally walled the frame
# (gamefeel P1: the fade never fired because the camera rides ~1.5-2m above the ground). The
# SpringArm masks world-only, so it never pulls in on enemies (layer 4). (#6)
func set_camera_near(cam_dist: float) -> void:
	if mesh_root == null or not is_instance_valid(mesh_root):
		return
	# HYSTERESIS band: a body hovering right at the fade threshold (a cluster pressing the lens, or a
	# colossus whose 0.45*body_h reaches ~6m) used to flip visible/hidden every frame = flicker "glitch".
	# Hide only when strictly inside the threshold; reveal only after clearing it by 35%.
	var near_t := maxf(CAM_FADE_NEAR, 0.45 * body_h)
	if _cam_hidden:
		if cam_dist > near_t * 1.35:
			_cam_hidden = false
	elif cam_dist <= near_t:
		_cam_hidden = true
	mesh_root.visible = not _cam_hidden


# TRUE height of a model — bones unioned with the mesh envelope. This measurement was FIXED HERE
# first (rotated Meshy armatures, richest-skeleton, the giant_bat that read 1.3m instead of 4.7m),
# while main.gd carried an older bones-only copy of the same idea and quietly disagreed with it about
# every KayKit character. It now lives in ONE place so that cannot happen a third time.
func _char_height(node: Node3D) -> float:
	return GPose.char_height(node)



# Local-frame merged mesh bounds of a subtree (scale/ground decisions at setup, before the model
# animates). Accumulates transforms from IDENTITY so the result is relative to `root`.
func _model_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [[root, Transform3D.IDENTITY]]
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
