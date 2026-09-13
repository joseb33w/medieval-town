class_name Vehicle extends CharacterBody3D
## BOARDABLE VEHICLES & MOUNTS (v3 — Wave 3 "motion profiles + mounts") — a world-level "vehicles"
## entry the player can walk up to, BOARD, and DRIVE/RIDE:
##   "vehicles": [{"pos": [x, z], "name": "...", "profile": "car"|"tank"|"boat"|"plane"|"horse"|
##                 "bull"|"dragon" (default "car"), "color": [r, g, b], "model": "<optional>"}]
## main.gd spawns these ONCE at boot onto the PERSISTENT layer (never cell-parented — chunk
## eviction and zone transitions can't touch them). The body is a CharacterBody3D with a box
## collider derived from the composed/scale-normalised AABB, so buildings/walls stop it
## (move_and_slide) while y terrain-follows the rendered surface via GTerrain.height. While
## driving, main.gd feeds its EXISTING input vector here and the player is parked ON the
## boardable every physics tick — so chunk streaming and reach_area quest notifications (both
## read player.global_position) follow the DRIVEN position with no extra wiring.
##
## PROFILES (Wave 3):
##   car    — Wave-2 articulated parametric car, byte-equivalent behavior (door choreography).
##   tank   — turn-in-place tracks; parametric hull/glacis/turret body; door-less Wave-1 style
##            swap-in boarding (hatch choreography is OUT OF SCOPE v1 — the driver is hidden,
##            exactly the Wave-1 fused-GLB idiom).
##   boat   — rides the WATER LEVEL (set_water) with a small bob, not the terrain; a world with
##            NO water degrades to car-on-terrain. Step-in boarding (no door) + GPose.sit.
##   plane  — arcade flight: car-like taxi, lift-off above takeoff speed, pitch/bank in the air,
##            SPEED_MAX 22 / ALT_MAX 32 envelope, lands when terrain-relative height < 0.5.
##            Step-in boarding + GPose.sit. Cosmetic spinning prop disc.
##   horse / bull / dragon — MOUNTS: no parametric body; "model" omitted resolves a LIBRARY
##            DEFAULT (main.gd asks Vehicle.default_model_path). Rider is VISIBLE, parked on a
##            "MountMarker" seated ON the creature's DORSAL SURFACE (mesh-vertex back-line sample
##            at a per-profile seat z — never the AABB top, which is the raised head/crest) and
##            posed astride via GPose.ride. An engine-built parametric saddle marks the seat
##            (spec {"saddle": false} disables; generators ship mounts BARE-BACKED). Gait
##            sync plays the model's EMBEDDED clips (walk/gallop/idle; dragon flap/glide) —
##            clipless creatures still ride, silently un-animated. Dragon shares the plane's
##            flight envelope and walks when landed.
##
## BODY MODES (decided by the SPEC, not by fetch success):
##   - VEHICLE profiles, "model" OMITTED  -> the profile's PARAMETRIC body (GShapes + GSurf).
##   - VEHICLE profiles, "model" PRESENT  -> the Wave-1 fused-GLB swap-in boarding, with a
##     VISIBLE-DRIVER upgrade: setup synthesizes a "SeatMarker" at the CABIN CENTRE at seat
##     height — enter() then seats the driver visibly (GPose.sit). Closed cabs ("cab":"closed")
##     and flyer profiles keep the Wave-1 instant hide. (The old cabin-column PROBE was retired;
##     solidity stopped being the test when it went — see _probe_cabin_seat.) A spec "seat": [x, y, z]
##     (self-local metres) or an authored SaddleMarker/SeatMarker node in the GLB wins outright.
##   - MOUNT profiles -> ALWAYS the model path (library default or spec model) and ALWAYS the
##     mount boarding (visible rider at the MountMarker) — a mount has no cabin to hide in, so
##     the fused-GLB "hide the driver" fallback would strand an invisible rider on its back.
##
## HOT-RELOAD SAFETY: main.gd calls exit() before freeing. exit() mid-ENTER is guarded (no-op),
## exit() mid-FLIGHT is a guarded no-op too (no mid-air dismounts — the chunk movement contract
## has no gravity, a dropped player would float), and _exit_tree() force-restores the driver
## (pose/visibility/collision/position AT TERRAIN HEIGHT) if the node is freed mid-choreography,
## mid-drive or mid-flight, so a chat edit can never strand a hidden, posed or airborne player.

# Per-profile tuning. max_speed/accel/brake/turn_rate are the GROUND (or water) gait; flight
# uses the shared SPEED_MAX/ALT_MAX envelope below. Flags: steer_fixed (turn-in-place, steering
# NOT scaled by speed), steer_floor (min low-speed steering authority, 0..1 — the hull/nose turns
# while spooling up), water (rides the water level), fly (has the flight model, "takeoff" =
# lift-off speed), mount (creature: model path + MountMarker + GPose.ride + gait sync).
const PROFILES := {
	"car": {
		"length": 4.0,       # longest horizontal dim after scale-normalisation (same idiom as traffic)
		"max_speed": 12.0,   # m/s
		"accel": 14.0,       # m/s^2 toward the throttle target
		"brake": 22.0,       # m/s^2 shedding speed (throttle released / reversed)
		"turn_rate": 2.0,    # rad/s at full speed — scaled by speed so a parked car can't pirouette
		"exit_side": 2.0,    # metres to the vehicle's side where the driver steps out
		"board": "door",     # parametric boarding style (model-present always boards instant)
	},
	"tank": {
		"length": 5.2, "max_speed": 7.0, "accel": 6.0, "brake": 14.0,
		"turn_rate": 1.6, "exit_side": 2.4, "board": "instant",
		"steer_fixed": true,   # TURN-IN-PLACE: steering works at zero speed, never speed-scaled
	},
	"boat": {
		"length": 5.5, "max_speed": 9.0, "accel": 7.0, "brake": 6.0,   # brisker spool-up, drifty stop
		"turn_rate": 1.6, "exit_side": 2.2, "board": "step",
		"water": true,       # y = water level (+bob) when the world has water; else terrain (car-like)
		"steer_floor": 0.45, # low-speed helm authority (2.3): the hull answers the stick while spooling up
	},
	"plane": {
		"length": 7.0, "max_speed": 14.0, "accel": 8.0, "brake": 16.0,   # ground TAXI numbers
		"turn_rate": 1.2, "exit_side": 2.8, "board": "step",             # slower taxi turn than a car
		"fly": true, "takeoff": 9.0,   # throttle-held above 9 m/s lifts off (pinned envelope)
		"steer_floor": 0.35, # taxi turns the nose while below rotation speed (2.3)
	},
	"horse": {
		"length": 2.2, "max_speed": 10.0, "accel": 8.0, "brake": 12.0,   # gallop feel
		"turn_rate": 2.4, "exit_side": 1.6, "board": "mount", "mount": true,
	},
	"bull": {
		"length": 2.2, "max_speed": 8.0, "accel": 5.0, "brake": 10.0,    # heavier
		"turn_rate": 1.4, "exit_side": 1.6, "board": "mount", "mount": true,   # slight turn resistance
	},
	"dragon": {
		"length": 4.5, "max_speed": 7.0, "accel": 6.0, "brake": 10.0,    # GROUND walk when landed
		"turn_rate": 1.8, "exit_side": 3.0, "board": "mount", "mount": true,
		"fly": true, "takeoff": 6.0,   # a dragon leaps from a run — its walk gait tops out at 7,
	},                                 # so the plane's 9.0 runway threshold would be unreachable
}
# LIBRARY DEFAULTS for mount models ("model" omitted). main.gd resolves these to absolute URLs
# via its _norm (they are bare library paths like the traffic set); all three exist, rig:true.
const MOUNT_MODELS := {
	"horse": "animals/farm_Horse.glb",
	"bull": "animals/farm_Cow.glb",
	"dragon": "animals/monster_Dragon.glb",
}
const PROMPT_RANGE := 2.8    # metres to the CLOSEST HULL POINT — show the floating DRIVE/RIDE label
const PROMPT_HIDE := 2.85    # ... hide past here (a 0.05 m hysteresis band so an edge-hover can't flicker)
const GROUND_LIFT := 0.1     # ride just above the surface (same cue as TrafficCar's +0.12)
const SNAP_RATE := 10.0      # y-lerp rate onto the terrain (fast enough to hug, soft enough not to pop)

# --- shared FLIGHT ENVELOPE (plane + dragon) — pinned Wave-3 numbers ---
const SPEED_MAX := 22.0            # m/s airborne top speed (<1.2 cells/s at cell_size 20 — streaming keeps up)
const ALT_MAX := 32.0              # metres above the LOCAL terrain (soft ceiling)
const PITCH_MAX_DEG := 35.0        # visual + kinematic pitch clamp
const ROLL_MAX_DEG := 40.0         # visual bank clamp
const PITCH_RATE := 1.2            # rad/s pitch slew toward the input target
const ROLL_RATE := 3.0             # rad/s visual roll slew
const AIR_TURN := 1.1              # rad/s yaw while banked (not speed-scaled — arcade)
# AIR_ACCEL: m/s^2 toward SPEED_MAX while airborne. Throttle is IMPLICIT (cruise power always
# on): airborne input.y is PITCH, so there is no lever left to map to power — arcade contract.
const AIR_ACCEL := 6.0
const CEIL_BAND := 6.0             # metres below ALT_MAX where the allowed climb fades to zero
const GROUNDED_H := 0.5            # terrain-relative height below which a DESCENDING flyer lands
const DESCENT_GAIN := 2.5          # nose-down sink multiplier: a landing flyer cuts throttle, so its airspeed-driven sink (_speed*sin(pitch)) is feeble — this restores real descent authority WITHOUT touching climb/cruise (only applied when _pitch < 0)
const PROP_SPIN := 30.0            # rad/s cosmetic prop-disc spin while driving

# --- desired-heading steering (CONTRACT A: drive_input_world) ---
# Within this cone of the target heading the steer command tapers to zero, so the body eases onto
# the camera-relative heading instead of oscillating across it. Outside it, full turn authority.
const HEADING_BAND := deg_to_rad(35.0)
# REVERSE: when the pushed heading is more than REVERSE_ENTER off the nose, back UP toward it instead
# of U-turning ("pull back = reverse"); latch out again only below REVERSE_EXIT so the forward/reverse
# choice can't flicker at the boundary. A hard SIDEWAYS push (~90°) stays a forward turn; only a
# clearly-behind push reverses. No reverse in flight.
const REVERSE_ENTER := deg_to_rad(115.0)
const REVERSE_EXIT := deg_to_rad(95.0)

# --- wheel motion (2.2) ---
const WHEEL_RADIUS := 0.32         # parametric wheel radius — rolling spin = (speed / radius) * delta
const WHEEL_STEER_MAX := deg_to_rad(28.0)   # front steer-pivot yaw at full stick
const WHEEL_STEER_SLEW := 5.0      # rad/s the front pivots slew toward the steer target

# --- ride bob (2.4: sells motion even when the mount clip is subtle/absent) ---
const RIDE_BOB_AMP := 0.05         # rider vertical bounce, metres (added to the MountMarker y)
const RIDE_PITCH_DEG := 3.0        # +/- body rock pitch on the mount while walking
const RIDE_MOVE_MIN := 0.3         # |speed| above which a mount visibly bobs/rocks

# --- water ride (boat) ---
const BOB_AMP := 0.15              # small bob = 0.15 * sin(time * 1.2) (pinned)
const BOB_HZ := 1.2

# --- mount gait sync ---
const GAIT_MOVE_MIN := 0.5         # |speed| above this plays the move clip
const GAIT_FAST_FRAC := 0.55       # fraction of max_speed above which gallop/run wins over walk

# --- enter/exit state machine (choreographed boards; instant boards jump straight IDLE<->DRIVING) ---
const S_IDLE := 0
const S_ENTERING := 1
const S_DRIVING := 2
const S_EXITING := 3

# --- parametric body tuning ---
const BODY_COLOR_DEFAULT := Color(0.72, 0.16, 0.14)   # warm red (spec "color": [r,g,b] overrides)
const TANK_COLOR_DEFAULT := Color(0.32, 0.36, 0.25)   # olive drab
const BOAT_COLOR_DEFAULT := Color(0.85, 0.87, 0.90)   # white gelcoat
const PLANE_COLOR_DEFAULT := Color(0.78, 0.80, 0.84)  # silver
const DOOR_OPEN_DEG := -70.0   # hinge swing about local +Y; negative = outward on the +X (driver/left) side
const DOOR_TIME := 0.35        # seconds per door swing (open and close)
const WALK_TIME := 0.4         # seconds for the driver's walk-to-seat / step-out position tween
const SEAT_TOP := 0.45         # y of the car cushion top = its "SeatMarker" height (car-local)
# Roof underside of the parametric car (roof slab centre 1.445, 0.09 thick). SEAT_TOP..CAR_ROOF_Y is
# the clear column a seated driver has to fit inside — 0.95 m, which is what a real sedan gives and
# comfortably clears the ~0.86 m sitting height of a 1.65 m humanoid (sitting height runs ~0.52x
# stature). A stylized chibi rig needs ~1.36 m and genuinely cannot sit in a sedan; _seat_driver
# hides those rather than posting a head through the roof. Keep these in sync with the cushion and
# roof slabs in _build_parametric — SCALETEST asserts the resulting column admits one and not the
# other, so a change here that breaks that shows up as a red test rather than a shipped screenshot.
const CAR_ROOF_Y := 1.40
# Fallback hip height as a fraction of standing height, used ONLY when a rig exposes no hip bone.
# Measuring beats this constant every time: it is ~0.52 on a realistic humanoid but 0.178 on a
# KayKit chibi, and seating a chibi by the realistic ratio drops its origin half a metre too far and
# buries it in the floor. See GPose.hips_height.
const HIP_RATIO := 0.52

# --- seat synthesis (mount dorsal scan + modeled-vehicle cabin centre) ---
# Mount seat z, as a fraction of body length FORWARD (+Z) of the AABB centre: horse/bull sit the
# back's dip at the centre; a dragon sits behind the wing roots, forward of centre — the old
# fixed 25%-BACK landed over the rump/tail.
const SEAT_Z_OFF := {"horse": 0.0, "bull": 0.0, "dragon": 0.175}
# Dorsal-height fallback (fraction of AABB height) when the vertex scan finds nothing — the
# back line, NOT ab.end.y (the AABB top is the raised head/crest: horse back ≈ 0.72, dragon 0.55).
const SEAT_FRACTION := {"horse": 0.72, "bull": 0.72, "dragon": 0.55}
const DORSAL_X_BAND := 0.15    # dorsal scan: |x - centreline| window, fraction of body width
const DORSAL_Z_BAND := 0.06    # dorsal scan: |z - seat z| window, fraction of body length
const SCAN_VERT_CAP := 60000   # stride huge Meshy meshes past this many verts (boot-cost cap)
const SCAN_TRI_CAP := 150000   # same cap for the cabin probe's triangle walk
const CABIN_HEADROOM := 1.0    # metres of clear column a seated driver needs above the seat surface
const CABIN_FLOOR_MIN := 0.12  # a cabin floor/deck sits ABOVE this fraction of body height (a
                               # watertight solid body's underside must not read as a "floor")
const CABIN_FLOOR_MAX := 0.75  # ... and BELOW this fraction (a surface at roof height is a roof)
const VEHICLE_SEAT_Z := -0.15  # synthesized vehicle seat: fraction of length BACK of the centre
const SADDLE_COLOR := Color(0.34, 0.21, 0.11)   # leather brown (parametric mount saddle)

# Emitted on enter/exit so main.gd can track the active vehicle (input routing + camera-arm exclusion).
# Choreographed boards emit `true` at sequence START (camera switch + control lockout, Wave-1
# behavior) and `false` at exit-sequence END.
signal drive_state_changed(vehicle: Vehicle, is_driving: bool)

var profile := "car"
var display_name := "Car"
var terrain: GTerrain = null    # set via set_terrain() after the streamer boots; null = flat world (y=0)
var player_ref: Node3D = null   # for the floating DRIVE/RIDE prompt proximity check (set by main at spawn)
var driving := false            # public Wave-1 flag: true from enter-start until exit completes
var water_level := 0.0          # the world's GWater level (set_water) — boats float here

var _state := S_IDLE
var _driver: CharacterBody3D = null
var _speed := 0.0               # signed m/s along -basis.z (negative = reversing)
var _input := Vector2.ZERO      # main.gd's shared input vector (x = steer, y = throttle, screen-up = -y)
var _rev_latch := false         # drive_input_world reverse state (hysteresis, ground/water only)
var _world_drive := false       # true while the on-screen joystick feeds a camera-relative heading via
                                # drive_input_world (point-and-go, speed-independent turn); false = the raw
                                # drive_input(steer,throttle) path used by the verify harness
var _label: Label3D = null
var _height := 1.6              # scaled model height (roof) — the floating label sits above it
var _body_ab := AABB()          # composed body bounds in the vehicle's LOCAL frame — the DRIVE/RIDE
                                # affordance measures to the closest point on THIS, not the origin
