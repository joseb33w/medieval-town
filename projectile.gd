class_name GProjectile extends Node3D
## POOLED KINEMATIC PROJECTILES (Wave 4) — arrows/bolts for ranged + thrown weapons. NO physics
## bodies: pure kinematic advance + one intersect_ray per tick (mask 1 = world) + a manual
## segment-vs-chest proximity test against the live enemy list — cheap and mobile-safe.
##
##   GProjectile.fire(world_root, from, dir, def, enemies_provider=Callable(), exclude=[])
##       -> GProjectile|null   spawn from the pool, velocity = dir.normalized() * speed
##   GProjectile.fire_at(world_root, from, to, def, enemies_provider=Callable(), exclude=[])
##       -> GProjectile|null   aim at a POINT; when the def arcs (thrown) the launch velocity is
##                             ballistically compensated (+0.5*g*t up) so the drop lands ON `to`
##                             — use this with the auto-aim target for reliable hits
##   GProjectile.pick_target(from, facing, enemies, max_range, cone_deg=30.0) -> Node3D|null
##       mobile AUTO-AIM: the nearest live enemy inside a 30° half-angle cone of `facing`
##       (horizontal, like the melee arc) AND within range; null -> caller fires straight ahead
##   GProjectile.aim_point(enemy) -> Vector3          the enemy's chest (origin +1.0 m)
##   GProjectile.flash(at, parent)                    muzzle flash: emissive quad + OmniLight
##                                                    pulse, 0.08 s (fire()/fire_at() call it
##                                                    automatically at `from`)
##
## `def` = the merged weapon def (GEquip contract). Stats read with the pinned schema defaults:
## damage 1, speed 22 (from def.projectile.speed, then def.speed), arc true only for "thrown".
## `enemies_provider` = a Callable returning the LIVE enemy Array each tick (streamer.enemies) —
## projectiles fly for seconds, a fire-time snapshot would go stale. `exclude` = nodes (or RIDs)
## the world ray must ignore — pass the mount/vehicle when a RIDER fires (mounts sit on world
## layer 1, the ray would hit them at the muzzle).
##
## POOL: max 12 live, statically pooled and reused (oldest is recycled when full); zero per-frame
## allocations (the ray-query params, meshes, puffs and flash are all reused). Pool nodes parent
## to `world_root` — pass a PERSISTENT root (main), never a cell/area root, or the pool dies with
## the area (guards recreate it, but that wastes the pool). Impact puffs (one-shot CPUParticles3D)
## and the muzzle flash are pooled too (never freed — strictly cheaper than free-per-impact).
##
## HITS: on an enemy hit (segment within 0.9 m of chest = origin +1.0 m) the projectile calls the
## SAME public damage entry melee uses — enemy.take_hit(damage) — then puffs + deactivates. On a
## world hit (layer 1) it puffs at the hit point. 3 s lifetime cap. Enemies whose `dead` property
## is true are skipped; everything is duck-typed (no dependency on enemy.gd, works in both
## templates). Deactivated projectiles stop processing entirely.

const MAX_LIVE := 12
const LIFETIME := 3.0
const HIT_RADIUS := 0.9
const CHEST := Vector3(0.0, 1.0, 0.0)
const GRAVITY := 9.8
const FLASH_TIME := 0.08

# schema defaults (duplicated tiny readers keep this module self-contained; GEquip.stat is the
# public one for main)
const DEF_DAMAGE := 1.0
const DEF_SPEED := 22.0

static var _pool: Array = []                 # GProjectile nodes, live + idle (max MAX_LIVE)
static var _flash_node: Node3D = null        # pooled muzzle flash (quad + light + timer)
static var _flash_timer: Timer = null
static var _puffs: Array = []                # ring of pooled impact puffs
static var _puff_i := 0
static var _mat_bolt: StandardMaterial3D = null
static var _mat_arrow: StandardMaterial3D = null

var _active := false
var _vel := Vector3.ZERO
var _arc := false
var _dmg := 1.0
var _life := 0.0
var _born := 0
var _enemies := Callable()
var _ray: PhysicsRayQueryParameters3D
var _bolt: MeshInstance3D
var _arrow: MeshInstance3D


# ─────────────────────────────── public API ───────────────────────────────

