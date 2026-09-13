class_name WanderAgent extends Node3D
## CROWD LOCOMOTION — makes a populated character (a Meshy/library person) WALK instead of standing still: it
## strolls to a random target within a radius of its home, pauses, picks a new one — following the terrain, facing
## its heading, and playing its WALK clip while moving / IDLE while paused (so a `populate` cast reads as a LIVING
## crowd, not statues). Cheap: pure transform movement (no physics body), but COLLISION-AWARE: two short raycasts (a
## torso ray + a shin ray, so LOW props the torso ray flies over are still caught) validate each stroll target and
## probe ahead while walking, so agents route around solid objects instead of clipping through them (colliderless
## worlds: rays hit nothing -> behaviour identical to before). Movement ticks
## in _physics_process because space-state queries are only valid there. The model is a child of this node;
## `setup()` wires it. Used by chunk_manager when a `populate` entry sets behaviour:"wander".

const RAY_H := 1.0          # torso obstacle ray flies ~1m above the ground (over kerbs, under archways)
const LOW_RAY_H := 0.35     # shin ray — catches low props (~0.5m planters/crates) the torso ray flies clean over, yet still clears kerbs (~0.1-0.3m)
const PROBE_AHEAD := 1.5    # while walking, look this far ahead for something solid
const PROBE_EVERY := 0.6    # seconds between forward probes (cheap: <=2 rays per probe, torso ray short-circuits ~3-4 rays/s per moving agent)
const PICK_TRIES := 6       # target resamples before giving up and idling in place

var terrain: GTerrain = null
var home: Vector2 = Vector2.ZERO
var radius := 6.0
var speed := 1.6
var _target: Vector2
var _pause := 0.0
var _probe := 0.0
var _fresh := true          # initial target not picked yet — deferred to the first physics tick (rays need physics)
var _anim: AnimationPlayer = null
var _walk := ""
var _swim := ""                 # swim/tread clip (empty -> GPose.swim fallback)
var _water_level := -1e9        # world water surface (-1e9 = no water block); passed from the spawner
var _aquatic := false           # true -> rides ANY water (fish/croc); false -> floats only when forced in
var _in_water := false          # last-frame float state (for the water->land GPose.stand transition)
var _idle := ""
var _walk_phase := 0.0           # procedural-walk gait phase for a CLIPLESS crowd member (no clips -> would slide)
var _rng := RandomNumberGenerator.new()
var _exclude: Array[RID] = []   # this agent's own colliders — never mistake yourself for an obstacle


func setup(t: GTerrain, home_xz: Vector2, r: float, spd: float, seed_i: int, water_level := -1e9, aquatic := false) -> void:
	terrain = t
	home = home_xz
	radius = maxf(1.0, r)
	speed = maxf(0.2, spd)
	_water_level = water_level
	_aquatic = aquatic
	_rng.seed = seed_i
	_anim = _find_anim(self)
	if _anim != null:
		_walk = _match_clip(["walk", "run", "move"])
		_idle = _match_clip(["idle", "stand"])
		_swim = _match_clip(["swim", "paddle", "tread", "float"])
	_collect_own_bodies(self)
	_target = home_xz
	_fresh = true
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if _fresh:   # first tick after setup: pick the initial target here, where space-state queries are legal
		_fresh = false
		_pick_target()
	if _pause > 0.0:
		_pause -= delta
		_play(_idle)
		if _anim == null:
			GPose.walk_stop(self)   # clipless: return legs to rest while paused (idle)
		return
	var here := Vector2(position.x, position.z)
	var to := _target - here
	var dist := to.length()
	if dist < 0.4:
		_pause = _rng.randf_range(1.5, 4.5)   # arrived -> idle a beat, then a new target
		_pick_target()
		return
	var dir := to / dist
	_probe -= delta
	if _probe <= 0.0:
		_probe = PROBE_EVERY
		if _blocked(here, here + dir * PROBE_AHEAD):   # something solid moved into the path -> reroute now
			_pick_target()
			return
	var np := here + dir * speed * delta
	var g := _ground(np.x, np.y)
	# WATER: float at the surface with a swim/tread pose in deep water instead of walking the seabed or
	# sinking out of view; a land animal floats only when forced in, an aquatic one rides any water.
	var st := GWater.float_state(_water_level, g, position.y, (0.0 if _aquatic else 0.6), 0.4)
	if bool(st["float"]):
		position = Vector3(np.x, float(st["y"]), np.y)
		if _anim == null:
			GPose.walk_stop(self)   # entering water: drop the walk pose before the swim lean
		if _swim != "":
			_play(_swim)
		elif not _in_water:
			GPose.swim(self)
	else:
		if _in_water and _swim == "":
			GPose.stand(self)
		position = Vector3(np.x, g, np.y)
		_play(_walk)
		if _anim == null:
			_walk_phase += delta * (3.0 + speed * 2.0)   # clipless crowd member: procedural stride so it doesn't glide
			GPose.walk(self, _walk_phase)
	_in_water = bool(st["float"])
	_face_heading(dir, delta)   # face the heading, DAMPED (deadzone + lerp — see _face_heading)