var _snapped := false           # first ground snap is instant (no boot-time rise-from-y=0 lerp)
var _has_water := false         # set_water was called (the world HAS a water block)
var _water_rest := false        # this vehicle RESTS on the water surface (boat, or spec "water":true
                                # seaplane) — floors its ground height at water_level when _has_water
var _time := 0.0                # local clock for the boat bob
var _park_t := 0.0              # throttle accumulator for the PARKED per-frame work (see _physics_process)

# --- body/boarding wiring ---
var _parametric := false                  # a parametric VEHICLE body was built (never true for mounts)
var _is_mount := false                    # horse/bull/dragon — model path + MountMarker + GPose.ride
var _board := "door"                      # "door" | "step" | "instant" | "mount"
var _board_local := Vector3(1.45, 0.0, -0.15)   # boarding spot beside the body (self-local, ground level)
var _visual: Node3D = null                # the body subtree that takes the cosmetic flight pitch/roll
var _seat_marker: Node3D = null           # "SeatMarker" — cushion/floor point where the seated hips rest
# Clear vertical column above the SeatMarker, metres. INF = open-topped (boat, plane cockpit, any
# mount) — nothing overhead to clip, so the driver is always visible. A finite value is a ROOF, and
# _seat_driver hides a driver too tall to fit under it instead of clipping them through it. Set by
# whichever body builder ran; INF is the safe default because "no roof" only ever costs visibility.
var _cabin_headroom := INF
                                          # (parametric cushion top OR the modeled-cabin probe's find)
var _mount_marker: Node3D = null          # "MountMarker" — dorsal-surface seat point (rider hips)
var _door_pivot: Node3D = null            # "DoorPivot" — hinge at the door opening's FRONT edge (car only)
var _door_shape: CollisionShape3D = null  # the leaf's blocking collider (disabled while open/driving)
var _door_body: StaticBody3D = null
var _prop: Node3D = null                  # "PropDisc"/rotor — cosmetic spinner (parametric plane OR an assembled aircraft's prop/rotor GLB)
var _wheels: Array[Node3D] = []           # spun about their axle by (speed / _wheel_radius)*delta while moving
var _steer_pivots: Array[Node3D] = []     # front "WheelPivot" nodes — slew toward the steer input
var _wheel_axle := Vector3.UP             # local axle for a wheel spin: parametric +Y (rotation.z=PI/2),
                                          # modeled GLB wheels +X (rolling axis for a +Z-facing body)
var _wheel_radius := WHEEL_RADIUS         # rolling radius used for the spin RATE — the 0.32 parametric/mount
                                          # default; an assembled vehicle overrides it per its wheel-GLB size (spec "wheel_r")
var _ride_bob := 0.0                      # per-tick rider bounce (2.4) added to the MountMarker y
var _seq: Tween = null                    # the running enter/exit choreography
var _seated := false                      # GPose.sit/ride succeeded — driver rides the marker, visible
var hull_len := 4.0                       # nose-to-tail metres after scale-normalize (USE-range credit for big hulls)
var _seat_y_off := 0.0                    # driver-origin drop below the marker (per-rig hip height)
var _mount_seat_y := -INF                 # skeleton-derived saddle-line height (self-local, base-0 frame); -INF = no rig, use scan fallback

# --- flight state (plane + dragon) ---
var _airborne := false
var _pitch := 0.0               # radians, POSITIVE = climb (screen-up / W = climb; see _drive_air)
var _roll := 0.0                # radians, visual bank
var _flyer_orient_yaw := 0.0    # yaw baked to turn an X-fuselage aircraft model onto +Z (drive axis); composed UNDER the flight pitch/roll so climbing pitches the nose instead of barrel-rolling. 0 = model already fuselage-forward.
var _flyer_scale := 1.0         # uniform model scale, preserved when the flight code rebuilds _visual.basis
var _air_thr := 1.0             # 0..1 flight throttle target: _speed eases to SPEED_MAX*_air_thr, so
                                # easing off / pulling back the stick actually SLOWS the flyer.
                                # drive_input_world sets it from the stick; raw drive_input leaves cruise 1.0.
var _land_req := false          # a mid-air USE requested a braked descent-then-dismount (see _drive_air/exit)

# --- mount gait sync (embedded clips only; "" = clip absent -> silent degrade) ---
var _gait_ap: AnimationPlayer = null
var _clip_walk := ""            # substring "walk"
var _clip_fast := ""            # substring "gallop"/"run"
var _clip_idle := ""            # substring "idle" -> rest
var _clip_flap := ""            # substring "fly"/"flap" -> airborne move
var _clip_glide := ""           # substring "glide" -> airborne level/descending
var _clip_any := ""             # LONGEST embedded clip — the move fallback so a rigged creature whose
                                # clips don't name-match a gait still rides animated, never frozen (2.4)


# The library-default model for a profile whose spec omits "model" — main.gd calls this from its
# _vehicle_model_url so mounts fetch their creature GLB instead of the default sedan. Returns ""
# for VEHICLE profiles: those build a parametric body and need no fetch at all.
static func default_model_path(profile_name: String) -> String:
	return String(MOUNT_MODELS.get(profile_name, ""))


# Skeleton rest-pose bounds x the cumulative node scale up to `model` — the true authored size
# of a skinned creature (the mesh AABB under-reads when the armature scale is baked into the skin).
#
# DELIBERATELY BONES-ONLY, unlike GPose.char_height. This feeds the MOUNT dorsal scan, which wants
# the creature's BACK LINE — and a horse's mesh envelope includes its raised head and a dragon's its
# crest, so unioning the envelope in here would move the saddle onto the animal's skull. Height for
# a HUMANOID DRIVER is a different question with a different answer and uses GPose.char_height; the
# two looked interchangeable, and treating them as such is what put a rider's head through a roof.
func _skel_span(model: Node3D) -> Vector3:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return Vector3.ZERO
	var s := sks[0] as Skeleton3D
	if s.get_bone_count() == 0:
		return Vector3.ZERO
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for i in s.get_bone_count():
		var g: Vector3 = s.get_bone_global_rest(i).origin
		lo = lo.min(g)
		hi = hi.max(g)
	if hi.x <= lo.x:
		return Vector3.ZERO
	var cum := Vector3.ONE
	var w: Node = s
	while w != null and w != model and w is Node3D:
		cum *= (w as Node3D).scale
		w = w.get_parent()
	return (hi - lo) * cum


# Skeleton-derived FEET + SADDLE line (self-local metres), robust for the skin-baked-scale Meshy
# rigs where the mesh AABB and the un-skinned vertex scan both mis-report (the very reason
# _skel_span measures by BONES). x = lowest bone origin (the grounding datum); y = highest TORSO
# bone (spine/chest/back/hips/pelvis/torso/body/saddle, EXCLUDING neck/head/tail/leg/twist/roll)
# ~= the withers/saddle line where a rider's hips rest. Bone rest origins are pushed through the
# FULL node chain INCLUDING model.transform (so scale is honoured) to self-local, letting the
# caller ground and seat in ONE frame. Returns Vector2(-INF,-INF) when no skeleton/torso bone.
func _skel_feet_back(model: Node3D) -> Vector2:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return Vector2(-INF, -INF)
	var s := sks[0] as Skeleton3D
	if s.get_bone_count() == 0:
		return Vector2(-INF, -INF)
	var t := s.transform                       # skeleton-local -> self-local (model is a child of self)
	var node := s.get_parent()
	while node != null and node != model and node is Node3D:
		t = (node as Node3D).transform * t
		node = node.get_parent()
	t = model.transform * t
	var foot := INF
	var back := -INF
	for i in s.get_bone_count():
		var bp := t * s.get_bone_global_rest(i).origin
		if bp.y < foot:
			foot = bp.y
		var bn := s.get_bone_name(i).to_lower()
		if "twist" in bn or "roll" in bn or "neck" in bn or "head" in bn or "tail" in bn or "leg" in bn:
			continue
		if "spine" in bn or "chest" in bn or "back" in bn or "hips" in bn or "pelvis" in bn or "torso" in bn or "body" in bn or "saddle" in bn:
			if bp.y > back:
				back = bp.y
	if not is_finite(back) or not is_finite(foot):
		return Vector2(-INF, -INF)
	return Vector2(foot, back)


# Public "is this a creature MOUNT (horse/bull/dragon)?" — main.gd stows the weapon visual while
# DRIVING A VEHICLE but keeps it on a mount (firing from the saddle is a Wave-4 feature). Pure
# accessor over the setup-time flag.
func is_mount() -> bool:
	return _is_mount


# Build the body from a world.json vehicle spec + an (optional) model duplicated from the builder
# cache. Called BEFORE the node enters the tree; main positions it afterwards.
func setup(spec: Dictionary, model: Node3D, parts: Dictionary = {}) -> void:
	profile = String(spec.get("profile", "car"))
	if not PROFILES.has(profile):
		profile = "car"
	var p: Dictionary = PROFILES[profile]
	_is_mount = bool(p.get("mount", false))
	# WATER-REST (2.3): boat floats by profile default; any profile becomes a "seaplane" with spec
	# "water": true; a boat opts out with "water": false. Honored in _rest_y/_ground_h once set_water
	# hands over the level (main.gd wires it via _wire_vehicle_terrain when the world has a water block).
	_water_rest = bool(spec.get("water", p.get("water", false)))
	display_name = String(spec.get("name", profile.capitalize() if _is_mount else "Car"))
	# world layer so the player bumps into a parked boardable; world mask so walls/buildings stop it
	collision_layer = 1
	collision_mask = 1
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING   # y is ours (terrain/water/flight) — no floor magic
	# THE SPEC decides the body mode. VEHICLE profiles: no "model"/"url"/"asset" key -> the
	# profile's parametric body; a model key present -> the Wave-1 fused-GLB swap-in path
	# (placeholder box fallback included when the fetch failed). MOUNT profiles ALWAYS take the
	# model path — main resolves the library default (default_model_path) when the spec omits one.
	# ASSEMBLED multi-part vehicles (Phase 3) carry body_url/wheel_url/prop_url (not a single fused
	# model key), so they must NOT be treated as parametric — fold those keys into the model-present test.
	_parametric = (not _is_mount) and not (spec.has("model") or spec.has("url") or spec.has("asset") or spec.has("body_url") or spec.has("wheel_url") or spec.has("prop_url"))
	# Boarding style: mounts always mount-board (visible rider); parametric vehicles use their
	# profile's style ("door" car / "step" boat+plane / "instant" tank); modeled vehicles board
	# instant (Wave-1 swap-in — a fused GLB has no interior to choreograph into).
	if _is_mount:
		_board = "mount"
	elif _parametric:
		_board = String(p.get("board", "door"))
	else:
		_board = "instant"
	var body_ab: AABB
	if _parametric:
		if model != null:
			model.free()   # unused duplicate from main's default-model resolve (never entered the tree)
		match profile:
			"tank":
				body_ab = _build_parametric_tank(spec)
			"boat":
				body_ab = _build_parametric_boat(spec)
			"plane":
				body_ab = _build_parametric_plane(spec)
			_:
				body_ab = _build_parametric(spec)   # the Wave-2 car, unchanged
	elif spec.has("body_url") or spec.has("wheel_url") or spec.has("prop_url"):
		body_ab = _assemble_model(spec, model, parts)   # Phase 3: bespoke body GLB + engine-instanced (or parametric-fallback) wheels/prop that MOVE
	else:
		body_ab = _mount_model(spec, model)
	if _is_mount:
		_setup_mount(spec, body_ab)
	elif not _parametric:
		_setup_vehicle_seat(spec, body_ab)   # visible-driver seat probe (modeled vehicles)
	_height = maxf(0.8, body_ab.size.y)
	_body_ab = body_ab   # keep the LOCAL-frame bounds for the label's closest-hull-point proximity test
	# box collider from the composed/scaled AABB, centred on it (GLB origins are rarely dead-centre)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(0.5, body_ab.size.x), maxf(0.5, body_ab.size.y), maxf(0.5, body_ab.size.z))
	cs.shape = box
	cs.position = body_ab.position + body_ab.size * 0.5
	add_child(cs)
	# floating DRIVE (RIDE for mounts) prompt over the roof (billboarded, the add_sign idiom),
	# shown only while PARKED near the player — no words while driving. ACTIVATION runs through
	# the interaction system's USE mechanism — this label is the visual affordance only.
	_label = Label3D.new()
	_label.font_size = 48
	_label.pixel_size = 0.012
	_label.modulate = Color(1.0, 1.0, 0.6)
	_label.outline_size = 12
	_label.outline_modulate = Color(0, 0, 0, 0.8)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# FIXED screen size: a perspective-scaled label fills a third of a phone screen when the
	# camera stands next to the hull (giant clipped "DRI…"); fixed_size keeps it a readable cue
	# at every distance and the HUD USE prompt owns the close range anyway.
	_label.fixed_size = true
	_label.pixel_size = 0.0006
	_label.position = Vector3(0.0, _height + 0.8, 0.0)
	_label.visible = false
	add_child(_label)


# A parked mount idles (clip resolution already done in _setup_mount); play() outside the tree is
# deferred by the engine until processing starts, but _ready is the unambiguous place.
func _ready() -> void:
	if _gait_ap != null and _clip_idle != "":
		_play_clip(_clip_idle, 1.0)


# Mount the model: scale-normalise to the profile length, then AABB-ground it (base -> origin,
# drop-only, traffic idiom). MOUNTS normalise by BODY LENGTH (size.z, the stack's forward axis) —
# a wings-spread dragon must not shrink by its WINGSPAN; modeled VEHICLES keep the
# longest-horizontal idiom their profile lengths were tuned for. A spec "scale" (absolute metres,
# nose-to-tail) beats the profile default. Falls back to a simple box body when the GLB isn't
# in the cache, so the boardable still works. Returns the final local AABB the collider is
# derived from.
func _mount_model(spec: Dictionary, model: Node3D) -> AABB:
	var target_len := float(spec.get("scale", PROFILES[profile]["length"]))
	hull_len = target_len   # interaction credits half of this toward USE range on big hulls (QA W-3)
	if model != null:
		var ab := _world_aabb(model)
		# ORIENT ground vehicles whose nose-to-tail LENGTH runs along X: they'd drive CRAB-WISE (body
		# sideways to travel) because forward is Godot -Z and nothing rotated the model onto it. Yaw 90
		# so the length aligns with Z, then re-measure (x/z swapped). EXCLUDE FLYERS: a plane's WINGSPAN
		# (X) is wider than its fuselage LENGTH (Z), so this rule would fire on the wings and spin the
		# aircraft 90 into a sideways attitude — aircraft GLBs are authored fuselage-forward already.
		if not _is_mount:
			if bool(PROFILES.get(profile, {}).get("fly", false)):
				_orient_flyer_fuselage(model)   # aircraft: WINGSPAN confounds the x>z rule, so detect the fuselage by end-heights
				ab = _world_aabb(model)
			elif ab.size.x > ab.size.z:
				model.rotation.y += PI * 0.5
				ab = _world_aabb(model)
		var dim := ab.size.z if (_is_mount and ab.size.z > 0.001) else maxf(ab.size.x, ab.size.z)
		# SKINNED creatures (library animals / rigged mounts): a runtime-parsed skinned mesh
		# reports its RAW bind AABB (the armature's x100 scale is baked into the skin), so the
		# mesh-AABB dim under-reads ~100x and the normalize blows the creature up into a giant.
		# Bones carry the true size — measure by skeleton rest span instead.
		var span := _skel_span(model) if _is_mount else Vector3.ZERO
		if span.z > 0.05:
			dim = span.z
		if dim > 0.001:
			model.scale *= target_len / dim
		_flyer_scale = model.scale.x   # preserved so the flight code can rebuild _visual.basis without dropping scale
		if span.z > 0.05:
			var k := target_len / dim
			var sz: Vector3 = span * k
			# Ground the SCALED mesh so its visible base sits at y=0 (matching the base-0 bounds returned
			# below), and CACHE the skeleton saddle line for _setup_mount in that SAME frame. Normal rigs:
			# _world_aabb (visible mesh base) grounds correctly, so keep it; seat = bone-back above the
			# mesh base. Skin-baked-scale Meshy rigs bake the armature x100 into the SKIN, so _world_aabb
			# under-reads ~100x and never actually grounds (attempt (a)'s stale shift) -> detect via mesh
			# height << bone span and ground by the SKELETON feet instead. Either way the saddle line is
			# bone-derived, so the marker and the returned AABB share ONE grounded frame (no mismatch).
			var wab := _world_aabb(model)
			var mb := wab.position.y
			var fb := _skel_feet_back(model)
			if is_finite(fb.x):
				if wab.size.y < 0.5 * sz.y:
					mb = fb.x                          # unreliable skin-baked mesh -> ground by skeleton feet
				_mount_seat_y = fb.y - mb              # saddle line above the grounded base (both pre-shift)
			model.position.y -= mb
			add_child(model)
			_visual = model
			return AABB(Vector3(-sz.x * 0.5, 0.0, -sz.z * 0.5), sz)   # bone-derived bounds, base at origin
		ab = _world_aabb(model)
		# base -> origin, LIFT *and* drop. A Meshy vehicle GLB is centred on its origin, so its base
		# sits BELOW y=0 (ab.position.y < 0); the old drop-only `-maxf(0.0, …)` left those unlifted, so
		# the body sat under the terrain once the hull origin snapped to the surface (the "vehicles below
		# ground" bug — and a body embedded in the terrain trimesh can't move_and_slide forward either).
		model.position.y = -ab.position.y
		add_child(model)
		_visual = model
		if not _is_mount:
			_scan_model_wheels(model)   # modeled vehicle: register wheel|tire|tyre subnodes as spinners (2.2)
		return _world_aabb(model)
	# placeholder body (model missing) — still boardable, clearly a body-sized box
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(target_len * 0.45, 1.3, target_len)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.57, 0.6)   # neutral "loading" gray, not a jarring red box — a missed model hot-swaps in when its fetch lands (#9)
	mi.material_override = m
	mi.position.y = 0.65
	add_child(mi)
	print("GOGI_PLACEHOLDER vehicle ", profile)   # verify.mjs asset-fail gate: a gray vehicle box is visible
	_visual = mi
	return AABB(Vector3(bm.size.x * -0.5, 0.0, bm.size.z * -0.5), bm.size)


