class_name Weather3D extends Node3D
## Prompt-driven TIME-OF-DAY + WEATHER for 3D templates (rpg / 3d).
##
## The agent configures it from the BUILD REQUEST — a single fixed condition, or an
## arbitrary CYCLE the request names. NEVER a default grey sky.
##
##   Weather.apply({"time": "night", "weather": "snow"})                 # "only snow" -> static
##   Weather.apply({"loop": true, "cycle": [                             # "cycle day -> night -> rain"
##       {"time": "day",   "weather": "clear", "seconds": 60},
##       {"time": "night", "weather": "rain",  "seconds": 30}]})
##
## Drives a ProceduralSkyMaterial sky + the sun (DirectionalLight3D) + Environment
## distance fog + camera-following CPU rain/snow + storm lightning + weather audio.
## gl_compatibility / WebGL2 safe: procedural sky (correct gamma), distance fog only
## (NO volumetric), CPUParticles3D, light-energy lightning. Set it up once with
## setup(env, sun, cam); it owns the sky/ambient thereafter (don't clobber env elsewhere).

# "Middle ground" lighting: day must not blow out pale albedo toward white, and
# night must stay readable (never near-black). sun_energy is monotone across
# day >= sunrise >= sunset >= night; retunes are CONSTANTS-ONLY — edit values here.
# (prev sun_energy: day 1.05 / sunrise 1.0 / sunset 0.95 / night 0.32; prev night
#  ambient Color(0.21, 0.24, 0.36) @ 0.85; prev sun clamp ceiling 1.6; prev
#  ambient_energy day 0.95 / night 0.9 — trimmed alongside env.tonemap_white = 4.0
#  in main.gd, which reshapes the whole ACES curve: day pale-wall radiance must sit
#  < 1.0 so headroom actually renders N·L shading, night whites land ~0.6 not 0.9)
const TIME := {
	"day": {
		"sun_rot": Vector3(-58, -42, 0), "sun_energy": 0.87, "sun_color": Color(1.0, 0.97, 0.9),
		"top": Color(0.28, 0.52, 0.92), "horizon": Color(0.74, 0.84, 0.98), "ground": Color(0.55, 0.6, 0.62),
		"ambient": Color(0.55, 0.58, 0.62), "ambient_energy": 0.80,
	},
	"sunrise": {
		"sun_rot": Vector3(-9, -98, 0), "sun_energy": 0.9, "sun_color": Color(1.0, 0.72, 0.46),
		"top": Color(0.33, 0.44, 0.72), "horizon": Color(0.98, 0.62, 0.42), "ground": Color(0.45, 0.42, 0.42),
		"ambient": Color(0.5, 0.46, 0.46), "ambient_energy": 0.95,
	},
	"sunset": {
		"sun_rot": Vector3(-8, -262, 0), "sun_energy": 0.85, "sun_color": Color(1.0, 0.55, 0.3),
		"top": Color(0.24, 0.3, 0.56), "horizon": Color(0.96, 0.46, 0.3), "ground": Color(0.4, 0.36, 0.38),
		"ambient": Color(0.46, 0.4, 0.42), "ambient_energy": 0.9,
	},
	# Night is "moonlit, playable" — geometry must stay readable on phone screens
	# (dark sky colours keep it reading as night; do NOT drop the light floor).
	"night": {
		"sun_rot": Vector3(-52, -150, 0), "sun_energy": 0.38, "sun_color": Color(0.58, 0.68, 1.0),
		"top": Color(0.02, 0.03, 0.1), "horizon": Color(0.06, 0.08, 0.17), "ground": Color(0.04, 0.05, 0.09),
		"ambient": Color(0.24, 0.27, 0.4), "ambient_energy": 0.75,
	},
}

