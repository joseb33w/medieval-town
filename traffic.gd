class_name TrafficCar extends Node3D
## AMBIENT TRAFFIC — a car that drives along a lane (a world-space line A→B) at constant speed and LOOPS, riding
## the terrain and facing its heading. Spawned along a cell's `roads` so a city's streets have moving cars (the
## "living city" cue). Pure transform movement (no physics body) so many can run cheaply, but COLLISION-AWARE: a
## short forward raycast at car-front height probes down the lane; a solid collider (building/prop) in the way makes
## the car SLOW, then HALT before it (never drive through), and a persistent blockage triggers a U-turn re-route
## down the lane. Colliderless worlds: the ray hits nothing -> the car advances exactly as the pre-collision build.
## Ticks in _physics_process because space-state queries are only valid there. The car MODEL is a child of this node;
## `setup()` wires the lane.

const RAY_H := 0.7          # forward probe height above the road (car bumper/hood) — catches building/prop colliders, clears kerbs
const PROBE_AHEAD := 4.5    # look this far down the lane for something solid
const HARD_STOP := 2.0      # a solid collider nearer than this -> full halt (don't drive into it)
const PROBE_EVERY := 0.25   # seconds between forward probes (cheap: ~4 rays/s per car)
const REROUTE_AFTER := 3.0  # halted this long (a permanent blockage across the lane) -> U-turn and drive the lane back

var a: Vector3 = Vector3.ZERO     # lane start (world)
var b: Vector3 = Vector3.ZERO     # lane end (world)
var speed := 6.0
var terrain: GTerrain = null
var _u := 0.0                     # progress 0..1 along the lane
var _len := 1.0
var _dir_sign := 1                # +1 drives A→B, -1 drives B→A (flipped by a re-route U-turn)
var _gate := 1.0                  # last speed multiplier from the probe: 1 clear, 0..1 slowing, 0 halted
var _probe := 0.0                 # countdown to the next forward probe
var _blocked_t := 0.0             # seconds spent halted against a blockage (drives the re-route)
var _exclude: Array[RID] = []     # this car's own colliders — never mistake yourself for an obstacle


func setup(start: Vector3, end: Vector3, spd: float, t: GTerrain, u0 := 0.0) -> void:
	a = start
	b = end
	speed = maxf(0.5, spd)
	terrain = t
	_u = clampf(u0, 0.0, 1.0)
	_len = maxf(0.1, a.distance_to(b))
	_dir_sign = 1
	_gate = 1.0
	_probe = 0.0
	_blocked_t = 0.0
	_collect_own_bodies(self)
	# face the lane direction up front so it doesn't spawn sideways
	var dir := (b - a).normalized()
	rotation.y = atan2(dir.x, dir.z)
	_apply()
	set_physics_process(true)   # space-state queries are only valid in physics


func _physics_process(delta: float) -> void:
	var here := position
	var fwd := _fwd_xz()
	_probe -= delta
	if _probe <= 0.0:
		_probe = PROBE_EVERY
		_gate = _speed_gate(here, fwd)   # refresh the slow/halt multiplier from a forward ray
	if _gate <= 0.01:
		_blocked_t += delta
		if _blocked_t >= REROUTE_AFTER:   # lane is permanently boxed -> turn around and drive it back
			_reroute()
		return                            # halted: hold position against the obstacle (no drive-through)
	_blocked_t = 0.0
	_u += _dir_sign * (_gate * speed * delta) / _len
	# PING-PONG at the physical lane ends — do NOT teleport-loop u:1->0. The old wrap made a car
	# reaching one end reappear at the other in a single frame; on an isolated or blocked lane (no
	# neighbour cell continuing the street to mask it) that reads as the car POPPING across the road.
	# Clamping to the end and flipping direction paces the car up and down its lane, so a multi-cell
	# street still shows two-way traffic (each cell already keeps its own cars) with no visible jump.
	if _u >= 1.0:
		_u = 1.0
		_dir_sign = -1
	elif _u <= 0.0:
		_u = 0.0
		_dir_sign = 1
	_apply()


# The horizontal (XZ) unit direction the car is currently travelling, signed by the re-route flag. Vector2(x, z).
func _fwd_xz() -> Vector2:
	var d := Vector2(b.x - a.x, b.z - a.z)
	if d.length() < 0.001:
		return Vector2(0.0, 1.0)
	return d.normalized() * float(_dir_sign)


# Forward-probe multiplier: cast a ray RAY_H above the road down the lane. EMPTY (colliderless world, or clear road)
# -> 1.0 (full speed, identical to the pre-collision build). A solid hit within HARD_STOP -> 0.0 (halt); farther hit
# -> a 0..1 slow ramp so the car eases down before an obstacle. Space-state access — only valid in _physics_process.
func _speed_gate(here: Vector3, fwd: Vector2) -> float:
	var w := get_world_3d()
	if w == null:
		return 1.0
	var hx := here.x + fwd.x * PROBE_AHEAD
	var hz := here.z + fwd.y * PROBE_AHEAD
	var from := Vector3(here.x, _ground(here.x, here.z) + RAY_H, here.z)
	var dest := Vector3(hx, _ground(hx, hz) + RAY_H, hz)
	var q := PhysicsRayQueryParameters3D.create(from, dest)   # default mask, bodies only
	q.exclude = _exclude
	var hit := w.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 1.0
	var hp: Vector3 = hit.position
	var d := from.distance_to(hp)
	if d <= HARD_STOP:
		return 0.0
	return clampf((d - HARD_STOP) / (PROBE_AHEAD - HARD_STOP), 0.0, 1.0)


# Persistent blockage across the lane -> reverse the travel direction (a U-turn) so the car re-routes back the way
# it came instead of idling against the wall forever, and re-face + re-probe on the new heading.
func _reroute() -> void:
	_dir_sign = -_dir_sign
	_blocked_t = 0.0
	_gate = 1.0
	_probe = 0.0
	var d := _fwd_xz()
	rotation.y = atan2(d.x, d.y)   # face the new travel heading (d = worldX, worldZ)


func _apply() -> void:
	var p := a.lerp(b, _u)
	var gy := terrain.height(p.x, p.z) if terrain != null else 0.0
	position = Vector3(p.x, gy + 0.12, p.z)   # ride just above the road surface


# The car model may carry its own collider (the solid-by-default pass) — collect every CollisionObject3D under this
# node so the car's forward ray skips its own body.
func _collect_own_bodies(n: Node) -> void:
	if n is CollisionObject3D:
		_exclude.append((n as CollisionObject3D).get_rid())
	for c in n.get_children():
		_collect_own_bodies(c)


func _ground(x: float, z: float) -> float:
	return terrain.height(x, z) if terrain != null else 0.0