# ── ASSEMBLED MULTI-PART VEHICLE (Phase 3) ──────────────────────────────────────────────────────
# A Meshy-styled BODY GLB (empty wheel wells, no baked prop) + a single WHEEL GLB the engine instances
# at each hub + an optional PROPELLER/ROTOR GLB. The separate parts feed the SAME proven spinner pipeline
# the parametric car/plane use — _update_wheels rolls _wheels about _wheel_axle and slews the front
# _steer_pivots; the _physics_process tick spins _prop about its local +Y — so a Meshy-styled vehicle
# finally gets REAL rolling/steering wheels + a spinning prop with NO doubling (nothing is baked into the
# body). Everything hangs off ONE container that becomes _visual, with the body pre-oriented (nose -> +Z)
# and pre-scaled INSIDE it, then _flyer_orient_yaw/_flyer_scale are reset to 0/1 so the airborne basis
# rebuild (1393/1415) adds ONLY pitch/roll to the container (body + prop + wheels pitch/roll as one unit).
# Returns the BODY-only self-local AABB the box collider is derived from (wheels/prop are visual — no
# collider — so the hull box stays tight, unlike the parametric car whose AABB happens to include wheels).
func _assemble_model(spec: Dictionary, model: Node3D, parts: Dictionary) -> AABB:
	var root := Node3D.new()
	root.name = "AssembledVehicle"
	add_child(root)
	_visual = root
	var body_ab := _assemble_body(spec, root, model)
	# The container holds the final orientation + scale on the body inside it, so the flyer basis-rebuild
	# must add ONLY pitch/roll — never re-apply an orient yaw or a scale (those live on the body child).
	_flyer_orient_yaw = 0.0
	_flyer_scale = 1.0
	# WHEELS / PROP — a bespoke body ALWAYS gets wheels on a car/plane (and a prop on a plane): the
	# supplied wheel/prop GLB when present, else a PARAMETRIC fallback. So a body_url with a MISSING or
	# FAILED wheel_url|prop_url still rolls/spins instead of sliding on a wheelless hull — the graceful
	# degrade for the multi-part salvage path (the agent can drop a failed part's url and still ship a
	# working bespoke ride). Front hubs steer on a car; aircraft gear rolls only.
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.RIGHT
	var wheel_src := parts.get("wheel", null) as Node3D
	# A car always rolls; a flyer gets wheels ONLY if a wheel GLB was authored. Many planes (especially a
	# seaplane) have no wheels, and forcing parametric wingtip gear onto them just reads as "weird side
	# wheels" — so a wheel-less flyer stays clean, while an authored-wheel plane gets tucked belly gear.
	if wheel_src != null or profile == "car":
		_assemble_wheels(spec, root, body_ab, wheel_src)   # wheel_src null (car) -> parametric fallback wheels
	# PROP / ROTOR — nose (+Z) for a plane, top (+Y) for a helicopter-style rotor; spun about local +Y
	var prop_src := parts.get("prop", null) as Node3D
	if prop_src != null or profile == "plane":
		_assemble_prop(spec, root, body_ab, prop_src)      # prop_src null on a plane -> parametric prop disc
	print("GOGI_ASSEMBLED ", display_name, " profile=", profile, " wheels=", _wheels.size(), " steer=", _steer_pivots.size(), " prop=", ("yes" if _prop != null else "no"), " wheel_r=%.2f" % _wheel_radius)
	return body_ab


# BODY of an assembled vehicle: normalise to the profile length, orient the nose onto +Z (flyers use the
# fuselage detector; ground vehicles yaw 90 when their length runs along X), ground the base to y=0, and
# parent it INTO the container `root`. Returns the body-only AABB in container/self-local frame. Mirrors
# _mount_model's vehicle branch minus the mount/skinned-creature handling. A missing GLB degrades to a
# gray body box so the boardable still works.
func _assemble_body(spec: Dictionary, root: Node3D, model: Node3D) -> AABB:
	var target_len := float(spec.get("scale", PROFILES[profile]["length"]))
	hull_len = target_len
	if model != null:
		var ab := _world_aabb(model)
		if bool(PROFILES.get(profile, {}).get("fly", false)):
			_orient_flyer_fuselage(model)   # WINGSPAN fools the x>z rule — detect the fuselage by end bulk
			ab = _world_aabb(model)
		elif ab.size.x > ab.size.z:
			model.rotation.y += PI * 0.5    # length ran along X -> would drive crab-wise; yaw onto +Z
			ab = _world_aabb(model)
		var dim := maxf(ab.size.x, ab.size.z)
		if dim > 0.001:
			model.scale *= target_len / dim
		ab = _world_aabb(model)
		model.position.y = -ab.position.y   # base -> y=0 (lift & drop, the _mount_model grounding idiom)
		root.add_child(model)
		return _world_aabb(model)
	# GLB missing -> gray "loading" body box, still boardable (mirror _mount_model's placeholder)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(target_len * 0.45, 1.3, target_len)
	mi.mesh = bm
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.55, 0.57, 0.6)
	mi.material_override = pm
	mi.position.y = 0.65
	root.add_child(mi)
	print("GOGI_PLACEHOLDER vehicle ", profile, " (assembled body GLB missing)")
	return AABB(Vector3(bm.size.x * -0.5, 0.0, bm.size.z * -0.5), bm.size)


# Instance the single wheel GLB at each hub. Hubs auto-derive from the body footprint (front/rear axle
# +/- wheelbase/2, left/right +/- track/2, hub y = wheel radius so the tyre bottom kisses y=0) unless the
# spec authors "hubs":[{"pos":[x,y,z],"steer":bool}]. Each wheel is fitted into a holder whose ROLL axis
# is local +X (the modeled convention, _wheel_axle=RIGHT) and scaled to the wheel radius; the HOLDER is
# what spins (and, for a car's front hubs, what a WheelPivot steers). Aircraft gear never steers.
func _assemble_wheels(spec: Dictionary, root: Node3D, body_ab: AABB, wheel_src: Node3D) -> void:
	var is_car := not bool(PROFILES.get(profile, {}).get("fly", false))
	var wheel_r := float(spec.get("wheel_r", clampf(body_ab.size.y * 0.30, 0.22, 0.7)))
	_wheel_radius = maxf(0.05, wheel_r)
	for hub in _wheel_hubs(spec, body_ab, _wheel_radius, is_car):
		var pos: Vector3 = hub[0]
		var steer: bool = hub[1]
		var holder := Node3D.new()
		holder.name = "Wheel"
		var wh: Node3D
		if wheel_src != null:
			wh = wheel_src.duplicate() as Node3D
		else:
			wh = _parametric_wheel(_wheel_radius)   # no wheel_url -> a dark parametric tyre so the bespoke body still rolls
		holder.add_child(wh)
		_fit_part_axis(holder, wh, 0, _wheel_radius)   # roll axis -> +X, radius -> wheel_r, centre at holder origin
		if steer:
			var pivot := Node3D.new()
			pivot.name = "WheelPivot"
			pivot.position = pos
			root.add_child(pivot)
			pivot.add_child(holder)                     # holder sits at the pivot origin; the pivot carries the steer yaw
			_steer_pivots.append(pivot)
		else:
			holder.position = pos
			root.add_child(holder)
		_wheels.append(holder)


# Four hub anchors (self-local) from the body footprint, or the authored spec "hubs". Front hubs (z>0)
# steer on a car. wheelbase/track default to fractions of the body length/width; spec overrides win.
func _wheel_hubs(spec: Dictionary, body_ab: AABB, wheel_r: float, is_car: bool) -> Array:
	var out: Array = []
	var authored = spec.get("hubs", null)
	if authored is Array:
		for h in authored:
			if h is Dictionary and (h.get("pos") is Array) and (h["pos"] as Array).size() >= 3:
				var a: Array = h["pos"]
				out.append([Vector3(float(a[0]), float(a[1]), float(a[2])), bool(h.get("steer", false))])
		if not out.is_empty():
			return out
	var cx := body_ab.position.x + body_ab.size.x * 0.5
	var cz := body_ab.position.z + body_ab.size.z * 0.5
	var half_base := maxf(0.3, float(spec.get("wheelbase", body_ab.size.z * 0.62)) * 0.5)
	# AIRCRAFT gear: a plane's body is nose-onto-+Z, so size.x is the WINGSPAN — deriving the track from
	# it fans the gear out to the wingtips ("wheels on the side"). A flyer tucks a narrow belly gear under
	# the fuselage instead (clamped well inside the wingspan); a car keeps the wide footprint.
	var track_def := body_ab.size.x * 0.82
	if not is_car:
		track_def = clampf(body_ab.size.z * 0.16, wheel_r * 3.0, body_ab.size.x * 0.14)
	var half_track := maxf(0.3, float(spec.get("track", track_def)) * 0.5)
	for sx in [-1.0, 1.0]:
		out.append([Vector3(cx + half_track * sx, wheel_r, cz + half_base), is_car])   # front (steer on a car)
		out.append([Vector3(cx + half_track * sx, wheel_r, cz - half_base), false])    # rear
	return out


# Place the prop/rotor GLB and assign _prop (spun about its local +Y in _physics_process while driving).
# PLANE (default): nose (+Z), holder rotation.x=90 so local +Y -> forward, disc faces ahead — the same
# axis trace as the parametric PropDisc. HELICOPTER-style (spec "prop_mount":"top"): on top, local +Y
# stays up so the blades sweep horizontally. The blade disc is fitted so its normal is holder-local +Y.
func _assemble_prop(spec: Dictionary, root: Node3D, body_ab: AABB, prop_src: Node3D) -> void:
	var holder := Node3D.new()
	holder.name = "PropDisc"
	var pr: Node3D
	if prop_src != null:
		pr = prop_src.duplicate() as Node3D
	else:
		pr = _parametric_prop()   # no prop_url on a plane -> a cosmetic parametric disc so it still spins
	holder.add_child(pr)
	var target_r := clampf(maxf(body_ab.size.x, body_ab.size.y) * 0.45, 0.35, 2.2)
	_fit_part_axis(holder, pr, 1, target_r)   # disc normal -> +Y, radius -> target_r, centre at holder origin
	var cx := body_ab.position.x + body_ab.size.x * 0.5
	if String(spec.get("prop_mount", "nose")) == "top":
		holder.position = Vector3(cx, body_ab.end.y + target_r * 0.12, body_ab.position.z + body_ab.size.z * 0.5)
	else:
		holder.rotation.x = PI * 0.5   # local +Y -> +Z (forward): the disc faces the nose
		holder.position = Vector3(cx, body_ab.position.y + body_ab.size.y * 0.55, body_ab.end.z + target_r * 0.10)
	root.add_child(holder)
	_prop = holder


# Fit a wheel/disc part INTO its holder: rotate the part so its THIN axis (a wheel's roll axis / a prop
# disc's normal) points the holder-local `axis_to` (0 = +X wheel roll, 1 = +Y disc normal), uniform-scale
# it so its radius (across the two thick axes) = target_r, and shift it so the part CENTRE sits at the
# holder origin — so the holder's position IS the hub/mount point and spinning rolls about the centre. A
# wheel/disc is symmetric about its axis, so either sign of the target axis is equivalent.
func _fit_part_axis(holder: Node3D, part: Node3D, axis_to: int, target_r: float) -> void:
	var ab := _world_aabb(part)
	if ab.size == Vector3.ZERO:
		return
	var thin := _thin_axis(ab.size)
	if axis_to == 0:                            # want thin on +X (wheel roll axis)
		if thin == 1: part.rotate_z(PI * 0.5)   # +Y -> +X
		elif thin == 2: part.rotate_y(PI * 0.5)  # +Z -> +X
	else:                                        # want thin on +Y (disc normal)
		if thin == 0: part.rotate_z(PI * 0.5)   # +X -> +Y
		elif thin == 2: part.rotate_x(PI * 0.5)  # +Z -> +Y
	var ab2 := _world_aabb(part)
	var rad := (maxf(ab2.size.y, ab2.size.z) if axis_to == 0 else maxf(ab2.size.x, ab2.size.z)) * 0.5
	if rad > 0.001:
		part.scale *= target_r / rad
	var ab3 := _world_aabb(part)
	part.position -= (ab3.position + ab3.size * 0.5)   # centre the part on the holder origin


# Index (0=x,1=y,2=z) of the smallest extent — a wheel/disc's flat axis (its spin/roll axis).
func _thin_axis(size: Vector3) -> int:
	if size.x <= size.y and size.x <= size.z:
		return 0
	if size.y <= size.x and size.y <= size.z:
		return 1
	return 2


# PARAMETRIC FALLBACK PARTS for an assembled body whose wheel_url / prop_url is missing or failed — so a
# bespoke Meshy body still ROLLS (and a plane still spins a prop) instead of sliding on a wheelless hull.
# Both are built origin-centred with their flat/thin axis on +Y, so _fit_part_axis fits + scales them into
# a Wheel/PropDisc holder exactly like a loaded GLB part (a wheel: thin +Y -> roll +X; a disc: thin +Y).
func _parametric_wheel(r: float) -> MeshInstance3D:
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var wh := GShapes.cylinder(r, r, r * 0.55, 18)   # thin axis = height (< radius) = +Y
	GShapes.set_material(wh, tire)
	return wh


func _parametric_prop() -> MeshInstance3D:
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var disc := GShapes.cylinder(1.0, 1.0, 0.06, 24)   # flat cosmetic disc, thin axis +Y (matches the parametric plane prop)
	GShapes.set_material(disc, trim)
	return disc


# FLYER FUSELAGE ORIENT. Aircraft GLBs are authored with the nose along an arbitrary horizontal axis AND
# direction, and the ground x>z rule CAN'T tell fuselage from WINGSPAN — a plane's wings make the AABB
# x<z even when the fuselage is sideways, so the old code excluded flyers and left them crab-wise +
# barrel-rolling on climb (pitch is applied about local X; for an X-fuselage that's a ROLL). Two-step:
#   (1) FUSELAGE AXIS = the horizontal axis whose ENDS keep HEIGHT (nose/cockpit/tail-fin are tall) while
#       the WINGSPAN axis tapers to THIN wingtips.
#   (2) NOSE END = the end with the larger OUTER cross-section (the blunt cockpit/engine mass). The TAIL
#       always tapers to a thin boom/fin, so cross-section — not end-HEIGHT — is the reliable nose signal:
#       a propeller/cockpit makes the NOSE the taller end on some models and the tail fin makes the TAIL
#       taller on others (the old "taller = tail" rule flew the Bush Plane/helicopter BACKWARDS).
# Then bake the yaw that turns the nose onto +Z (the drive axis) so climbing PITCHES the nose up.
func _orient_flyer_fuselage(model: Node3D) -> void:
	var pts := PackedVector3Array()
	_collect_mesh_pts(model, Transform3D.IDENTITY, pts, 2400)
	if pts.size() < 24:
		return
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = mn.min(p)
		mx = mx.max(p)
	var size := mx - mn
	if size.x < 0.01 or size.z < 0.01:
		return
	# (1) fuselage axis = the horizontal axis with the TALLER ends (nose/cockpit/fin vs thin wingtips)
	var xlo := _yspan_end(pts, 0, mn.x, mn.x + 0.25 * size.x)
	var xhi := _yspan_end(pts, 0, mx.x - 0.25 * size.x, mx.x)
	var zlo := _yspan_end(pts, 2, mn.z, mn.z + 0.25 * size.z)
	var zhi := _yspan_end(pts, 2, mx.z - 0.25 * size.z, mx.z)
	var fax := 0 if maxf(xlo, xhi) >= maxf(zlo, zhi) else 2   # 0 = X fuselage, 2 = Z fuselage
	var pax := 2 if fax == 0 else 0                            # WINGSPAN axis (perpendicular horizontal)
	# (2) nose end = the end with the larger OUTER cross-section (blunt cockpit/engine); tail tapers thin
	var neg_bulk := _end_xsec(pts, fax, pax, mn, size, false)
	var pos_bulk := _end_xsec(pts, fax, pax, mn, size, true)
	var nose_pos := pos_bulk > neg_bulk       # true = nose on the +axis end
	# rotate the nose onto +Z: X-fuselage needs ±90°; Z-fuselage is 0 (already fwd) or 180 (reversed)
	if fax == 0:
		_flyer_orient_yaw = (-PI * 0.5) if nose_pos else (PI * 0.5)
	else:
		_flyer_orient_yaw = 0.0 if nose_pos else PI
	if not is_zero_approx(_flyer_orient_yaw):
		model.rotation.y += _flyer_orient_yaw
	var axn := "X" if fax == 0 else "Z"
	var nosn := ("+" if nose_pos else "-") + axn
	print("GOGI_FLYER_ORIENT %s fuselage=%s nose=%s bulk(-/+)=%.2f/%.2f yaw=%.2f" % [display_name, axn, nosn, neg_bulk, pos_bulk, _flyer_orient_yaw])