# Weather modifiers layered on the time-of-day base.
#   desat  : desaturate + grey the sky colours (overcast look — ProceduralSky has no clouds)
#   bright : push the sky toward white (overcast) or black (storm)
#   light  : multiplier on sun + ambient energy
#   fog    : distance-fog density (0 = off); NEVER volumetric
#   part   : "" | "rain" | "snow"   audio: "" | "rain" | "wind"   storm: lightning on
const WX := {
	# FOG densities cut hard (was fog 0.032 / rain 0.011 / storm 0.015 / ...): the old "fog" preset was a
	# pea-soup white-out that, at sunrise, washed the whole daytime scene warm/hazy. Distance fog is kept only
	# LIGHT — enough to soften the far streaming edge, never enough to veil the daytime world. "clear" stays 0.
	"clear":    {"desat": 0.0, "bright": 0.0,  "light": 1.0,  "fog": 0.0,    "part": "",     "audio": "",     "storm": false},
	"cloudy":   {"desat": 0.35, "bright": 0.18, "light": 0.82, "fog": 0.0012, "part": "",     "audio": "",     "storm": false},
	"overcast": {"desat": 0.6,  "bright": 0.3,  "light": 0.6,  "fog": 0.004,  "part": "",     "audio": "wind", "storm": false},
	"fog":      {"desat": 0.45, "bright": 0.22, "light": 0.7,  "fog": 0.010,  "part": "",     "audio": "wind", "storm": false},
	"rain":     {"desat": 0.55, "bright": 0.05, "light": 0.55, "fog": 0.006,  "part": "rain", "audio": "rain", "storm": false},
	"storm":    {"desat": 0.65, "bright": -0.12, "light": 0.42, "fog": 0.009,  "part": "rain", "audio": "rain", "storm": true},
	"snow":     {"desat": 0.4,  "bright": 0.28, "light": 0.82, "fog": 0.008,  "part": "snow", "audio": "wind", "storm": false},
}

var env: Environment
var sun: DirectionalLight3D
var cam: Node3D                      # particles follow this (the camera/rig)
var time_state := "day"             # last-applied TIME key (day/night/sunrise/sunset) — read back by the web gogiGetTime hook
var no_fog := false                 # world.json sky {"fog": false} hard-disables distance fog on EVERY weather (incl. cycles)

var _sky_mat: ProceduralSkyMaterial
var _cur := {}                       # current (lerped) numeric state
var _target := {}                    # desired numeric state
var _cycle: Array = []               # [{time, weather, seconds}, ...]
var _loop := false
var _idx := 0
var _seg_t := 0.0
var _active_wx := "clear"            # weather whose particles/audio/lightning are live
var _fx: Node3D                      # parent for rain/snow, follows the camera
var _rain: CPUParticles3D
var _snow: CPUParticles3D
var _bolt_t := 5.0                   # countdown to next lightning
var _flash := 0.0                    # transient lightning brightness add


func setup(environment: Environment, sun_light: DirectionalLight3D, cam_node: Node3D) -> void:
	env = environment
	sun = sun_light
	cam = cam_node
	_sky_mat = ProceduralSkyMaterial.new()
	_sky_mat.sun_angle_max = 9.0
	_sky_mat.sky_energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.set_meta("weather_owned", true)   # area/chunk builders skip their env clobber when set
	# Explicit ambient (COLOR) so time-of-day ambient (dark night / warm dusk) is
	# driven by our presets rather than auto-derived from the sky.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_fx = Node3D.new()
	add_child(_fx)
	_rain = _make_rain()
	_snow = _make_snow()
	_fx.add_child(_rain)
	_fx.add_child(_snow)
	# A sane default until the agent calls apply() — clear day, never a grey void.
	var st := _resolve("day", "clear")
	_cur = st.duplicate(true)
	_target = st.duplicate(true)
	_apply_now()


## Configure from the build request. cfg = {time, weather} OR {cycle:[...], loop}.
func apply(cfg: Dictionary) -> void:
	# STICKY: only an apply() that explicitly carries a "fog" key may change the hard-disable.
	# Region/day-cycle re-applies ({time,weather} / {cycle} with no "fog" key) used to RESET
	# no_fog to false, silently re-enabling distance fog on the first weather tick after the
	# world.json sky {"fog": false} boot apply (QA P0: Frostpeak white-out).
	if cfg.has("fog"):
		no_fog = cfg.get("fog", null) == false
	if cfg.has("cycle") and cfg["cycle"] is Array:
		for seg0 in cfg["cycle"]:
			if seg0 is Dictionary and (seg0 as Dictionary).has("fog"):
				no_fog = (seg0 as Dictionary).get("fog", null) == false
				break
	if cfg.has("cycle") and cfg["cycle"] is Array and (cfg["cycle"] as Array).size() > 0:
		_cycle = []
		for seg in cfg["cycle"]:
			if seg is Dictionary:
				_cycle.append({
					"time": String(seg.get("time", "day")),
					"weather": String(seg.get("weather", "clear")),
					"seconds": maxf(2.0, float(seg.get("seconds", 30.0))),
				})
		_loop = bool(cfg.get("loop", true))
		_idx = 0
		_seg_t = 0.0
		_set_segment(0)
	else:
		_cycle = []
		_target = _resolve(String(cfg.get("time", "day")), String(cfg.get("weather", "clear")))
		_switch_weather(String(cfg.get("weather", "clear")))
		time_state = String(cfg.get("time", "day"))
	# Start IN the requested condition (no day->night fade on load); cycle segments
	# still cross-fade smoothly via the per-frame chase in _process.
	_cur = _target.duplicate(true)
	_apply_now()