# DAMPED heading — mirrors enemy.gd `_face` (deadzone + lerp_angle). For a FIXED stroll target this is a
# near-no-op (the heading barely changes tick-to-tick), just a smoother pivot on direction changes. The reason
# it's here at all: if a game ever RETARGETS a WanderAgent to a MOVING target (an NPC that follows/flees the
# player), a moving target makes `dir` chatter every tick — the old hard `rotation.y = atan2(...)` would then
# kick the yaw a few degrees each frame and a skinned mesh lever-arm-amplifies that into a visible buzz (the
# exact creature-jitter enemy.gd cured with direct-chase + this same filter). `dir2` is a normalized XZ vector;
# `dir2.y` is the z-component (model -Z forward — SAME yaw the old atan2(dir.x, dir.y) produced, so facing is
# unchanged, only filtered).
func _face_heading(dir2: Vector2, delta: float) -> void:
	if dir2.length() < 0.05:
		return
	var tgt := atan2(dir2.x, dir2.y)
	if absf(wrapf(tgt - rotation.y, -PI, PI)) < 0.05:
		return   # ~2.9deg deadzone: already facing -> don't re-snap to sub-degree bearing noise
	rotation.y = lerp_angle(rotation.y, tgt, minf(1.0, 12.0 * delta))


# Pick a stroll target the agent can actually reach: resample until the line here->candidate is clear of solid
# colliders (up to PICK_TRIES rays); every direction blocked -> idle in place and retry after the pause. Raycasts,
# so physics-tick only — every caller is on a _physics_process path.
func _pick_target() -> void:
	var here := Vector2(position.x, position.z)
	for _try in PICK_TRIES:
		var ang := _rng.randf() * TAU
		var rr := sqrt(_rng.randf()) * radius   # uniform over the disc
		var cand := home + Vector2(cos(ang) * rr, sin(ang) * rr)
		if not _blocked(here, cand):
			_target = cand
			return
	_target = here
	_pause = _rng.randf_range(1.5, 4.5)   # boxed in -> stand a beat, then try again


# TRUE when a solid collider sits between XZ points `a` and `b`. Sampled at TWO heights above the terrain: the torso
# ray (RAY_H) clears kerbs/steps and passes under archways; the shin ray (LOW_RAY_H) catches low props the torso ray
# would fly clean over. Blocked if EITHER hits (the torso ray short-circuits, so a clear path costs 2 rays, a wall 1).
# Space-state access — only valid during _physics_process. Colliderless worlds: intersect_ray returns an EMPTY
# Dictionary (never an error), so both rays are FALSE and behaviour matches the pre-collision build.
func _blocked(a: Vector2, b: Vector2) -> bool:
	var w := get_world_3d()
	if w == null:
		return false
	var ss := w.direct_space_state
	var ga := _ground(a.x, a.y)
	var gb := _ground(b.x, b.y)
	return _ray_solid(ss, a, ga, b, gb, RAY_H) or _ray_solid(ss, a, ga, b, gb, LOW_RAY_H)


# One height sample of _blocked: is a solid body between `a` and `b` at height `h` above each end's terrain?
func _ray_solid(ss: PhysicsDirectSpaceState3D, a: Vector2, ga: float, b: Vector2, gb: float, h: float) -> bool:
	var from := Vector3(a.x, ga + h, a.y)
	var dest := Vector3(b.x, gb + h, b.y)
	var q := PhysicsRayQueryParameters3D.create(from, dest)   # default mask, bodies only
	q.exclude = _exclude
	return not ss.intersect_ray(q).is_empty()


# The wrapped model may carry its own collider (populate `collider` option / the solid-by-default pass) — collect
# every CollisionObject3D under this node so the agent's rays skip its own body.
func _collect_own_bodies(n: Node) -> void:
	if n is CollisionObject3D:
		_exclude.append((n as CollisionObject3D).get_rid())
	for c in n.get_children():
		_collect_own_bodies(c)


func _ground(x: float, z: float) -> float:
	return terrain.height(x, z) if terrain != null else 0.0


func _play(clip: String) -> void:
	if _anim == null or clip == "":
		return
	if _anim.current_animation != clip:
		var a := _anim.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		_anim.play(clip)


func _match_clip(keys: Array) -> String:
	if _anim == null:
		return ""
	var clips := _anim.get_animation_list()
	for k in keys:
		for c in clips:
			if String(k) in String(c).to_lower():
				return String(c)
	return String(clips[0]) if clips.size() > 0 else ""


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null