# Gather sampled mesh vertices into `out` in the frame of the ROOT passed to the first call (xf = the
# transform from each descendant up to that root). Sampled/capped so a dense hull stays cheap at load.
func _collect_mesh_pts(node: Node, xf: Transform3D, out: PackedVector3Array, cap: int) -> void:
	if out.size() >= cap:
		return
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			if arr.size() <= Mesh.ARRAY_VERTEX or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var vs := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var step := maxi(1, int(vs.size() / maxi(1, int(cap / 3))))
			var i := 0
			while i < vs.size() and out.size() < cap:
				out.append(xf * vs[i])
				i += step
	for c in node.get_children():
		if c is Node3D:
			_collect_mesh_pts(c, xf * (c as Node3D).transform, out, cap)


# Vertical extent (max-min y) of the vertices whose X (axis 0) or Z (axis 2) falls in [lo, hi]. 0 if empty.
func _yspan_end(pts: PackedVector3Array, axis: int, lo: float, hi: float) -> float:
	var ymn := INF
	var ymx := -INF
	for p in pts:
		var a: float = p.x if axis == 0 else p.z
		if a >= lo and a <= hi:
			ymn = minf(ymn, p.y)
			ymx = maxf(ymx, p.y)
	return (ymx - ymn) if ymx > ymn else 0.0


# Outer-end cross-section proxy (perp-width * height) over the outer 30% band on one end of the
# fuselage axis. The NOSE (blunt cockpit/engine) has the larger cross-section; the TAIL tapers to a
# thin boom/fin — so the bulkier end is the nose. `positive`=true samples the +axis end, else the -axis.
func _end_xsec(pts: PackedVector3Array, fax: int, pax: int, mn: Vector3, size: Vector3, positive: bool) -> float:
	var lenf: float = size[fax]
	if lenf < 0.001:
		return 0.0
	var lo := 0.70 if positive else 0.0
	var hi := 1.0 if positive else 0.30
	var pmn := INF
	var pmx := -INF
	var ymn := INF
	var ymx := -INF
	for p in pts:
		var t: float = (p[fax] - mn[fax]) / lenf
		if t >= lo and t < hi:
			pmn = minf(pmn, p[pax])
			pmx = maxf(pmx, p[pax])
			ymn = minf(ymn, p.y)
			ymx = maxf(ymx, p.y)
	if pmx <= pmn or ymx <= ymn:
		return 0.0
	return (pmx - pmn) * (ymx - ymn)


# Modeled-vehicle wheel discovery (2.2): register the TOP-MOST descendant Node3D whose name
# contains wheel/tire/tyre as a spinner (skip its children so a rim+tire pair isn't double-spun).
# A +Z-facing body rolls its wheels about local +X, so _wheel_axle flips to +X here. No match ->
# _wheels stays empty (static wheels, per the fused-GLB contract) — we never fabricate wheels the
# model doesn't have, and never steer-pivot a modeled vehicle (no reliable steer axis).
func _scan_model_wheels(model: Node3D) -> void:
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.RIGHT
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var matched := false
		if n is Node3D:
			var nm := String(n.name).to_lower()
			if "wheel" in nm or "tire" in nm or "tyre" in nm:
				_wheels.append(n as Node3D)
				matched = true
		if not matched:
			for c in n.get_children():
				stack.append(c)
	# Fused single-mesh vehicle GLBs (typical of Meshy text/image-to-3D output) have their wheels
	# BAKED INTO the body mesh — no separable wheel nodes to spin. We do NOT fabricate parametric
	# wheels here: a model that already shows baked wheels would then render doubled. Instead emit a
	# build-visible line so verify/QA can flag it — the world author should use a PARAMETRIC profile
	# (wheels spin) or a model with separable wheel/tire nodes when rolling wheels matter.
	if _wheels.is_empty():
		print("GOGI_WHEELS fused-static ", display_name, " (modeled vehicle has no separable wheel nodes — wheels won't spin)")


# Mount extras, computed at setup from the FINAL (scaled, grounded) AABB:
#   - "MountMarker": rider hips rest here — seated ON the DORSAL SURFACE (the mesh back line
#     sampled near the centreline at the per-profile seat z), NOT the AABB top: ab.end.y is the
#     raised head/crest and left riders hovering ~0.5-1.4m of air above the visible back. An
#     authored seat (spec "seat" / SaddleMarker node) wins verbatim; a failed scan degrades to a
#     per-profile SEAT_FRACTION of the AABB height.
#   - one GOGI_SEAT_CONTACT telemetry line (gap between marker and sampled surface — 0.0 when
#     seated directly on the sample) that the verify harness greps.
#   - parametric saddle at the seat (spec {"saddle": false} disables).
#   - boarding spot: on the ground beside the creature's flank at the marker's z.
#   - gait AnimationPlayer + clip resolution by NAME SUBSTRING (walk/trot/canter/move,
#     gallop/run/sprint, idle, fly/flap, glide). Library animals and rig-lab outputs both carry
#     EMBEDDED clips; a rig whose clips DON'T name-match still rides on the LONGEST clip (_clip_any)
#     instead of freezing, and only a truly clipless creature rides silently un-animated (2.4).
func _setup_mount(spec: Dictionary, ab: AABB) -> void:
	var centre := ab.position + ab.size * 0.5
	var seat_z := centre.z + float(SEAT_Z_OFF.get(profile, 0.0)) * ab.size.z
	var gap := 0.0
	var seat := _authored_seat(spec)
	if seat.is_finite():
		var dy := _dorsal_y(seat.x, seat.z, ab)
		if is_finite(dy):
			gap = seat.y - dy   # authored seat: report its height over the sampled surface
	elif is_finite(_mount_seat_y):
		# ROBUST SEAT: the skeleton's saddle line (highest torso bone), cached by _mount_model in the
		# SAME grounded, base-0 frame as `ab`. This replaces the old fraction-of-bone-span fallback and
		# the mesh-vertex scan band — both of which mixed frames (seat as a fraction of the BONE span vs
		# a back surface that is a fraction of the taller MESH), rejecting good scans and sinking the
		# rider. Lift a hair from the spine-bone CENTRE to the back SURFACE so the hips rest ON the
		# back, not buried in the vertebrae; _seat_y_off then applies the astride hip drop.
		seat = Vector3(centre.x, _mount_seat_y + 0.06 * ab.size.y, seat_z)
	else:
		# No skeleton (parametric/placeholder mount): degrade to the prior mesh-scan + fraction heuristic.
		var frac_y := ab.position.y + float(SEAT_FRACTION.get(profile, 0.6)) * ab.size.y
		var dy := _dorsal_y(centre.x, seat_z, ab)
		var lo := ab.position.y + 0.60 * ab.size.y
		var hi := ab.position.y + 0.72 * ab.size.y
		if is_finite(dy) and dy >= lo and dy <= hi:
			seat = Vector3(centre.x, dy, seat_z)   # scan landed on the back
		else:
			seat = Vector3(centre.x, frac_y, seat_z)   # bogus/absent scan -> back-line fraction
	_mount_marker = Node3D.new()
	_mount_marker.name = "MountMarker"
	_mount_marker.position = seat
	add_child(_mount_marker)
	print("GOGI_SEAT_CONTACT ", String(spec.get("name", profile)), " ", "%.3f" % gap)
	if bool(spec.get("saddle", true)):
		_build_saddle(seat)
	_board_local = Vector3(ab.end.x + 0.5, 0.0, _mount_marker.position.z)
	_gait_ap = _find_anim(self)
	if _gait_ap != null:
		_clip_walk = _match_clip(["walk", "trot", "canter", "move"])
		_clip_fast = _match_clip(["gallop", "run", "sprint"])
		_clip_idle = _match_clip(["idle"])
		_clip_flap = _match_clip(["fly", "flap"])
		_clip_glide = _match_clip(["glide"])
		_clip_any = _longest_clip()   # move fallback: a rigged-but-unnamed clip beats a frozen ride (2.4)


# Synthesized seat for MODELED vehicles (the empty-jeep fix): an authored seat wins outright;
# otherwise seat at the CABIN CENTRE at half body height and put a "SeatMarker" there (the
# in-body comment at the retired _probe_cabin_seat says why the column probe went). enter()'s
# instant board then seats the driver VISIBLY (GPose.sit through _seat_driver, _seated=true —
# _park_driver/_track_driver's existing visible-seated path drives it). Closed cabs and flyers
# keep the Wave-1 hide, unchanged.
func _setup_vehicle_seat(spec: Dictionary, ab: AABB) -> void:
	if String(spec.get("cab", "")) == "closed":
		# authored closed cab (helicopter / jet glider): the dorsal probe lands the driver ON the
		# hull exterior of a closed-canopy aircraft (QA P1-A) — keep the hidden-driver swap-in.
		return
	var seat := _authored_seat(spec)
	if not seat.is_finite():
		# AIRCRAFT (fly profile, no authored seat): an aircraft's AABB height is inflated by the tall
		# tail fin + landing gear, so the centre-of-AABB seat below lands at/above the cabin roof and
		# the seated pilot POPS OUT the top (QA: Bush Plane). A fused-GLB cockpit interior is unreliable
		# to probe, so hide the driver (the Wave-1 swap-in) for every flyer — same as the closed-cab
		# helicopter/glider. An explicit spec "seat" still wins above; this only replaces the fallback.
		if bool(PROFILES.get(profile, {}).get("fly", false)):
			print("GOGI_SEAT_CONTACT ", String(spec.get("name", String(spec.get("profile", "car")))), " hidden-flyer")
			return
		# Seat the driver at the CABIN CENTRE at seat height. This replaces the fragile per-model floor
		# probe, which HID the driver entirely on fused/open hulls (the INVISIBLE roadster) and picked
		# the wrong row on others (the driver riding in the truck BED). A centre-of-cabin seat is ALWAYS
		# visible, seated INSIDE the hull, and never popping — consistent across every AI-generated model.
		var centre := ab.position + ab.size * 0.5
		seat = Vector3(centre.x, ab.position.y + 0.5 * ab.size.y, centre.z)
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = seat + Vector3(0.0, 0.05, 0.0)   # hips just above the found surface
	add_child(_seat_marker)
	# Same telemetry contract as _setup_mount (verify greps one line per boardable): the seat
	# sits directly on the probed cabin surface, so the marker-to-surface gap is the 0.05 lift.
	print("GOGI_SEAT_CONTACT ", String(spec.get("name", String(spec.get("profile", "car")))), " 0.050")