# Immediate time-of-day override for the web JS hook (window.gogiSetTime). Pins `state` with the
# CURRENT weather and snaps to it INSTANTLY (apply() copies _cur = _target — no lerp), STOPPING any
# running cycle so the state holds until changed again. Unknown keys render as "day" (via _resolve)
# while time_state stores the raw request for readback.
func set_time(state: String) -> void:
	apply({"time": state, "weather": _active_wx})


func _set_segment(i: int) -> void:
	var seg: Dictionary = _cycle[i]
	_target = _resolve(String(seg["time"]), String(seg["weather"]))
	_switch_weather(String(seg["weather"]))
	time_state = String(seg["time"])


func _process(delta: float) -> void:
	# advance the cycle
	if not _cycle.is_empty():
		_seg_t += delta
		var dur := float(_cycle[_idx].get("seconds", 30.0))
		if _seg_t >= dur:
			_seg_t = 0.0
			_idx += 1
			if _idx >= _cycle.size():
				if _loop:
					_idx = 0
				else:
					_idx = _cycle.size() - 1
			_set_segment(_idx)
	# smoothly chase the target (~3.3s time constant regardless of frame rate, so
	# big light swings — e.g. rain -> clear day — glide instead of flashing)
	var k := clampf(delta * 0.3, 0.0, 1.0)
	for key in _target:
		var a = _cur.get(key)
		var b = _target[key]
		if a is float:
			_cur[key] = lerpf(a, b, k)
		elif a is Vector3:
			_cur[key] = (a as Vector3).lerp(b, k)
		elif a is Color:
			_cur[key] = (a as Color).lerp(b, k)
		else:
			_cur[key] = b
	# lightning timer (storm only)
	if _active_wx == "storm":
		_bolt_t -= delta
		if _bolt_t <= 0.0:
			_strike()
			_bolt_t = randf_range(4.0, 11.0)
	_flash = maxf(0.0, _flash - delta * 6.0)
	# the FX rig rides above the camera so rain/snow always surround the player
	if cam:
		_fx.global_position = cam.global_position + Vector3(0.0, 11.0, 0.0)
	_apply_now()


func _apply_now() -> void:
	if sun:
		sun.rotation_degrees = _cur.get("sun_rot", Vector3(-58, -42, 0))
		# clamped so no weather math + lightning combo blows out pale albedo materials
		sun.light_energy = clampf(float(_cur.get("sun_energy", 1.0)) + _flash * 2.5, 0.0, 1.5)
		sun.light_color = _cur.get("sun_color", Color.WHITE)
	if _sky_mat:
		_sky_mat.sky_top_color = _cur.get("top", Color(0.28, 0.52, 0.92))
		_sky_mat.sky_horizon_color = _cur.get("horizon", Color(0.74, 0.84, 0.98))
		_sky_mat.ground_horizon_color = _cur.get("horizon", Color(0.74, 0.84, 0.98))
		_sky_mat.ground_bottom_color = _cur.get("ground", Color(0.5, 0.55, 0.58))
	if env:
		env.ambient_light_color = _cur.get("ambient", Color(0.55, 0.58, 0.62))
		# same defence for ambient — lightning adds here too, never wash the scene out
		env.ambient_light_energy = clampf(float(_cur.get("ambient_energy", 1.0)) + _flash, 0.0, 1.3)
		var fog := float(_cur.get("fog", 0.0))
		env.fog_enabled = fog > 0.0001 and not no_fog   # sky {"fog":false} overrides every weather preset
		if env.fog_enabled:
			env.fog_density = fog
			env.fog_light_color = _cur.get("horizon", Color(0.7, 0.75, 0.8))


# Build the resolved numeric state for a (time, weather) pair.
func _resolve(time: String, weather: String) -> Dictionary:
	var t: Dictionary = TIME.get(time, TIME["day"])
	var w: Dictionary = WX.get(weather, WX["clear"])
	var desat := float(w["desat"])
	var bright := float(w["bright"])
	return {
		"sun_rot": t["sun_rot"],
		"sun_energy": float(t["sun_energy"]) * float(w["light"]),
		"sun_color": t["sun_color"],
		"top": _wx_col(t["top"], desat, bright),
		"horizon": _wx_col(t["horizon"], desat, bright),
		"ground": _wx_col(t["ground"], desat * 0.5, bright * 0.5),
		"ambient": _wx_col(t["ambient"], desat * 0.6, bright * 0.4),
		"ambient_energy": float(t["ambient_energy"]) * lerpf(1.0, float(w["light"]), 0.6),
		"fog": float(w["fog"]),
	}