## Fire along a DIRECTION (auto-aim missed / straight ahead). Velocity = dir.normalized()*speed;
## an arcing def then drops under gravity (no compensation — use fire_at for a known target).
static func fire(world_root: Node3D, from: Vector3, dir: Vector3, def: Dictionary, enemies_provider: Callable = Callable(), exclude: Array = []) -> GProjectile:
	if world_root == null or not is_instance_valid(world_root) or not world_root.is_inside_tree():
		return null
	var v := dir
	if v.length() < 0.001:
		v = Vector3.BACK                      # stack convention: characters face +Z
	v = v.normalized() * _speed_of(def)
	return _spawn(world_root, from, v, def, enemies_provider, exclude)


## Fire AT a point (the auto-aimed chest). Straight shot for flat defs; arcing defs get the exact
## ballistic compensation (v.y += 0.5*g*t for t = dist/speed), so the drop cancels at `to`.
static func fire_at(world_root: Node3D, from: Vector3, to: Vector3, def: Dictionary, enemies_provider: Callable = Callable(), exclude: Array = []) -> GProjectile:
	if world_root == null or not is_instance_valid(world_root) or not world_root.is_inside_tree():
		return null
	var speed := _speed_of(def)
	var delta := to - from
	var dist := delta.length()
	if dist < 0.05 or speed < 0.05:
		return fire(world_root, from, delta, def, enemies_provider, exclude)
	var t := dist / speed
	var v := delta / t
	if _arc_of(def):
		v.y += 0.5 * GRAVITY * t
	return _spawn(world_root, from, v, def, enemies_provider, exclude)


## Mobile AUTO-AIM: nearest live enemy within `cone_deg` HALF-ANGLE of `facing` (flattened
## horizontal, matching the melee arc test) and within `max_range` (horizontal). Null = none.
static func pick_target(from: Vector3, facing: Vector3, enemies: Array, max_range: float, cone_deg: float = 30.0) -> Node3D:
	var f := facing
	f.y = 0.0
	if f.length() < 0.001:
		return null
	f = f.normalized()
	var cos_limit := cos(deg_to_rad(cone_deg))
	var best: Node3D = null
	var best_d := INF
	for e in enemies:
		if e == null or not is_instance_valid(e) or not (e is Node3D):
			continue
		if e.get("dead"):
			continue
		var to: Vector3 = (e as Node3D).global_position - from
		to.y = 0.0
		var d := to.length()
		if d < 0.01 or d > max_range:
			continue
		if f.dot(to / d) < cos_limit:
			continue
		if d < best_d:
			best_d = d
			best = e as Node3D
	return best


## Where auto-aimed shots point: the enemy's chest (+1.0 m above its origin).
static func aim_point(enemy: Node3D) -> Vector3:
	return enemy.global_position + CHEST


## Muzzle flash at `at`: a brief emissive billboard quad + an OmniLight pulse (0.08 s), pooled
## (one node, restarted per shot). fire()/fire_at() call this automatically at the fire origin.
## Build every lazily-created combat node ONCE, at world start, instead of mid-fight.
##
## The pool projectile, the muzzle flash and the impact puffs were each created ON FIRST USE — inside
## the frame that fired, or the frame that connected. On the web build that means mesh creation,
## material creation and first-draw pipeline compilation land on the exact frame a player first shoots
## somebody, which is the worst possible moment and reads as the game stuttering the instant combat
## starts.
##
## The puffs are the worst of the three and explain the shape of the complaint: the ring grows to
## FOUR, one per impact, so the hitch repeats on the first four hits and then never again — which
## feels like the game "warming up" rather than like a bug.
##
## Everything is placed at `at`, drawn for the frames it takes to become real, then hidden. Doing it
## at spawn costs a blip nobody is looking at, instead of a stutter at the moment they are.
static func prewarm(world_root: Node3D, at: Vector3) -> void:
	if world_root == null or not is_instance_valid(world_root) or not world_root.is_inside_tree():
		return
	flash(at, world_root)
	var p := _acquire(world_root)
	if p != null:
		p.global_position = at
		p.visible = true
		# The puff ring is static and shared, so filling it from one projectile warms it for all.
		for i in range(4):
			p._puff(at)
		p._deactivate()
	print("GOGI_COMBAT_WARM pool=", _pool.size(), " puffs=", _puffs.size(),
		" flash=", _flash_node != null)