# An authored seat beats every heuristic: spec "seat": [x, y, z] (self-local metres) verbatim, or
# a marker node inside the model ("SaddleMarker"/"saddle"/"SeatMarker"/"seat_hint" — rig-lab and
# builders can pin the exact point). Vector3.INF = nothing authored. The node lookup accumulates
# transforms manually (_world_aabb idiom): setup() runs before tree entry, where global_position
# would error.
func _authored_seat(spec: Dictionary) -> Vector3:
	var s = spec.get("seat", null)
	if s is Array and (s as Array).size() >= 3:
		return Vector3(float(s[0]), float(s[1]), float(s[2]))
	if _visual == null:
		return Vector3.INF
	var stack: Array = [[_visual, _visual.transform]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		if n is Node3D:
			var nm := String(n.name).to_lower()
			if "saddlemarker" in nm or "seatmarker" in nm or nm == "saddle" or nm == "seat_hint":
				return xf.origin
		for c in n.get_children():
			var cx := xf
			if c is Node3D:
				cx = xf * (c as Node3D).transform
			stack.append([c, cx])
	return Vector3.INF


# Max mesh-vertex height (self-local) in a column around (sx, sz) — the DORSAL-SURFACE sample.
# Rest-pose vertex reads (the scan runs at setup, before any idle clip plays), transform-
# accumulating walk mirroring _world_aabb (detachment-safe). Huge Meshy meshes are STRIDED —
# a surface dense enough to trip the cap stays well-sampled through the stride. Returns -INF
# when no vertex lands in the window (caller falls back to SEAT_FRACTION).
func _dorsal_y(sx: float, sz: float, ab: AABB) -> float:
	var best := -INF
	if _visual == null:
		return best
	var rx := maxf(0.05, DORSAL_X_BAND * ab.size.x)
	var rz := maxf(0.05, DORSAL_Z_BAND * ab.size.z)
	var stack: Array = [[_visual, _visual.transform]]
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
			var mesh: Mesh = (n as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var step := 1
				if verts.size() > SCAN_VERT_CAP:
					step = int(ceilf(float(verts.size()) / float(SCAN_VERT_CAP)))
				var i := 0
				while i < verts.size():
					var v := xf * verts[i]
					if absf(v.x - sx) <= rx and absf(v.z - sz) <= rz and v.y > best:
						best = v.y
					i += step
	return best


# RETIRED — _setup_vehicle_seat seats at the CABIN CENTRE instead. Kept for reference only:
# as of the 2026-08-21 rpg->3d engine re-sync this has ZERO callers in EITHER template
# (3d/vehicle.gd used to call it and is now a verbatim copy of this file). Do not wire it
# back up without re-reading why the probe was retired.
# CABIN PROBE: collect every y where the vertical line at (sx, sz) pierces body geometry, then
# walk the crossings TOP-DOWN for a floor/deck/cushion surface with CABIN_HEADROOM of clear
# column above it (open sky counts). The floor band guards both false-opens: a watertight solid
# body's underside (below CABIN_FLOOR_MIN of the height) and its roof read from outside (above
# CABIN_FLOOR_MAX) are rejected, so a fused sedan blob stays on the hide path. Vector3.INF = no
# viable seat.
func _probe_cabin_seat(sx: float, sz: float, ab: AABB) -> Vector3:
	var ys := _column_hits(sx, sz)
	if ys.is_empty():
		return Vector3.INF
	var floor_min := ab.position.y + CABIN_FLOOR_MIN * ab.size.y
	var floor_max := ab.position.y + CABIN_FLOOR_MAX * ab.size.y
	for i in range(ys.size() - 1, -1, -1):
		var fy := ys[i]
		if fy > floor_max or fy < floor_min:
			continue
		var head := (ys[i + 1] - fy) if i + 1 < ys.size() else INF
		if head >= CABIN_HEADROOM:
			# The probe already knows the exact clear column it accepted — keep it, so _seat_driver
			# can ask "does THIS driver fit" instead of assuming CABIN_HEADROOM suits every rig. A
			# cab with 1.0 m of room takes a realistic humanoid and not a chibi, and only the
			# measured value can tell those apart.
			_cabin_headroom = head
			return Vector3(sx, fy, sz)
	return Vector3.INF


# All self-local y crossings of the vertical line at (sx, sz) with the body's triangles, sorted
# ascending. Deindexed via Mesh.get_faces(); a cheap xz reject keeps the per-triangle cost tiny
# and SCAN_TRI_CAP strides truly huge meshes (dense enough to survive the stride).
func _column_hits(sx: float, sz: float) -> PackedFloat32Array:
	var ys := PackedFloat32Array()
	if _visual == null:
		return ys
	var stack: Array = [[_visual, _visual.transform]]
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
			var faces := (n as MeshInstance3D).mesh.get_faces()
			var tri_count := int(faces.size() / 3.0)
			var step := 3
			if tri_count > SCAN_TRI_CAP:
				step = 3 * int(ceilf(float(tri_count) / float(SCAN_TRI_CAP)))
			var i := 0
			while i + 2 < faces.size():
				var a := xf * faces[i]
				var b := xf * faces[i + 1]
				var c3 := xf * faces[i + 2]
				i += step
				# cheap xz reject before the barycentric test
				if (a.x < sx and b.x < sx and c3.x < sx) or (a.x > sx and b.x > sx and c3.x > sx):
					continue
				if (a.z < sz and b.z < sz and c3.z < sz) or (a.z > sz and b.z > sz and c3.z > sz):
					continue
				var y := _tri_line_y(a, b, c3, sx, sz)
				if not is_nan(y):
					ys.append(y)
	ys.sort()
	return ys


# y where the vertical line at (sx, sz) pierces triangle (a, b, c) — NAN on a miss (2D
# barycentric containment in the xz plane, then the plane equation solved along the line;
# vertical wall faces have no y pierce).
func _tri_line_y(a: Vector3, b: Vector3, c: Vector3, sx: float, sz: float) -> float:
	var v0 := Vector2(c.x - a.x, c.z - a.z)
	var v1 := Vector2(b.x - a.x, b.z - a.z)
	var v2 := Vector2(sx - a.x, sz - a.z)
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d02 := v0.dot(v2)
	var d11 := v1.dot(v1)
	var d12 := v1.dot(v2)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-12:
		return NAN
	var u := (d11 * d02 - d01 * d12) / den
	var w := (d00 * d12 - d01 * d02) / den
	if u < -0.0001 or w < -0.0001 or u + w > 1.0001:
		return NAN
	var nrm := (b - a).cross(c - a)
	if absf(nrm.y) < 1e-12:
		return NAN
	return a.y - (nrm.x * (sx - a.x) + nrm.z * (sz - a.z)) / nrm.y


# Parametric SADDLE at the mount's seat point (spec {"saddle": false} disables): a low flattened
# leather pad + rear lip + two strap/stirrup hints, ~0.5m — the rider's visual anchor. Generators
# ship mounts BARE-BACKED (playbook rule), so the engine owns the tack. Attached to the BODY (not
# _visual): it stays level with the parked rider, exactly like the MountMarker. Purely cosmetic —
# built after the collider AABB is measured, so it never fattens the box.
func _build_saddle(at: Vector3) -> void:
	var leather := GSurf.surface({"color": [SADDLE_COLOR.r, SADDLE_COLOR.g, SADDLE_COLOR.b], "rough": 0.85, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var root := Node3D.new()
	root.name = "Saddle"
	root.position = at
	add_child(root)
	var pad := GShapes.box(Vector3(0.42, 0.06, 0.52))
	GShapes.set_material(pad, leather)
	pad.position = Vector3(0.0, 0.03, 0.0)   # pad base ON the dorsal surface (the marker height)
	root.add_child(pad)
	var cantle := GShapes.box(Vector3(0.34, 0.09, 0.08))
	GShapes.set_material(cantle, leather)
	cantle.position = Vector3(0.0, 0.09, -0.24)   # low rear lip
	root.add_child(cantle)
	for sx in [-1.0, 1.0]:
		var strap := GShapes.box(Vector3(0.03, 0.30, 0.06))
		GShapes.set_material(strap, leather)
		strap.position = Vector3(0.24 * sx, -0.15, 0.05)
		root.add_child(strap)
		var stirrup := GShapes.box(Vector3(0.05, 0.05, 0.14))
		GShapes.set_material(stirrup, leather)
		stirrup.position = Vector3(0.24 * sx, -0.31, 0.05)
		root.add_child(stirrup)


# ---------------- parametric bodies (VEHICLE profiles, spec "model" omitted) ----------------

# The articulated default car (Wave 2, unchanged): GShapes boxes/cylinders + GSurf triplanar
# materials. Grounded (base y=0), forward +Z (Wave-1 convention), so the LEFT/driver side is +X —
# which is exactly where Wave-1's exit_side (+basis.x) already steps the driver out. Cabin is a
# composed CAVITY (floor/walls/dash/roof panels, open where the door is) with two seats, a dash,
# a steering wheel, and a "SeatMarker" Node3D on the cushion top. The driver-side DOOR LEAF
# hinges at its FRONT edge ("DoorPivot"), carries its own StaticBody3D collider (collision-
# excepted from this body, disabled while open or driving), and is NOT in the "gogi_door" group —
# building-door consumers must never discover a car door. Returns the composed local AABB
# (door closed).
func _build_parametric(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, BODY_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.35, "metal": 0.25, "bump": 0.0, "tile": 6.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "CarBody"
	add_child(root)
	_visual = root
	# shell — hood/trunk/bumpers around an open cabin (z -1.225 .. 0.95, belt line y 1.05)
	_part(root, Vector3(1.5, 0.30, 0.18), Vector3(0.0, 0.45, 1.93), trim)     # front bumper
	_part(root, Vector3(1.5, 0.30, 0.18), Vector3(0.0, 0.45, -1.93), trim)    # rear bumper
	_part(root, Vector3(1.5, 0.42, 1.0), Vector3(0.0, 0.55, 1.45), paint)     # hood
	_part(root, Vector3(1.5, 0.55, 0.75), Vector3(0.0, 0.62, -1.60), paint)   # trunk
	# SUNKEN CABIN. The floor/cushion used to sit at 0.35/0.50, leaving 0.675 m between the cushion
	# top and the roof underside (1.255). A seated 1.65 m humanoid needs ~0.79 m from hips to the top
	# of its head — so NOBODY fit, and every driver either clipped through the roof or got hidden by
	# the fallback, which made the visible-driver feature dead code on the most common vehicle in the
	# library. Dropping the floor 0.13 m buys 0.825 m of headroom and changes no exterior line: the
	# roof, glass, pillars, bumpers, hood, trunk and wheels are all exactly where they were.
	_part(root, Vector3(1.5, 0.10, 2.4), Vector3(0.0, 0.22, -0.15), trim)     # cabin floor
	# Walls run from the new floor to the belt line — extended DOWN by the same 0.13, not moved, or a
	# gap opens along the sill and you can see through the car's side into the cabin.
	_part(root, Vector3(0.07, 0.78, 2.1), Vector3(-0.765, 0.66, -0.15), paint)    # right wall (solid)
	_part(root, Vector3(0.07, 0.78, 0.48), Vector3(0.765, 0.66, -0.99), paint)    # left wall behind the door
	_part(root, Vector3(0.07, 0.78, 0.40), Vector3(0.765, 0.66, 0.75), paint)     # left wall ahead of the door
	for sx in [-1.0, 1.0]:   # window-band pillars: belt line (1.05) up to the raised roof (1.40)
		_part(root, Vector3(0.07, 0.35, 0.14), Vector3(0.765 * sx, 1.225, -1.15), trim)
		_part(root, Vector3(0.07, 0.35, 0.14), Vector3(0.765 * sx, 1.225, 0.88), trim)
	# Roof raised 0.145 to 1.445 (underside CAR_ROOF_Y = 1.40). With the sunken cushion at 0.45 that
	# is 0.95 m of headroom — a real sedan's figure, against the ~0.86 m sitting height of a 1.65 m
	# humanoid (sitting height is ~0.52x stature; the 0.79 m this was first sized to was simply
	# wrong, and SCALETEST failed it). Overall height 1.49 m on a 4 m body is a normal sedan.
	_part(root, Vector3(1.6, 0.09, 2.2), Vector3(0.0, 1.445, -0.15), paint)   # roof
	# Glass follows the roof: same sill, same rake, re-cut so the top edge still meets the roofline.
	var shield := _part(root, Vector3(1.44, 0.762, 0.05), Vector3(0.0, 1.064, 1.02), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-28.0)   # raked back toward the roof
	var rear_glass := _part(root, Vector3(1.44, 0.689, 0.05), Vector3(0.0, 1.102, -1.24), glass)
	rear_glass.rotation.x = deg_to_rad(30.0)
	# interior — dash, steering wheel, two seats, the SeatMarker
	# Dash + wheel drop with the floor, or the driver's knees sit inside the dash block.
	_part(root, Vector3(1.40, 0.22, 0.35), Vector3(0.0, 0.73, 0.72), trim)    # dash block
	var wheel := GShapes.cylinder(0.17, 0.17, 0.05, 20)
	GShapes.set_material(wheel, tire)
	wheel.position = Vector3(0.38, 0.82, 0.50)
	wheel.rotation.x = deg_to_rad(65.0)   # tilted toward the driver
	root.add_child(wheel)
	for sx in [-1.0, 1.0]:
		# 0.18 thick, centred 0.36: spans the floor top (0.27) to SEAT_TOP (0.45) exactly. Thickened
		# rather than re-centred so it rests ON the sunken floor — at the old 0.16 it hovered 2 cm
		# above it, which reads as a floating seat from the open door.
		_part(root, Vector3(0.60, 0.18, 0.55), Vector3(0.38 * sx, 0.36, -0.15), cloth)          # cushion (top = SEAT_TOP)
		var back := _part(root, Vector3(0.60, 0.55, 0.12), Vector3(0.38 * sx, 0.69, -0.47), cloth)
		back.rotation.x = deg_to_rad(-8.0)                                                       # recline
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.38, SEAT_TOP, -0.15)   # driver cushion top — hips rest here
	_cabin_headroom = CAR_ROOF_Y - SEAT_TOP                  # the sedan HAS a roof: 0.805 m of column
	root.add_child(_seat_marker)
	# lights (emissive fills, NOT OmniLights — no light budget spent on cars)
	var head_mat := GSurf.emissive(Color(1.0, 0.95, 0.75), 1.4)
	var tail_mat := GSurf.emissive(Color(0.9, 0.10, 0.08), 1.4)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.28, 0.12, 0.06), Vector3(0.48 * sx, 0.62, 1.96), head_mat)
		_part(root, Vector3(0.25, 0.10, 0.06), Vector3(0.52 * sx, 0.72, -1.99), tail_mat)
	# wheels — cylinders lying on their sides (rotation.z=PI/2 -> local +Y is the axle). The 2 FRONT
	# wheels (z = +1.25) ride under a "WheelPivot" Node3D that carries the steer yaw; all 4 are kept
	# in _wheels and spun about their axle in the physics tick (2.2). WHEEL_RADIUS mirrors the 0.32 r.
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.UP
	for wp in [Vector3(0.78, 0.32, 1.25), Vector3(-0.78, 0.32, 1.25), Vector3(0.78, 0.32, -1.25), Vector3(-0.78, 0.32, -1.25)]:
		var wh := GShapes.cylinder(WHEEL_RADIUS, WHEEL_RADIUS, 0.24, 18)
		GShapes.set_material(wh, tire)
		wh.rotation.z = PI * 0.5
		if wp.z > 0.0:   # front axle -> steerable pivot; the wheel sits at pivot-local origin
			var pivot := Node3D.new()
			pivot.name = "WheelPivot"
			pivot.position = wp
			root.add_child(pivot)
			wh.position = Vector3.ZERO   # overwrite cylinder()'s base lift; the pivot holds the spot
			pivot.add_child(wh)
			_steer_pivots.append(pivot)
		else:
			wh.position = wp
			root.add_child(wh)
		_wheels.append(wh)
	# the driver-side DOOR — hinge pivot at the opening's FRONT edge, leaf swings outward (+X)
	_door_pivot = Node3D.new()
	_door_pivot.name = "DoorPivot"
	# Hinges at the sill, which moved down with the floor — the leaf spans the same 0.27..1.05 as the
	# walls it sits flush with, so an open door still fills its opening.
	_door_pivot.position = Vector3(0.795, 0.27, 0.55)
	root.add_child(_door_pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	_door_pivot.add_child(leaf)
	var leaf_mi := GShapes.box(Vector3(0.07, 0.78, 1.30))
	GShapes.set_material(leaf_mi, paint)
	leaf_mi.position = Vector3(0.0, 0.39, -0.65)
	leaf.add_child(leaf_mi)
	var handle := GShapes.box(Vector3(0.04, 0.05, 0.16))
	GShapes.set_material(handle, trim)
	handle.position = Vector3(0.06, 0.63, -1.05)
	leaf.add_child(handle)
	_door_body = StaticBody3D.new()
	_door_body.name = "DoorBody"
	_door_body.collision_layer = 1
	var dcs := CollisionShape3D.new()
	var dbs := BoxShape3D.new()
	dbs.size = Vector3(0.07, 0.78, 1.30)     # matches the leaf mesh above — collider and paint agree
	dcs.shape = dbs
	dcs.position = Vector3(0.0, 0.39, -0.65)
	_door_body.add_child(dcs)
	leaf.add_child(_door_body)
	_door_shape = dcs
	add_collision_exception_with(_door_body)   # the car must never move_and_slide against its own door
	_board_local = Vector3(1.45, 0.0, -0.15)   # on the ground just outside the open door
	return _world_aabb(root)


# The parametric TANK: hull box + sloped glacis (ramp wedge) + dark track skirts low on the
# sides + a rotating-look turret group (ring cylinder + box) + a thin long barrel forward +Z.
# The turret is grouped under one "Turret" Node3D so a later wave can aim it — v1 is COSMETIC
# (no aiming). No door, no SeatMarker: tank boarding is the Wave-1 swap-in (driver hidden);
# hatch choreography is OUT OF SCOPE v1. Grounded (base y=0), forward +Z.
func _build_parametric_tank(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, TANK_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.7, "metal": 0.3, "bump": 0.0, "tile": 5.0})
	var track := GSurf.surface({"color": [0.09, 0.09, 0.10], "rough": 0.95, "metal": 0.1, "bump": 0.0, "tile": 4.0})
	var root := Node3D.new()
	root.name = "TankBody"
	add_child(root)
	_visual = root
	# track skirts — dark boxes LOW on the sides (they read as the running gear)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.60, 0.55, 5.0), Vector3(0.95 * sx, 0.35, 0.0), track)
	# hull slab between/above the tracks (top at y 1.15)
	_part(root, Vector3(1.9, 0.60, 4.4), Vector3(0.0, 0.85, -0.20), paint)
	# sloped GLACIS: GShapes.ramp rises along +X; rotation.y = +90° maps +X -> -Z (basis rotation:
	# x' = (cos90, 0, -sin90) = -Z), so the slope rises toward -Z = up toward the hull top, with
	# the low edge at +Z = the nose. Width (pre-rotation Z) becomes the X span.
	var glacis := GShapes.ramp(0.9, 0.55, 1.9)
	GShapes.set_material(glacis, paint)
	glacis.position = Vector3(0.0, 0.875, 2.30)   # centre: y 0.6..1.15, z 1.85..2.75
	glacis.rotation.y = PI * 0.5
	root.add_child(glacis)
	# rear plate
	_part(root, Vector3(1.9, 0.35, 0.30), Vector3(0.0, 0.70, -2.35), paint)
	# TURRET group — ring cylinder + turret box + barrel, one pivot for future aiming
	var turret := Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0.0, 1.15, -0.30)   # sits on the hull top
	root.add_child(turret)
	var ring := GShapes.cylinder(0.85, 0.75, 0.22, 20)
	GShapes.set_material(ring, paint)
	ring.position = Vector3(0.0, 0.11, 0.0)   # centre-positioned (overwrites base-lift; _part idiom)
	turret.add_child(ring)
	var tbox := GShapes.box(Vector3(1.35, 0.50, 1.70))
	GShapes.set_material(tbox, paint)
	tbox.position = Vector3(0.0, 0.47, -0.05)
	turret.add_child(tbox)
	# barrel — thin long cylinder FORWARD +Z: rotation.x = +90° maps the cylinder's +Y axis to +Z
	# ((0,1,0) -> (0, cos90, sin90) = (0,0,1)), so its length lies along the heading.
	var barrel := GShapes.cylinder(0.07, 0.06, 2.3, 12)
	GShapes.set_material(barrel, track)
	barrel.position = Vector3(0.0, 0.42, 1.85)   # turret-local: from the turret face out past the nose
	barrel.rotation.x = PI * 0.5
	turret.add_child(barrel)
	return _world_aabb(root)


# The parametric BOAT: box hull with a V-keel wedge + raked bow ramp + deck + small fore cabin +
# raked windshield + open cockpit seat with a "SeatMarker". No door — boarding is the step-in
# choreography. Grounded at base y=0 (the WATER ride puts the waterline partway up the keel).
func _build_parametric_boat(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, BOAT_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.3, "metal": 0.1, "bump": 0.0, "tile": 5.0})
	var deck_mat := GSurf.surface({"color": [0.55, 0.42, 0.28], "rough": 0.8, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "BoatBody"
	add_child(root)
	_visual = root
	# hull slab (freeboard) + V-KEEL: a wedge flipped upside down (rotation.z = PI turns the
	# gable peak downward), so the ridge line runs along Z at y=0 — the keel.
	_part(root, Vector3(1.9, 0.65, 4.4), Vector3(0.0, 0.50, -0.30), paint)
	var keel := GShapes.wedge(Vector3(1.9, 0.35, 4.4))
	GShapes.set_material(keel, paint)
	keel.position = Vector3(0.0, 0.18, -0.30)   # centre: peak (keel) at ~y 0, merging into the hull
	keel.rotation.z = PI
	root.add_child(keel)
	# raked BOW: same ramp-rotation trace as the tank glacis (rotation.y = +90° -> rises toward -Z),
	# so the low edge points forward at +Z — the nose — and the top meets the deck.
	var bow := GShapes.ramp(1.3, 0.60, 1.9)
	GShapes.set_material(bow, paint)
	bow.position = Vector3(0.0, 0.55, 2.20)
	bow.rotation.y = PI * 0.5
	root.add_child(bow)
	# deck + gunwale rails
	_part(root, Vector3(1.7, 0.10, 4.2), Vector3(0.0, 0.88, -0.35), deck_mat)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.08, 0.25, 4.2), Vector3(0.88 * sx, 1.00, -0.35), paint)
	# small FORE cabin (cuddy) + windshield raked back toward the cockpit
	_part(root, Vector3(1.5, 0.70, 1.5), Vector3(0.0, 1.25, 1.00), paint)
	var shield := _part(root, Vector3(1.3, 0.50, 0.05), Vector3(0.0, 1.62, 0.15), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-22.0)
	# helm console + cockpit seat + SeatMarker
	_part(root, Vector3(0.9, 0.45, 0.35), Vector3(0.0, 1.10, 0.28), trim)
	_part(root, Vector3(0.60, 0.16, 0.55), Vector3(0.0, 1.00, -0.60), cloth)          # cushion
	var back := _part(root, Vector3(0.60, 0.50, 0.12), Vector3(0.0, 1.30, -0.92), cloth)
	back.rotation.x = deg_to_rad(-8.0)
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.0, 1.08, -0.60)   # cushion top — hips rest here
	root.add_child(_seat_marker)
	_board_local = Vector3(1.35, 0.0, -0.60)   # step in beside the cockpit
	return _world_aabb(root)