# Desaturate toward grey, then push toward white (overcast) or black (storm).
func _wx_col(c: Color, desat: float, bright: float) -> Color:
	var g := c.v
	var grey := Color(g, g, g, 1.0)
	var out := c.lerp(grey, clampf(desat, 0.0, 1.0))
	if bright >= 0.0:
		out = out.lerp(Color(0.86, 0.88, 0.92), clampf(bright, 0.0, 1.0))
	else:
		out = out.lerp(Color(0.05, 0.06, 0.09), clampf(-bright, 0.0, 1.0))
	return out


func _switch_weather(weather: String) -> void:
	if weather == _active_wx:
		return
	_active_wx = weather
	var w: Dictionary = WX.get(weather, WX["clear"])
	var part := String(w["part"])
	_rain.emitting = part == "rain"
	_snow.emitting = part == "snow"
	if w["storm"]:
		_bolt_t = randf_range(2.0, 5.0)
	# WEATHER AUDIO BED — on AudioManager's dedicated weather channel, never play_ambient().
	#
	# This used to call play_ambient(load(bed)) and had NO else-branch: a preset with no audio
	# ("clear", "cloudy") fell through doing nothing, so rain kept looping after the sky cleared —
	# the particles stopped, the sound didn't. It also stomped the game's region/biome bed, which
	# then never came back. play_weather_path handles both: its own channel (so the biome bed below
	# it is untouched) and an explicit "" -> fade out over ~1s, matching the gradual visual
	# transition instead of cutting dead. stream_for is cached, so a mid-game weather change no
	# longer blocks on a file load.
	#
	# THUNDER IS DELIBERATELY NOT GATED ON THIS. It fires from _strike() off `_active_wx == "storm"`,
	# so a storm authored with no rain bed still rumbles — clearing the bed must never silence it.
	var audio := String(w["audio"])
	if Engine.has_singleton("AudioManager") or _has_audio_manager():
		var bed := ""
		if audio == "rain":
			bed = "res://audio/rain.ogg"
		elif audio == "wind":
			bed = "res://audio/wind.ogg"
		if bed != "" and not ResourceLoader.exists(bed):
			bed = ""   # authored but missing -> treat as silent, and still clear a stale bed
		AudioManager.play_weather_path(bed)


func _has_audio_manager() -> bool:
	return get_node_or_null("/root/AudioManager") != null


func _strike() -> void:
	_flash = 1.0
	if _has_audio_manager() and ResourceLoader.exists("res://audio/thunder.ogg"):
		# slight delay so the thunder trails the flash
		get_tree().create_timer(randf_range(0.4, 1.4)).timeout.connect(func() -> void:
			if _has_audio_manager():
				AudioManager.play_sfx("thunder", -3.0))


func _make_rain() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = 120   # 240->120: halve rain billboards -> ~half the full-screen transparent fill + CPU sim (mobile)
	p.lifetime = 0.9
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(14.0, 0.2, 14.0)
	p.direction = Vector3(0.0, -1.0, 0.0)
	p.spread = 2.0
	p.gravity = Vector3(0.0, -38.0, 0.0)
	p.initial_velocity_min = 14.0
	p.initial_velocity_max = 20.0
	var qm := QuadMesh.new()
	qm.size = Vector2(0.03, 0.55)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.65, 0.72, 0.9, 0.55)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.material = m
	p.mesh = qm
	return p


func _make_snow() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = 96   # 160->96: fewer snow billboards -> less transparent fill + CPU sim (mobile)
	p.lifetime = 4.0
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(14.0, 0.2, 14.0)
	p.direction = Vector3(0.0, -1.0, 0.0)
	p.spread = 8.0
	p.gravity = Vector3(0.0, -2.2, 0.0)
	p.initial_velocity_min = 0.6
	p.initial_velocity_max = 1.6
	p.angular_velocity_min = -40.0
	p.angular_velocity_max = 40.0
	var qm := QuadMesh.new()
	qm.size = Vector2(0.09, 0.09)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.96, 0.97, 1.0, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.material = m
	p.mesh = qm
	return p