static func flash(at: Vector3, parent: Node3D) -> void:
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	if _flash_node == null or not is_instance_valid(_flash_node):
		_flash_node = _make_flash()
		_flash_timer = _flash_node.get_node("FlashTimer") as Timer
	var par := _flash_node.get_parent()
	if par == null:
		parent.add_child(_flash_node)
	elif par != parent:
		par.remove_child(_flash_node)
		parent.add_child(_flash_node)
	_flash_node.global_position = at
	_flash_node.visible = true
	_flash_timer.start()


# ─────────────────────────────── flight ───────────────────────────────

func _init() -> void:
	name = "GProjectile"
	_ray = PhysicsRayQueryParameters3D.new()   # reused every tick — no per-frame allocation
	_ray.collision_mask = 1                    # world layer only; enemies via the proximity test
	if _mat_bolt == null:
		_mat_bolt = StandardMaterial3D.new()
		_mat_bolt.albedo_color = Color(1.0, 0.85, 0.4)
		_mat_bolt.emission_enabled = true
		_mat_bolt.emission = Color(1.0, 0.8, 0.35)
		_mat_bolt.emission_energy_multiplier = 2.5
		_mat_arrow = StandardMaterial3D.new()
		_mat_arrow.albedo_color = Color(0.5, 0.35, 0.2)
		_mat_arrow.emission_enabled = true
		_mat_arrow.emission = Color(0.9, 0.7, 0.4)
		_mat_arrow.emission_energy_multiplier = 0.6
	_bolt = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.07
	sph.height = 0.14
	sph.radial_segments = 8
	sph.rings = 4
	_bolt.mesh = sph
	_bolt.material_override = _mat_bolt
	add_child(_bolt)
	_arrow = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.03, 0.03, 0.42)
	_arrow.mesh = bm
	_arrow.material_override = _mat_arrow
	add_child(_arrow)
	visible = false
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	_life -= delta
	if _life <= 0.0:
		_deactivate()
		return
	if _arc:
		_vel.y -= GRAVITY * delta
	var from := global_position
	var to := from + _vel * delta
	# world hit first (ray vs layer 1) so the enemy test only runs up to the wall, not through it
	var hit_pos := to
	var hit_world := false
	if is_inside_tree():
		_ray.from = from
		_ray.to = to
		var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
		if not hit.is_empty():
			hit_pos = hit["position"]
			hit_world = true
	if _enemies.is_valid():
		var list = _enemies.call()
		if list is Array:
			for e in list:
				if e == null or not is_instance_valid(e) or not (e is Node3D):
					continue
				if e.get("dead"):
					continue
				var chest: Vector3 = (e as Node3D).global_position + CHEST
				if _seg_dist_sq(from, hit_pos, chest) <= HIT_RADIUS * HIT_RADIUS:
					if e.has_method("take_hit"):
						e.call("take_hit", _dmg)   # the SAME public damage entry melee uses
					_puff(chest)
					_deactivate()
					return
	if hit_world:
		_puff(hit_pos)
		_deactivate()
		return
	global_position = to
	_orient()


func _launch(from: Vector3, vel: Vector3, def: Dictionary, provider: Callable, exclude: Array) -> void:
	global_position = from
	_vel = vel
	_arc = _arc_of(def)
	_dmg = _damage_of(def)
	_life = LIFETIME
	_born = Time.get_ticks_msec()
	_enemies = provider
	var rids: Array[RID] = []
	for x in exclude:
		if x is CollisionObject3D and is_instance_valid(x):
			rids.append((x as CollisionObject3D).get_rid())
		elif x is RID:
			rids.append(x)
	_ray.exclude = rids
	var ranged := String(def.get("kind", "")) == "ranged"
	_arrow.visible = ranged                    # elongated box = arrow-ish
	_bolt.visible = not ranged                 # emissive sphere = bolt / thrown
	visible = true
	_active = true
	set_physics_process(true)
	_orient()


func _deactivate() -> void:
	_active = false
	visible = false
	_enemies = Callable()                      # drop the streamer ref so it can free cleanly
	set_physics_process(false)


func _orient() -> void:
	if _vel.length_squared() < 0.001:
		return
	var d := _vel.normalized()
	if absf(d.dot(Vector3.UP)) < 0.98 and is_inside_tree():
		look_at(global_position + _vel)


# ─────────────────────────────── pool / spawn ───────────────────────────────