# The parametric PLANE: tapered cylinder fuselage (capsule-ish, fat nose / thin tail after the
# +90° X rotation maps the cylinder's +Y to +Z), thin wide straight wings, tailplane + fin, a
# cosmetic "PropDisc" nose spinner (spins while driving), fixed landing gear, and an open
# cockpit seat with a "SeatMarker". No door — step-in boarding. Grounded (wheels at y=0).
func _build_parametric_plane(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, PLANE_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.35, "metal": 0.45, "bump": 0.0, "tile": 5.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "PlaneBody"
	add_child(root)
	_visual = root
	# fuselage — cylinder axis +Y; rotation.x = +90° maps +Y -> +Z, so top_r (0.5) becomes the
	# NOSE radius at +Z and bottom_r (0.25) the tapering tail at -Z.
	var fus := GShapes.cylinder(0.25, 0.50, 6.2, 16)
	GShapes.set_material(fus, paint)
	fus.position = Vector3(0.0, 1.10, -0.10)   # centre: z -3.2 .. 3.0
	fus.rotation.x = PI * 0.5
	root.add_child(fus)
	# cosmetic PROP DISC on the nose (same axis trace as the fuselage) — spun in _physics_process
	# about its LOCAL +Y (the cylinder axis, = world +Z after the rotation).
	_prop = GShapes.cylinder(0.95, 0.95, 0.06, 24)
	GShapes.set_material(_prop, trim)
	_prop.name = "PropDisc"
	_prop.position = Vector3(0.0, 1.10, 3.10)
	_prop.rotation.x = PI * 0.5
	root.add_child(_prop)
	# straight wings + tailplane + fin (thin boxes)
	_part(root, Vector3(7.4, 0.12, 1.5), Vector3(0.0, 1.28, 0.50), paint)     # main wings
	_part(root, Vector3(2.8, 0.10, 0.9), Vector3(0.0, 1.35, -2.90), paint)    # tailplane
	_part(root, Vector3(0.12, 1.05, 1.0), Vector3(0.0, 1.90, -3.00), paint)   # vertical fin
	# open cockpit — windshield, seat, SeatMarker
	var shield := _part(root, Vector3(0.9, 0.40, 0.05), Vector3(0.0, 1.85, 1.35), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-30.0)
	_part(root, Vector3(0.55, 0.14, 0.50), Vector3(0.0, 1.55, 0.90), cloth)   # cushion
	_part(root, Vector3(0.55, 0.45, 0.10), Vector3(0.0, 1.80, 0.60), cloth)   # seat back
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.0, 1.62, 0.90)
	root.add_child(_seat_marker)
	# fixed landing gear — two main struts + wheels under the wing, one tail wheel. Wheel
	# cylinders lie on their sides (rotation.z = 90° -> local +Y is the axle), bottoms at y=0.
	# Registered in _wheels so they roll while taxiing (2.2); no steer pivots (rudder-steered plane).
	_wheels = []
	_steer_pivots = []
	_wheel_axle = Vector3.UP
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.08, 0.50, 0.08), Vector3(0.90 * sx, 0.42, 0.90), trim)
		var wh := GShapes.cylinder(0.22, 0.22, 0.15, 14)
		GShapes.set_material(wh, tire)
		wh.position = Vector3(0.90 * sx, 0.22, 0.90)
		wh.rotation.z = PI * 0.5
		root.add_child(wh)
		_wheels.append(wh)
	var tw := GShapes.cylinder(0.14, 0.14, 0.12, 12)
	GShapes.set_material(tw, tire)
	tw.position = Vector3(0.0, 0.15, -2.90)
	tw.rotation.z = PI * 0.5
	root.add_child(tw)
	_wheels.append(tw)
	_board_local = Vector3(1.30, 0.0, 0.90)   # step in beside the cockpit, inside the wing span
	return _world_aabb(root)


# One placed box part: GShapes.box + GSurf material, positioned by its CENTRE (BoxMesh is
# origin-centred; overwriting .position discards box()'s base-at-y=0 lift on purpose).
func _part(parent: Node3D, size: Vector3, center: Vector3, mat: Material) -> MeshInstance3D:
	var mi := GShapes.box(size)
	mi.position = center
	GShapes.set_material(mi, mat)
	parent.add_child(mi)
	return mi


func _spec_color(spec: Dictionary, fallback: Color) -> Color:
	var c = spec.get("color", null)
	if c is Array and (c as Array).size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return fallback


func _glass_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.75, 0.85, 0.32)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.05
	m.metallic = 0.4
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ---------------- per-tick ----------------

# A persistent wild MOUNT renders at ANY range (no streaming cull, unlike the cell-streamed populate
# crowd), so a far grazing animal shows as a speck against the sky/horizon once the player is up in a
# plane ("animals in the sky"). Cull TIGHT while the player flies so far mounts can't dot the horizon;
# stay GENEROUS on the ground so exploring still shows wildlife around you. It reappears as you near it
# (taming still works) and the crowd right around you is unchanged either way.
const MOUNT_CULL_GROUND := 150.0            # on foot / ground vehicle: show wildlife around you
const MOUNT_AIR_MAX := 75.0                 # while flying: never show a mount beyond this
const MOUNT_AIR_MIN_DROP := 0.40            # ...nor one less than ~22° BELOW the player's horizon (that band = "in the sky")
var _cull_t := 0.0                          # throttle for the cull check (visibility is cheap)


func _physics_process(delta: float) -> void:
	_time += delta
	if _state == S_DRIVING:
		_drive(delta)
		if _prop != null:
			_prop.rotate_object_local(Vector3.UP, PROP_SPIN * delta)   # cosmetic — local +Y = the disc axis
		_update_gait()
		_update_label()
		_update_mount_cull(delta)
		return
	# PARKED: a world can leave several rides standing around (a car, a plane, a couple of boats is
	# typical) and EVERY one of them used to run the full per-frame body below while
	# nobody was aboard — measured as 5 of the 11 nodes ticking each frame, on a single-threaded web
	# build where script time is the framerate ceiling. Nothing here is time-critical when parked: the
	# ground snap only matters as terrain streams in under the vehicle, and the label/gait/cull are
	# cosmetic. Run them ~10x/second instead of ~60x. Driving is untouched — it takes the branch above
	# at full rate, so handling and feel are identical.
	# A NETWORK peer is riding this. netsync places it every frame from their transform, so the
	# parked path below — whose ground snap would drag it back down to the terrain — must not run.
	# Same reasoning as peer_body's mask-0 AnimatableBody3D: network-driven, never world-pushed.
	if _remote_rider != null and is_instance_valid(_remote_rider):
		return
	_park_t += delta
	if _park_t < 0.1:
		return
	_snap_to_ground(_park_t)   # pass the ACCUMULATED delta so the snap moves the same distance per second
	_update_gait()
	_update_label()
	_update_mount_cull(_park_t)
	_park_t = 0.0


# Hide a distant wild mount so it can't dot the sky/horizon while the player flies. Only mounts
# (creatures) are culled — cars/planes/boats stay visible so a parked airfield reads normally. A
# RIDDEN mount is never hidden. Distance is the cheap hull-xz measure; the check runs ~4x/second.
func _update_mount_cull(delta: float) -> void:
	if not _is_mount or driving:
		if not visible:
			visible = true
		return
	if player_ref == null or not is_instance_valid(player_ref):
		return
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = 0.25
	var pg := player_ref.global_position
	var palt := pg.y - (terrain.height(pg.x, pg.z) if terrain != null else 0.0)
	var horiz := _hull_xz_distance(pg)
	if palt <= 5.0:
		# on the ground / ground vehicle: generous radius so exploring shows wildlife around you
		visible = horiz <= MOUNT_CULL_GROUND
		return
	# AIRBORNE: show a mount ONLY when it sits well BELOW the player's horizon (inside the ground-view
	# cone) and is close — never one near/at the horizon line, which is exactly what reads as an "animal
	# in the sky". drop = how far the mount is below the player; the ratio is its angle under the horizon.
	var drop := pg.y - global_position.y
	visible = horiz <= MOUNT_AIR_MAX and drop >= horiz * MOUNT_AIR_MIN_DROP


# Integrate one drive tick from the shared input vector main.gd feeds via drive_input().
func _drive(delta: float) -> void:
	var p: Dictionary = PROFILES[profile]
	if _airborne:
		_drive_air(delta)
	else:
		_drive_ground(delta, p)
	_update_wheels(delta)       # roll/steer parametric or modeled wheels (2.2)
	_update_ride_motion(delta)  # rider bob + body rock while a mount walks (2.4)
	# keep the driver ATTACHED: chunk streaming (_player_cell) and quest reach_area notifications
	# all read player.global_position, so parking the player on the boardable keeps the whole
	# ring/quest pipeline fed while driving. A SEATED/RIDING driver rides its marker (visible);
	# the Wave-1 hidden fallback rides the body origin — identical streaming semantics either way.
	_track_driver()


# Ground gait — cars/tanks/boats/taxiing planes/walking mounts. Boats replace the terrain target
# with the water level inside _rest_y (via _snap_to_ground); flyers hand off to _drive_air once
# past takeoff speed with the throttle held.
func _drive_ground(delta: float, p: Dictionary) -> void:
	var max_speed := float(p["max_speed"])
	# POINT-AND-GO (the on-screen joystick, via drive_input_world): turn the body TOWARD the commanded
	# heading at a snappy, SPEED-INDEPENDENT rate, then drive along the nose. The legacy path below
	# scales steering by speed, so a car/mount had almost no turn authority at low speed and felt
	# "locked into a direction" (the #1 driving complaint). _input.x here is the signed heading error
	# from drive_input_world; driving it toward zero points the body where the stick points, at any speed.
	if _world_drive:
		var wtarget := -_input.y * max_speed
		var wrate := float(p["accel"]) if absf(wtarget) > absf(_speed) else float(p["brake"])
		_speed = move_toward(_speed, wtarget, wrate * delta)
		var wturn := float(p["turn_rate"]) * (1.0 if bool(p.get("steer_fixed", false)) else 1.7)
		rotation.y += -_input.x * wturn * delta
		velocity = global_transform.basis.z * _speed
		velocity.y = 0.0
		move_and_slide()
		_snap_to_ground(delta)
		if bool(p.get("fly", false)) and _speed > float(p.get("takeoff", 9.0)) and -_input.y > 0.4:
			_airborne = true
			_pitch = deg_to_rad(10.0)
		return
	var target := -_input.y * max_speed   # screen-up / W = forward (same sign as _keyboard_vec)
	var rate := float(p["accel"]) if absf(target) > absf(_speed) else float(p["brake"])
	_speed = move_toward(_speed, target, rate * delta)
	# steering: scaled by speed (no pirouette when parked, flips in reverse — like a real car)
	# EXCEPT steer_fixed profiles (tank): tracks TURN IN PLACE, full authority at zero speed.
	# steer_floor (boat/plane, 2.3): keep a minimum turn authority while spooling up so the stick
	# answers below top speed — the magnitude is floored, the reverse sign flip preserved.
	var sf := 1.0
	if not bool(p.get("steer_fixed", false)):
		var frac := clampf(_speed / max_speed, -1.0, 1.0)
		var mag := maxf(absf(frac), float(p.get("steer_floor", 0.0)))
		sf = mag if _speed >= 0.0 else -mag
	rotation.y += -_input.x * float(p["turn_rate"]) * sf * delta
	# forward = +basis.z: library/Meshy models FACE +Z in this stack (TrafficCar's atan2(dir.x,
	# dir.z) and the player's look_at(pos - dir) both point +Z along the heading).
	velocity = global_transform.basis.z * _speed
	velocity.y = 0.0
	move_and_slide()              # buildings/walls (layer 1) stop it; slides along them
	_snap_to_ground(delta)
	# TAKEOFF (plane + dragon): past takeoff speed with the throttle still held, pitch up and fly.
	# The initial +10° pitch clears the GROUNDED_H band before the landing check can re-trigger
	# (landing requires DESCENDING: _pitch <= 0).
	if bool(p.get("fly", false)) and _speed > float(p.get("takeoff", 9.0)) and -_input.y > 0.4:
		_airborne = true
		_pitch = deg_to_rad(10.0)


# Arcade FLIGHT (plane + dragon, shared envelope): input.y = pitch, input.x = bank+yaw, speed
# runs toward SPEED_MAX on implicit cruise throttle. Soft ceiling at ALT_MAX above the LOCAL
# terrain; descending into the GROUNDED_H band lands (back to ground steering).
func _drive_air(delta: float) -> void:
	# LAND REQUEST (USE pressed mid-air): override the stick to a steady braked descent, then dismount
	# on touchdown below — a mid-air USE can no longer strand the rider up in the sky.
	if _land_req:
		_input = Vector2(0.0, 0.9)   # +y -> nose DOWN -> come down; no yaw
		_air_thr = 0.35
	# THROTTLE: ease speed toward SPEED_MAX * _air_thr (drive_input_world sets _air_thr from the stick),
	# so backing off / pulling the stick back genuinely SLOWS the flyer. A 0.2 floor keeps minimum
	# airspeed so it can't stall and drop. The raw drive_input path leaves _air_thr at cruise 1.0.
	_speed = move_toward(_speed, SPEED_MAX * clampf(_air_thr, 0.2, 1.0), AIR_ACCEL * delta)
	var gy := _ground_h()
	var rel := global_position.y - gy
	# PITCH sign: screen-up / W gives _input.y = -1 (the _keyboard_vec convention), and
	# -(-1) * PITCH_MAX = +35° = CLIMB — so holding W through takeoff keeps climbing.
	var tp := -_input.y * deg_to_rad(PITCH_MAX_DEG)
	# soft ceiling: inside the CEIL_BAND below ALT_MAX the allowed climb fades to 0, and ABOVE
	# ALT_MAX it goes negative — pitch is forced down approaching/at the lid.
	var allowed := clampf((ALT_MAX - rel) / CEIL_BAND, -1.0, 1.0) * deg_to_rad(PITCH_MAX_DEG)
	tp = minf(tp, allowed)
	_pitch = move_toward(_pitch, tp, PITCH_RATE * delta)
	# BANKED TURN: same steer sign as the ground path (A / x=-1 -> +yaw); not speed-scaled.
	rotation.y += -_input.x * AIR_TURN * delta
	# visual ROLL sign: rotation about local +Z by -θ dips the +X side ((1,0,0) -> (cosθ, -sinθ, 0));
	# steering toward +X (input.x = -1, yaw+) should dip +X, so roll target = input.x * ROLL_MAX
	# (input.x = -1 -> -40° -> +X wing down = banking INTO the turn).
	_roll = move_toward(_roll, _input.x * deg_to_rad(ROLL_MAX_DEG), ROLL_RATE * delta)
	if _visual != null:
		# Attitude = pitch(about X)/roll(about Z) COMPOSED OVER the fuselage orient, so a model whose
		# nose was authored along X (orient yaw != 0) climbs by PITCHING, not barrel-rolling. Rebuild the
		# whole basis (preserving scale) rather than set rotation.x/z, so the orient is applied UNDER the
		# attitude. Nose is +Z after orient; +θ about X pitches +Z down, so climb (+_pitch) needs -_pitch.
		_visual.transform.basis = (Basis.from_euler(Vector3(-_pitch, 0.0, _roll)) * Basis(Vector3.UP, _flyer_orient_yaw)).scaled(Vector3.ONE * _flyer_scale)
	# kinematics: forward along the yaw heading, vertical from the pitch angle
	var _vy := _speed * sin(_pitch)
	if _pitch < 0.0:
		_vy *= DESCENT_GAIN   # DESCENDING (nose down): sink faster than the low braked landing airspeed alone allows. Guarded by _pitch<0 so level flight, climb, ceiling hold and takeoff (+10°) are byte-for-byte unchanged.
	velocity = global_transform.basis.z * (_speed * cos(_pitch)) + Vector3.UP * _vy
	move_and_slide()   # buildings still stop a low flyer; slides along them
	# hard envelope clamp (the soft ceiling handles the approach; this catches terrain rising fast)
	global_position.y = clampf(global_position.y, gy + GROUND_LIFT, gy + ALT_MAX)
	rel = global_position.y - _ground_h()
	if rel < GROUNDED_H and _pitch <= 0.0:
		_land()
		if _land_req:
			_land_req = false
			exit()   # now grounded -> the airborne guard passes and the dismount completes


func _land() -> void:
	_airborne = false
	_pitch = 0.0
	_roll = 0.0
	if _visual != null:
		_visual.transform.basis = Basis(Vector3.UP, _flyer_orient_yaw).scaled(Vector3.ONE * _flyer_scale)   # level attitude, fuselage orient kept
	# _snap_to_ground lerps the last half-metre down at SNAP_RATE — a soft touchdown, no pop