static func _spawn(world_root: Node3D, from: Vector3, vel: Vector3, def: Dictionary, provider: Callable, exclude: Array) -> GProjectile:
	var proj := _acquire(world_root)
	proj._launch(from, vel, def, provider, exclude)
	flash(from, world_root)
	return proj


# Reuse an idle pool node; grow to MAX_LIVE; else recycle the OLDEST live one. Freed entries
# (scene reload took the parent with them) are purged; nodes reparent to the given root.
static func _acquire(world_root: Node3D) -> GProjectile:
	for i in range(_pool.size() - 1, -1, -1):
		if not is_instance_valid(_pool[i]):
			_pool.remove_at(i)
	var proj: GProjectile = null
	for p in _pool:
		if not (p as GProjectile)._active:
			proj = p as GProjectile
			break
	if proj == null and _pool.size() < MAX_LIVE:
		proj = GProjectile.new()
		_pool.append(proj)
	if proj == null:
		var oldest := -1
		for p in _pool:
			var gp := p as GProjectile
			if oldest == -1 or gp._born < oldest:
				oldest = gp._born
				proj = gp
	var par := proj.get_parent()
	if par == null:
		world_root.add_child(proj)
	elif par != world_root:
		par.remove_child(proj)
		world_root.add_child(proj)
	return proj


# ─────────────────────────────── impact puff + flash ───────────────────────────────

# One-shot dust puff at an impact, from a pooled ring (never freed — reused round-robin).
func _puff(at: Vector3) -> void:
	var parent := get_parent()
	if parent == null or not parent.is_inside_tree():
		return
	for i in range(_puffs.size() - 1, -1, -1):
		if not is_instance_valid(_puffs[i]):
			_puffs.remove_at(i)
	if _puffs.size() < 4:
		_puffs.append(_make_puff())
	_puff_i = (_puff_i + 1) % _puffs.size()
	var p := _puffs[_puff_i] as CPUParticles3D
	var par := p.get_parent()
	if par == null:
		parent.add_child(p)
	elif par != parent:
		par.remove_child(p)
		parent.add_child(p)
	p.global_position = at
	p.restart()


static func _make_puff() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = "GProjectilePuff"
	p.amount = 12
	p.lifetime = 0.35
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 80.0
	p.gravity = Vector3(0.0, 1.2, 0.0)
	p.initial_velocity_min = 1.2
	p.initial_velocity_max = 2.4
	p.damping_min = 2.0
	p.damping_max = 3.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var q := QuadMesh.new()
	q.size = Vector2(0.14, 0.14)
	p.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.78, 0.72, 0.62, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	p.material_override = m
	return p


static func _make_flash() -> Node3D:
	var root := Node3D.new()
	root.name = "GProjectileFlash"
	var quad := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.34, 0.34)
	quad.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.9, 0.6, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.5)
	m.emission_energy_multiplier = 3.0
	quad.material_override = m
	root.add_child(quad)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.85, 0.55)
	light.light_energy = 3.0
	light.omni_range = 4.5
	light.shadow_enabled = false
	light.light_specular = 0.3
	root.add_child(light)
	var timer := Timer.new()
	timer.name = "FlashTimer"
	timer.wait_time = FLASH_TIME
	timer.one_shot = true
	timer.timeout.connect(func() -> void:
		if _flash_node != null and is_instance_valid(_flash_node):
			_flash_node.visible = false)
	root.add_child(timer)
	root.visible = false
	return root


# ─────────────────────────────── helpers ───────────────────────────────

# Squared distance from point `p` to segment [a, b] — the sphere-cast-vs-chest test, no allocs.
static func _seg_dist_sq(a: Vector3, b: Vector3, p: Vector3) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	var t := 0.0
	if denom > 1e-8:
		t = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return (a + ab * t).distance_squared_to(p)


static func _damage_of(def: Dictionary) -> float:
	return float(def.get("damage", DEF_DAMAGE))


static func _speed_of(def: Dictionary) -> float:
	var p = def.get("projectile", null)
	if p is Dictionary and (p as Dictionary).has("speed"):
		return float(p["speed"])
	return float(def.get("speed", DEF_SPEED))


static func _arc_of(def: Dictionary) -> bool:
	var p = def.get("projectile", null)
	if p is Dictionary and (p as Dictionary).has("arc"):
		return bool(p["arc"])
	return String(def.get("kind", "")) == "thrown"