# WHEELS THAT MOVE (2.2): spin each registered wheel about its axle by rolling distance / radius,
# and slew the front steer pivots toward the current steer input. Parametric wheels spin about
# local +Y (rotation.z=PI/2 laid them on their side); modeled GLB wheels about local +X. Empty
# lists (mounts, wheelless fused GLBs) -> no-op.
func _update_wheels(delta: float) -> void:
	if not _wheels.is_empty():
		var spin := (_speed / _wheel_radius) * delta   # signed: reverses when backing up
		for w in _wheels:
			if w != null and is_instance_valid(w):
				w.rotate_object_local(_wheel_axle, spin)
	if not _steer_pivots.is_empty():
		# _input.x is the steer (A/x=-1 turns the body +yaw); match the front wheels to it.
		var target := -clampf(_input.x, -1.0, 1.0) * WHEEL_STEER_MAX
		for sp in _steer_pivots:
			if sp != null and is_instance_valid(sp):
				sp.rotation.y = move_toward(sp.rotation.y, target, WHEEL_STEER_SLEW * delta)


# RIDE-BOB (2.4): while a MOUNT walks, add a subtle rider bounce (fed to _track_driver via _ride_bob,
# so GPose.ride is never disturbed) plus a +/- body rock so a subtle/absent gait clip still reads as
# motion. Airborne (dragon) leaves _visual.rotation.x to the flight path; a stopped mount settles
# level. Non-mounts and vehicles are untouched (_ride_bob stays 0).
func _update_ride_motion(delta: float) -> void:
	_ride_bob = 0.0
	if not _is_mount or _airborne:
		return
	if _state == S_DRIVING and absf(_speed) > RIDE_MOVE_MIN:
		var phase := _time * (1.0 + 0.30 * absf(_speed)) * TAU   # ~1 Hz walk .. ~4 Hz gallop
		_ride_bob = RIDE_BOB_AMP * absf(sin(phase))              # rider bounce (always >= 0)
		if _visual != null:
			_visual.rotation.x = deg_to_rad(RIDE_PITCH_DEG) * sin(phase)   # +/- body rock
	elif _visual != null and not is_zero_approx(_visual.rotation.x):
		_visual.rotation.x = move_toward(_visual.rotation.x, 0.0, 4.0 * delta)   # settle level when idle


# Park the driver on the boardable for this tick: its marker (posed, visible — SeatMarker for
# seats, MountMarker for mounts) or the origin (hidden fallback).
# ── REMOTE RIDER (multiplayer) ────────────────────────────────────────────────────────────────
## A NETWORK peer riding this vehicle ON OUR SCREEN.
##
## Deliberately NOT enter(): that runs the drive state machine, emits drive_state_changed — which
## swings the LOCAL camera and rebinds input — and plays the boarding SFX. This client is a
## SPECTATOR of somebody else's ride and must do none of those. What it DOES share is the seating
## math below, so a peer sits exactly where the local driver would.
var _remote_rider: Node3D = null
var _remote_seated := false
var _remote_seat_y_off := 0.0


func set_remote_rider(rider: Node3D) -> void:
	if _remote_rider == rider:
		return
	clear_remote_rider()
	_remote_rider = rider
	if rider != null and is_instance_valid(rider):
		_seat_remote_rider()


func clear_remote_rider() -> void:
	var r := _remote_rider
	_remote_rider = null
	_remote_seated = false
	_remote_seat_y_off = 0.0
	if r != null and is_instance_valid(r):
		GPose.stand(r)   # undo the astride/seated pose or they walk around folded
		r.visible = true


## Mirror of _seat_driver for a rider we do not simulate. Same measurements, same thresholds, same
## closed-cab clearance rule and the same always-visible contract for mounts — a peer must not sit
## differently from the way the local player sits on the identical vehicle.
func _seat_remote_rider() -> void:
	var d := _remote_rider
	if d == null or not is_instance_valid(d):
		return
	var dh := GPose.char_height(d)
	if dh < 0.5:
		dh = _world_aabb(d).size.y
	if dh < 0.5:
		dh = 1.7
	var hips := GPose.hips_height(d)
	if hips <= 0.0:
		hips = HIP_RATIO * dh
	if _is_mount:
		_remote_seat_y_off = 0.12 - hips
		_remote_seated = GPose.ride(d)
	else:
		_remote_seat_y_off = 0.06 - hips
		_remote_seated = GPose.sit(d)
		if _remote_seated and _cabin_headroom < INF and (dh - hips) > _cabin_headroom:
			_remote_seated = false
			GPose.stand(d)
	if not _remote_seated:
		if _is_mount:
			_remote_seat_y_off = 0.0   # a mount's rider is ALWAYS visible — perch instead
		else:
			d.visible = false
			_remote_seat_y_off = 0.0


## Park this vehicle UNDER a rider netsync has already placed. The INVERSE of _track_driver: there
## the vehicle is authoritative and moves the driver; here the rider came off the wire, so the
## vehicle moves under them. Only one of the two is ever authoritative, so they cannot fight.
func place_under_remote_rider(rider_pos: Vector3, yaw: float) -> void:
	rotation.y = yaw
	var marker := _mount_marker if _is_mount else _seat_marker
	if marker == null or not is_instance_valid(marker) or not (_remote_seated or _is_mount):
		global_position = rider_pos
		return
	# The marker's offset from our origin is rigid. Read it AFTER the yaw is set, so it is already
	# rotated into world space, then subtract it (and the hip drop) from where the rider stands.
	var off := marker.global_position - global_position
	global_position = rider_pos - off - Vector3(0.0, _remote_seat_y_off, 0.0)


func _track_driver() -> void:
	if _driver == null or not is_instance_valid(_driver):
		return
	var marker := _mount_marker if _is_mount else _seat_marker
	# Mounts park the rider on the marker even when the pose failed (visible
	# perch); cabin vehicles only when actually seated (else hidden at origin).
	if marker != null and (_seated or _is_mount):
		# _ride_bob (2.4) is a small vertical bounce added while a mount walks — it moves the MARKER,
		# never the pose, so GPose.ride stays astride (0.0 for vehicles and a parked/idle mount).
		_driver.global_position = marker.global_position + Vector3(0.0, _seat_y_off + _ride_bob, 0.0)
		_driver.global_rotation = Vector3(0.0, global_rotation.y, 0.0)   # face where the body faces
	else:
		_driver.global_position = global_position
	_driver.velocity = Vector3.ZERO


# DEBUG (web console): window.gogiRotVeh(deg) sets the active vehicle model's yaw so I can find the
# correct forward-alignment offset empirically for the AI-generated meshes, then bake it.
func debug_yaw_model(deg: float) -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.rotation.y = deg_to_rad(deg)
		print("GOGI_VEH_YAW=%.0f profile=%s ax=%.2f az=%.2f" % [deg, profile, _body_ab.size.x, _body_ab.size.z])


# Rest-height target for the ground snap. Ground profiles: GTerrain.height(x, z) — the RENDERED-
# SURFACE height (mesh-accurate by contract), so the body hugs the visible ground; flat worlds
# (terrain == null) ride the y=0 slab. WATER profiles (boat) in a world WITH water: the GWater
# level + the pinned bob — maxed with the terrain so a boat driven over ground above the
# waterline beaches on it instead of sinking in; NO water block -> plain terrain (car-like).
func _rest_y() -> float:
	if _has_water and _water_rest:
		# A SEAPLANE (water_rest AND a flyer) can be DITCHED on high land, so it rests on the higher of
		# water/terrain. Without this the idle snap drags a plane dismounted over the island DOWN to sea
		# level, sinking it UNDER the ground it landed on — "the plane vanishes when I get off". A pure
		# BOAT keeps water_level only: maxing with the seabed would let the hull climb the beach as the
		# bottom rises toward shore (it can't drive on land — that stays a wall it stops against).
		if bool(PROFILES.get(profile, {}).get("fly", false)):
			var gyf := terrain.height(global_position.x, global_position.z) if terrain != null else 0.0
			return maxf(water_level, gyf) + BOB_AMP * sin(_time * BOB_HZ)
		return water_level + BOB_AMP * sin(_time * BOB_HZ)
	return _ground_h() + GROUND_LIFT


func _ground_h() -> float:
	var gy := terrain.height(global_position.x, global_position.z) if terrain != null else 0.0
	# WATER-REST vehicles (boat / spec-"water" seaplane) treat the water surface as their floor, so
	# a hull/seaplane over open water rides and LANDS on it instead of the seabed far below (2.3).
	# On the water the floor IS water_level (never the rising seabed, so the boat can't climb the
	# beach). A flying seaplane still references the higher of terrain/water so it clears real ground.
	# Non-water vehicles, and worlds with no water block (_has_water false), are unaffected.
	if _has_water and _water_rest:
		return maxf(gy, water_level) if _airborne else water_level
	# FLYER over water: a plane/dragon (fly profile) that isn't a water-rest craft still treats the water
	# SURFACE as its floor, so a mid-air dismount ditches it ON the water (visible, parked) instead of
	# diving to the seabed far below and vanishing. Over land maxf(gy,water_level)=gy, so it's a no-op.
	if _has_water and bool(PROFILES.get(profile, {}).get("fly", false)):
		return maxf(gy, water_level)
	return gy


# Surface a DISMOUNTED driver stands on at this XZ — MUST mirror the vehicle's own rest surface
# (_ground_h) so a flyer ditched on water (or a boat) drops its pilot onto the WATER next to the parked
# body, never the seabed/gorge-floor far below (which yanks the follow-camera off the plane so it reads
# as "vanished"). Cars/tanks/mounts on land keep raw terrain (water/fly conds false) — slopes unchanged.
func _exit_ground_y(x: float, z: float) -> float:
	var gy := terrain.height(x, z) if terrain != null else 0.0
	if _has_water and (_water_rest or bool(PROFILES.get(profile, {}).get("fly", false))):
		return maxf(gy, water_level)
	return gy


func _snap_to_ground(delta: float) -> void:
	var gy := _rest_y()
	if _snapped:
		global_position.y = lerpf(global_position.y, gy, minf(1.0, SNAP_RATE * delta))
	else:
		global_position.y = gy
		_snapped = true


# Wire (or re-wire) the terrain AFTER the streamer boots — vehicles spawn before ChunkManager
# builds GTerrain. Re-snaps instantly so a parked body doesn't visibly ride up to the new surface.
func set_terrain(t: GTerrain) -> void:
	terrain = t
	# Ground NOW, not on the next _physics_process. Vehicles spawn at y = 0.0 (main.gd) and are
	# lifted onto the surface only by _snap_to_ground inside _physics_process. A game that opens on
	# a title screen holds the world still behind it -> the vehicle's physics tick
	# never runs, so a body left at y = 0.0 sits UNDER any terrain column above 0 for the whole
	# title screen. Setting global_position is not gated by pause, so snap at hand-over; leave
	# _snapped = false so the first LIVE tick re-snaps after nudge_out / set_water refine it.
	if is_inside_tree() and t != null:
		global_position.y = _rest_y()
	_snapped = false


# Wire the world's water level (ChunkManager's `water_level`, read from world.json "water".level —
# the same number GWater.body renders the surface at). Only called for worlds WITH a water block;
# without it boats keep the terrain (car-on-terrain degrade, per the Wave-3 contract).
func set_water(level: float) -> void:
	_has_water = true
	water_level = level
	# Re-ground onto the water surface immediately for the same reason as set_terrain: set_water is
	# wired AFTER set_terrain, so a boat first grounds to the seabed then must lift to water_level.
	# Do it now (pause-safe) instead of waiting for a physics tick the frozen title screen suppresses.
	if is_inside_tree():
		global_position.y = _rest_y()
	_snapped = false


# ---------------- enter / exit (discrete API; choreographed boards wrap them in tweens) ----------------

# USE dispatch from the interaction system: walk up -> board; while driving -> exit.
# Mid-choreography USE is a no-op (this is the exit-mid-enter guard for the player path;
# the hot-reload free path is covered by _exit_tree's force-restore).
func use(driver: CharacterBody3D) -> bool:
	if _state == S_ENTERING or _state == S_EXITING:
		return false   # mid-choreography — the caller may retry shortly (a swallowed press reads as a dead button)
	if driving:
		exit()
	else:
		enter(driver)
	return true


# Swap the player IN. Instant boards (fused-GLB vehicles + the parametric tank): the Wave-1
# swap-in, hide + attach. Choreographed boards (car door / boat+plane step-in / mount): start the
# sequence with the camera switch + input routing (drive_state_changed) at sequence START,
# Wave-1 style; drive_input is ignored until the state machine reaches DRIVING.
func enter(driver: CharacterBody3D) -> void:
	if _state != S_IDLE or driver == null:
		return
	if _remote_rider != null and is_instance_valid(_remote_rider):
		return   # a peer is already riding this one
	driving = true
	_driver = driver
	_speed = 0.0
	_input = Vector2.ZERO
	_world_drive = false
	_air_thr = 1.0
	_land_req = false
	driver.velocity = Vector3.ZERO
	_set_body_collision(driver, true)   # the capsule must not fight the body's box from inside
	if _board == "instant":
		_state = S_DRIVING
		if _seat_marker != null:
			# modeled vehicle with a probed/authored seat (open or hollow cabin): board VISIBLE
			# and seated — _seat_driver poses (GPose.sit) and parks on the marker; a capsule rig
			# degrades to the hide inside it.
			_seat_driver()
		else:
			driver.visible = false      # hidden driver (tank: hatch choreography out of scope v1)
			driver.global_position = global_position
		AudioManager.play_sfx("door")
		drive_state_changed.emit(self, true)
		return
	_state = S_ENTERING
	drive_state_changed.emit(self, true)   # controls locked out from here: main routes input to the
	_set_door_blocking(false)              # body, and drive_input is ignored until _state == S_DRIVING
	_begin_enter_choreo()


# Swap the player OUT. Instant boards: the Wave-1 swap-out. Choreographed boards (while DRIVING):
# stop + run the exit choreography, releasing control (emit false) only when the driver is fully
# restored. Mid-ENTER exits are ignored (guard). AIRBORNE exits are ignored too — the chunk
# movement contract has no gravity, so a mid-air dismount would strand a floating player: land
# first (descend until terrain-relative height < 0.5), then exit. The hot-reload free path is
# restored by _exit_tree (which drops the driver at TERRAIN height, so even a freed-mid-flight
# session leaves them safely grounded).
func exit() -> void:
	if _state != S_DRIVING:
		return
	if _airborne:
		# IMMEDIATE dismount: a mid-air DISMOUNT/USE drops straight down to the surface below and gets off
		# right away. The old braked fly-down could take many seconds over deep gorges/open water (or never
		# reach a touchdown surface), reading as "the plane won't let me off." Snap the flyer just above the
		# ground/water beneath it, level it, then fall through to the normal grounded dismount so the driver
		# is placed safely (over water the swim system floats them to the surface next frame).
		global_position.y = _ground_h() + GROUND_LIFT
		_land()
		_land_req = false
	_speed = 0.0
	_input = Vector2.ZERO
	velocity = Vector3.ZERO
	if _board == "instant":
		driving = false
		_state = S_IDLE
		_seated = false
		var driver := _driver
		_driver = null
		if driver != null and is_instance_valid(driver):
			GPose.stand(driver)   # reverses a visible-seated instant board (no-op if never posed)
			var spot := global_position + global_transform.basis.x.normalized() * float(PROFILES[profile]["exit_side"])
			spot.y = _exit_ground_y(spot.x, spot.z) + 0.1
			_set_body_collision(driver, false)
			driver.global_position = spot
			driver.velocity = Vector3.ZERO
			driver.visible = true
		AudioManager.play_sfx("door")
		drive_state_changed.emit(self, false)
		return
	_state = S_EXITING
	_begin_exit_choreo()


# Fed by main._physics_process while this vehicle is active — the SAME input vector that walks the
# player (no second input path). Ground: x = steer, y = throttle (screen-up negative, like
# _keyboard_vec). Airborne: x = bank+yaw, y = pitch. Ignored (stored but never integrated)
# unless the state machine has reached DRIVING.
func drive_input(v: Vector2) -> void:
	_world_drive = false
	_input = v.normalized() if v.length() > 1.0 else v


# CONTRACT A (camera-relative desired-heading): main.gd feeds a WORLD XZ vector — the direction the
# player wants to go (forward = +Z), length = throttle 0..1. We turn the body toward that heading
# and drive forward, translating it into the SAME internal `_input` (steer, throttle) that
# drive_input feeds — so the ground/air integrators run UNCHANGED and the raw drive_input path (the
# verify harness) is untouched. Ground/water: steer toward atan2(x, z) at the profile turn rate
# (steer_fixed tanks rotate in place — sf=1 there), throttle = length. Airborne: bank+yaw toward the
# heading, hold level (a 2D world vector carries no climb). Near-zero -> COAST (hold heading + speed,
# no reverse, no snap-stop).
func drive_input_world(world_dir: Vector2) -> void:
	_world_drive = true
	var thr := clampf(world_dir.length(), 0.0, 1.0)
	if thr < 0.05:
		if _airborne:
			_air_thr = 0.4          # ease off the stick -> bleed toward a slow cruise (releasing SLOWS you)
			_input = Vector2.ZERO   # wings level
		else:
			# hold current speed (target == _speed) so momentum carries — no forced brake-to-zero
			var ms := float(PROFILES[profile]["max_speed"])
			_input = Vector2(0.0, -clampf(_speed / ms, -1.0, 1.0))
		return
	var want := atan2(world_dir.x, world_dir.y)          # +Z forward -> yaw = atan2(x, z)
	var err := wrapf(want - rotation.y, -PI, PI)
	if _airborne:
		# FLIGHT (no reverse): bank+yaw toward the heading; the SAME 2D stick also works throttle +
		# a gentle climb/descend, so the flyer can be sped up, slowed, and brought down without a
		# second input axis. rotation.y += -_input.x * rate, so a POSITIVE heading error needs _input.x < 0.
		var yaw_cmd := -clampf(err / HEADING_BAND, -1.0, 1.0)
		if absf(err) > REVERSE_ENTER:
			# stick pulled BEHIND the nose ("pull back / down") = SLOW DOWN + descend (arcade brake).
			_air_thr = 0.25
			_input = Vector2(yaw_cmd, 0.9)    # +y -> nose down -> lose altitude (steeper: pull-back now truly points the nose down instead of a shallow ~19°)
		else:
			# stick toward the nose = throttle up; a hard push also climbs a little.
			_air_thr = clampf(0.45 + thr * 0.55, 0.0, 1.0)
			_input = Vector2(yaw_cmd, -clampf((thr - 0.55) * 2.0, 0.0, 1.0) * 0.5)
		return
	# REVERSE vs forward (all ground/water rides + grounded mounts). Latch with hysteresis so the
	# choice can't chatter at the threshold. _drive_ground already integrates a negative _speed and
	# flips the steer sign in reverse for a real-car feel, so here we only pick throttle direction +
	# the steer TARGET (nose-onto-heading when forward, rear-onto-heading when reversing).
	if _rev_latch:
		if absf(err) < REVERSE_EXIT:
			_rev_latch = false
	elif absf(err) > REVERSE_ENTER:
		_rev_latch = true
	if _rev_latch:
		# BACK UP toward `want`: while reversing the nose points AWAY from travel, so the desired
		# facing is want - PI. Steer the nose onto that; +_input.y drives _speed negative = backward.
		var rev_err := wrapf(err - PI, -PI, PI)
		var rsteer := clampf(rev_err / HEADING_BAND, -1.0, 1.0)
		if bool(PROFILES[profile].get("steer_fixed", false)):
			rsteer = -rsteer   # tank turns in place (no reverse sf-flip) — use the forward-frame sign
		_input = Vector2(rsteer, thr)          # "turn and reverse" (rev_err!=0) or "just reverse" (~0)
	else:
		_input = Vector2(-clampf(err / HEADING_BAND, -1.0, 1.0), -thr)   # steer toward heading, forward


# Interaction-registry prompt text, re-read each query. Parked: "Ride <name>" / "Drive <name>".
# While driving (boarding included): "" — NO exit/dismount words anywhere; the USE button still
# exits because interaction routes by kind, not label, and interaction.gd renders no prompt for
# an empty label.
func prompt_label() -> String:
	if driving:
		return ""
	return ("Ride " if _is_mount else "Drive ") + display_name


# ---------------- enter/exit choreography (door / step-in / mount boards) ----------------

# Generalised Wave-2 sequence. Door segments only exist on the car (its _door_pivot); door-less
# boards (boat/plane step-in, mounts) run walk -> pose directly with a single boarding sfx.
func _begin_enter_choreo() -> void:
	_kill_seq()
	var d := _driver
	var beside := to_global(_board_local)   # on the ground beside the opening/cockpit/flank
	_seq = create_tween()
	# 1) door swings open (car only)
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_TIME).set_trans(Tween.TRANS_SINE)
	else:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))   # one boarding thunk for door-less boards
	# 2) the driver visibly walks to beside the seat / saddle
	_seq.tween_property(d, "global_position", beside, WALK_TIME).set_trans(Tween.TRANS_SINE)
	# 3) aboard: snap onto the marker + GPose.sit / GPose.ride (or the Wave-1 hide fallback)
	_seq.tween_callback(_seat_driver)
	# 4) door swings closed (car only) -> driving enabled
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", 0.0, DOOR_TIME).set_trans(Tween.TRANS_SINE)
	_seq.tween_callback(func() -> void:
		_state = S_DRIVING)


func _begin_exit_choreo() -> void:
	_kill_seq()
	var d := _driver
	var spot := global_position + global_transform.basis.x.normalized() * float(PROFILES[profile]["exit_side"])
	spot.y = _exit_ground_y(spot.x, spot.z) + 0.1
	_seq = create_tween()
	# 1) door swings open (car only)
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_TIME).set_trans(Tween.TRANS_SINE)
	# 2) the driver stands (pose restored / unhidden — GPose.stand reverses sit AND ride, same
	#    meta) and visibly steps out/off to exit_side
	_seq.tween_callback(func() -> void:
		_seated = false
		if d != null and is_instance_valid(d):
			GPose.stand(d)
			d.visible = true)
	if d != null and is_instance_valid(d):
		_seq.tween_property(d, "global_position", spot, WALK_TIME).set_trans(Tween.TRANS_SINE)
	# 3) door swings closed (car only) -> driver fully restored, control released
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", 0.0, DOOR_TIME).set_trans(Tween.TRANS_SINE)
	_seq.tween_callback(func() -> void:
		_finish_exit(spot))


# Put the driver aboard: measure the rig's standing height FIRST (the pose changes the AABB),
# drop the character origin so the hips land on the marker, then pose. Seats use GPose.sit
# (hips sink slightly into the cushion); mounts use GPose.ride (astride, hips a touch above the
# back-line so the spread thighs wrap the flanks). A false return (capsule / unrecognized rig):
# cabin vehicles hide the driver (Wave-1 fallback); MOUNTS keep the rider VISIBLE, perched on
# the MountMarker (rider-always-visible contract).
func _seat_driver() -> void:
	var d := _driver
	if d == null or not is_instance_valid(d):
		return
	# Measure the driver the same way main.gd sized it — bones UNIONED WITH THE MESH ENVELOPE. The old
	# bone-span-only read was the same mistake main.gd made: it stops at the head BONE (the neck), so
	# a stylized rig under-read by nearly half and every derived offset below was computed from a
	# height the character does not have. Fall back to the mesh AABB for an unrigged capsule, then to
	# 1.7 as a last resort.
	var dh := GPose.char_height(d)
	if dh < 0.5:
		dh = _world_aabb(d).size.y
	if dh < 0.5:
		dh = 1.7
	# Where this rig's hips actually are, not a ratio of its height. One constant cannot fit both a
	# realistic humanoid (hips at ~0.52 of height) and a KayKit chibi (0.178) — using the realistic
	# figure on a chibi drops it half a metre through the cabin floor.
	var hips := GPose.hips_height(d)
	if hips <= 0.0:
		hips = HIP_RATIO * dh
	if _is_mount:
		_seat_y_off = 0.12 - hips   # astride: hips just above the back-line
		_seated = GPose.ride(d)
	else:
		_seat_y_off = 0.06 - hips   # seated: hips just above the cushion (+0.06 sink)
		_seated = GPose.sit(d)
		# CLOSED-CAB CLEARANCE. Posing succeeded, but posing does not make the driver FIT: what has
		# to clear the roof is the span from the hips to the crown, and on a chibi rig that is 1.36 m
		# against a sedan's 0.95 m. Rather than post a head through the roof — the shipped bug —
		# take the same hidden-driver path an unposeable rig takes. Cabin vehicles have somewhere to
		# hide; mounts do not, which is why this is in the else branch only.
		if _seated and _cabin_headroom < INF and (dh - hips) > _cabin_headroom:
			_seated = false
			GPose.stand(d)   # undo the seated pose we just applied, or it rides hidden AND folded
	if not _seated:
		if _is_mount:
			# CONTRACT: a mount's rider is ALWAYS visible — there is no cabin
			# to hide in, and an invisible rider reads as a riderless horse.
			# Capsule/unposeable rigs PERCH visibly on the MountMarker instead
			# (same graceful degrade as the furniture seat).
			_seat_y_off = 0.0
		else:
			d.visible = false
			_seat_y_off = 0.0
	_track_driver()   # snap onto the marker (or origin) immediately; _drive re-parks every tick


# Final exit bookkeeping — the driver is standing at `spot`, solid, visible; the body is parked.
func _finish_exit(spot: Vector3) -> void:
	var d := _driver
	_driver = null
	_seated = false
	if d != null and is_instance_valid(d):
		_set_body_collision(d, false)
		d.global_position = spot
		d.velocity = Vector3.ZERO
		d.visible = true
	_set_door_blocking(true)   # parked + closed -> the leaf blocks again (no-op without a door)
	driving = false
	_state = S_IDLE
	drive_state_changed.emit(self, false)


# HOT-RELOAD SAFETY NET: main.gd calls exit() then frees rebuilt vehicles — if the free lands
# mid-choreography (exit() mid-ENTER is a guarded no-op), mid-drive, or MID-FLIGHT (exit() while
# airborne is a guarded no-op too), the vehicle-bound tweens die with this node. Restore the
# DRIVER synchronously — pose, visibility, collision, and a position at TERRAIN height — so a
# chat edit can never strand a hidden, posed, collision-less or floating player. (Also covers
# any future non-exit() free path.)
func _exit_tree() -> void:
	if _state == S_IDLE:
		return
	_kill_seq()
	var d := _driver
	_driver = null
	_state = S_IDLE
	driving = false
	_seated = false
	_airborne = false
	_land_req = false
	if d != null and is_instance_valid(d):
		GPose.stand(d)
		_set_body_collision(d, false)
		var spot := global_position + global_transform.basis.x.normalized() * float(PROFILES[profile]["exit_side"])
		spot.y = _exit_ground_y(spot.x, spot.z) + 0.1
		d.global_position = spot
		d.velocity = Vector3.ZERO
		d.visible = true
	drive_state_changed.emit(self, false)


func _kill_seq() -> void:
	if _seq != null and _seq.is_valid():
		_seq.kill()
	_seq = null


# The car door leaf's blocking collider: solid ONLY when parked with the door closed. Disabled
# while open (walk through the opening) and while entering/driving/exiting (the body's own box
# collider already covers the closed door, and a live child StaticBody would jam the camera
# SpringArm). No-op for door-less bodies.
func _set_door_blocking(on: bool) -> void:
	if _door_shape != null:
		_door_shape.disabled = not on


# ---------------- mount gait sync (embedded clips only) ----------------

# Drive the mount's own AnimationPlayer from the motion state. Ground: move clip while
# |speed| > 0.5 with speed_scale = clamp(speed/6, 0.6, 2.2) (gallop/run above 55% of max when
# the model carries one, else walk), idle when stopped/parked. Airborne (dragon): FLAP while
# climbing/accelerating, GLIDE when level/descending. Any missing clip is "" -> _play_clip
# no-ops -> a clipless creature rides silently (pinned degrade).
func _update_gait() -> void:
	if _gait_ap == null:
		return
	if _state == S_DRIVING and _airborne:
		var climbing := _pitch > deg_to_rad(3.0) or _speed < SPEED_MAX * 0.6
		var air_clip := _clip_flap if climbing else _clip_glide
		if air_clip == "":
			air_clip = _clip_flap if _clip_flap != "" else _clip_glide   # whichever exists
		if air_clip == "":
			air_clip = _clip_any   # no named air clip -> longest available beats a frozen flight (2.4)
		_play_clip(air_clip, 1.0)
		return
	if _state == S_DRIVING and absf(_speed) > GAIT_MOVE_MIN:
		var mv := _clip_walk
		if _clip_fast != "" and absf(_speed) > float(PROFILES[profile]["max_speed"]) * GAIT_FAST_FRAC:
			mv = _clip_fast
		if mv == "":
			mv = _clip_fast   # only a gallop/run clip shipped — better than freezing
		if mv == "":
			mv = _clip_any    # nothing name-matched -> longest rigged clip, never a frozen walk (2.4)
		_play_clip(mv, clampf(absf(_speed) / 6.0, 0.6, 2.2))
		return
	_play_clip(_clip_idle, 1.0)


# Play a clip if it isn't already playing (the WanderAgent._play idiom: force looping so gaits
# cycle) and set the playback rate. "" or no player -> silent no-op.
func _play_clip(clip: String, rate: float) -> void:
	if _gait_ap == null or clip == "":
		return
	_gait_ap.speed_scale = rate
	if _gait_ap.current_animation != clip:
		var a := _gait_ap.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		_gait_ap.play(clip)


func _match_clip(keys: Array) -> String:
	if _gait_ap == null:
		return ""
	for k in keys:
		for c in _gait_ap.get_animation_list():
			if String(k) in String(c).to_lower():
				return String(c)
	return ""


# The LONGEST embedded clip (by seconds) — the move/air fallback (2.4) so a rigged creature whose
# clips don't name-match any gait key still rides ANIMATED rather than frozen. "" only when the
# model carries no clips at all (the truly-clipless static degrade stays).
func _longest_clip() -> String:
	if _gait_ap == null:
		return ""
	var best := ""
	var best_len := -1.0
	for c in _gait_ap.get_animation_list():
		var a := _gait_ap.get_animation(String(c))
		if a != null and a.length > best_len:
			best_len = a.length
			best = String(c)
	return best


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


# ---------------- internals ----------------

# Silence the rider's colliders while aboard and make the two bodies mutually PASS THROUGH each
# other, so the physics solver can never depenetrate a seated rider back out of the hull ("character
# pops out of the vehicle"). Two-part fix: (1) disable every CollisionShape3D on the rider
# RECURSIVELY — a rigged avatar nests its shape under the model, not as a direct child, so the old
# direct-children-only loop missed it and left the rider solid; (2) a mutual collision exception
# (mirrors the door safeguard at enter/exit). Paired: off=true on board (disable + add exception),
# off=false on exit (re-enable + drop exception). Every caller passes the DRIVER.
func _set_body_collision(body: Node, off: bool) -> void:
	_disable_shapes_recursive(body, off)
	if body is CollisionObject3D:
		var co := body as CollisionObject3D
		if off:
			add_collision_exception_with(co)
			co.add_collision_exception_with(self)
		else:
			remove_collision_exception_with(co)
			co.remove_collision_exception_with(self)


func _disable_shapes_recursive(n: Node, off: bool) -> void:
	if n is CollisionShape3D:
		(n as CollisionShape3D).disabled = off
	for c in n.get_children():
		_disable_shapes_recursive(c, off)


# Floating prompt: DRIVE/RIDE when the player is within reach of the PARKED body; hidden while
# driving/riding (no floating EXIT/DISMOUNT words over the ride — USE is the exit control) and
# during the enter/exit choreography (USE is a no-op then anyway).
func _update_label() -> void:
	if _label == null:
		return
	if _state == S_ENTERING or _state == S_EXITING:
		_label.visible = false
		return
	if driving:
		_label.visible = false
		return
	_label.text = "RIDE" if _is_mount else "DRIVE"
	if player_ref == null or not is_instance_valid(player_ref):
		_label.visible = false
		return
	# Measure to the CLOSEST POINT on the body hull, not the node origin: on a 4 m body a player
	# touching the bumper is > PROMPT_RANGE from the origin but inches from the hull. Hysteresis
	# (show < PROMPT_RANGE / hide > PROMPT_HIDE) keeps an edge-hover from flickering the cue.
	var d := _hull_xz_distance(player_ref.global_position)
	if _label.visible:
		_label.visible = d < PROMPT_HIDE
	else:
		_label.visible = d < PROMPT_RANGE


# Horizontal (xz) distance from a world point to the CLOSEST POINT on the body's AABB. The box is
# stored in the vehicle's LOCAL frame at setup; bring the query point into local space, clamp it
# per-axis into the box, push the clamped point back to world, then measure in the xz plane. A
# cheap analytic closest-point — no physics query. The body root is yaw-only (flight pitch/roll
# rides _visual), so the xz result is exact; clamping y as well keeps it correct under any tilt.
func _hull_xz_distance(world_pos: Vector3) -> float:
	var local := global_transform.affine_inverse() * world_pos
	var clamped := Vector3(
		clampf(local.x, _body_ab.position.x, _body_ab.end.x),
		clampf(local.y, _body_ab.position.y, _body_ab.end.y),
		clampf(local.z, _body_ab.position.z, _body_ab.end.z))
	var closest := global_transform * clamped
	return Vector2(world_pos.x - closest.x, world_pos.z - closest.z).length()


# Merged mesh bounds of a subtree — DETACHMENT-SAFE (mirrors AreaBuilder._world_aabb): setup()
# measures the model BEFORE it is parented, where global_transform is identity + an error line.
# Accumulates transforms manually, root's own included. Local copy so this module stays
# self-contained (it is copied verbatim into the 3d template for parity).
func _world_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [[root, root.transform]]
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
