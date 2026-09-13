extends Node3D
## RPG STREAMING TEMPLATE — orchestration. Fetches a FETCHABLE world.json + quests.json
## (loose files served next to index.html, NOT packed in the .pck) + the asset manifest,
## wires the streaming systems, and keeps the player / combat / HUD PERSISTENT across area
## transitions. Areas + their .glb stream from R2 at runtime.
##
## EDITS COME FROM THE CHAT, not in-game: a chat edit is validated by qgcheck server-side
## and the new world.json is written back to R2. This template POLLS world.json and
## hot-reloads the live area when it changes (no re-export), so an open preview updates live.
##
## CHUNK MODE: when world.mode=="chunk" the one-resident ZONE streamer (SceneManager) is replaced
## by ChunkManager (resident 3x3 ring around the player). All chunk wiring is ADDITIVE + guarded
## by chunk_mode, so a non-chunk world behaves exactly as before.

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4
## Other players get their OWN layer rather than reusing L_ENEMY, and the reason is the projectile:
## its world ray runs with mask L_WORLD, and anything on that layer STOPS the shot as scenery before
## the proximity test can find a target. A peer on L_ENEMY would have worked by luck; on its own
## layer it is solid to the player (whose mask we extend) and invisible to every existing raycast.
const L_PEER := 8

# Default drivable-car model when a world-level "vehicles" entry omits "model" (resolved via _norm).
const VEHICLE_MODEL := "props/kk_city/car_sedan.glb"

# Third-person orbit camera (SpringArm rig) — see _build_player/_process/_input.
const CAM_DIST := 8.5
const CAM_HEAD := 1.5
# PITCH RANGE — deliberately narrow, and narrower than it looks like it "should" be.
# Was -1.30 .. +0.60 (1.90 rad). Measured on a 400px portrait screen that whole span was ~176 css px
# of drag — under half a thumb swipe — so players hit BOTH degenerate poses by accident, constantly:
# straight down is a screen of the player’s scalp and dark floor, and straight up drops the SpringArm
# to ground level until the avatar fills the entire frame against blank sky. Neither self-corrects;
# there is no recentring, so the camera just stays there for the rest of the session.
# +0.25 still clears the horizon (the reason Wave 2 raised it from -0.18) without the SpringArm
# grounding out behind the head.
const CAM_PITCH_MIN := -1.05
const CAM_PITCH_MAX := 0.25
const LOOK_SENS := 0.006
# Pitch is SLOWER than yaw on purpose. Yaw wants to be quick — turning to face someone is the most
# common camera action in the game. Pitch has hard stops a few degrees away in both directions, so at
# the same rate a gesture meant to turn slightly also slams into a limit. Splitting them is what makes
# the narrow range above feel deliberate instead of restrictive: ~206 css px to cross it, half a
# screen, rather than a flick.
const LOOK_SENS_PITCH := 0.0035

# Wave 2 (FEEL): canonical vertical motion + swim. GRAVITY applies ONLY while airborne — a floor snap
# hugs descents so the player never hovers off a ledge; together they restore the full default 45°
# climbable slope (stairs ~35° and river banks ~41° become walkable). SWIM floats the body at the
# water surface (head/shoulders above, always visible) when the water is deeper than a wade.
const GRAVITY := 22.0
const STEP_MAX := 1.2             # step-up assist lifts onto a lip no higher than this (else = a wall)
const EnemyScript := preload("res://enemy.gd")
const SPAWN_LIVE_CAP := 18   # max LIVE rule-spawned entities; older ones are recycled to make room
const JUMP_SPEED := 8.5           # jump launch velocity — apex ~1.6m at GRAVITY 22 (v = sqrt(2*g*h))
const BASE_MOVE_SPEED := 6.0      # the walk/run speed every world starts at; `set_speed` moves `move_speed` off it
const MAX_MOVE_SPEED := 24.0      # ceiling on `set_speed` — past this the body tunnels through streamed colliders
const SWIM_SPEED := 4.2           # player out-swims every creature (enemy in-water speed hard-capped at SWIM_MAX 2.6 in enemy.gd)
const SWIM_SURFACE_OFF := 1.1     # feet ride this far below the surface so the body sits IN the water (chest-deep, head+shoulders above). 0.4 pinned the FEET just under the surface -> the whole 1.7m body floated ON TOP ("walks then floats")
const WADE_DEPTH := 0.6           # water this much above the ground -> swim. MUST stay below a typical water.level (~1.0): the old 1.1 needed the seabed below -0.1, so ~95% of a shallow noise-lake never triggered swim ("can't swim in water")
const SWIM_CLIMB_REACH := 2.5     # a swimmer pushing toward shore climbs out onto walkable ground up to this far above the floating body — fixes being trapped bobbing at a steep/cliff bank the normal (seabed-risen) exit gate can't satisfy
const CLIMB_SPEED := 3.0          # CONTRACT C: ladder ascent/descent speed along Y
# --- TRAPPED-IN-PIT AUTO-RECOVERY (general pit/gorge climb-out) ---
# A grounded on-foot player pressing into a wall too steep to climb (so move_and_slide makes ~no
# progress), stuck for PIT_STUCK_TIME, gets a gentle scripted lift up the wall to the nearest walkable
# rim (found by sampling the shared heightfield). Universal — no per-world tuning, no collider dependency.
const PIT_STUCK_TIME := 1.4       # s of pressing-into-a-wall-with-no-progress before the lift arms
const PIT_PROGRESS_EPS := 0.6     # m/s: horizontal speed below this (while pushing) = "no progress" (walk = 6)
const PIT_PROBE_STEP := 0.5       # m: outward sampling stride searching the heightfield for the rim
const PIT_MAX_DIST := 6.0         # m: give up past this reach (a NEARBY pit wall, not a distant mountain)
const PIT_MIN_RISE := 1.6         # m: rim must sit at least this above the feet (== jump apex) so a jump+step can't already clear it
const PIT_WALK_SLOPE := 1.30      # tan(~52deg): a sample is a standable rim when the local slope is gentler than this
const PIT_LIFT_TIME := 0.45       # s: gentle scripted lift duration (smoothstep) — reads as a climb, never a launch

# Wave 4 ranged fire: auto-aim cone APEX angle (i.e. ±15° of the character's facing) and the
# muzzle's forward offset from the GEquipSlot (approximates the weapon tip for flash + spawn).
const FIRE_CONE_DEG := 30.0
const MUZZLE_FWD := 0.4

# Wave 1.5 native hero_model: the placeholder capsule mesh is 1.6 tall centred at y=0.85, so its
# top sits ~1.65 m — a fetched hero avatar scales to that height before its feet are seated at y=0.
const HERO_HEIGHT := 1.65

var origin := "https://preview.myapping.com"
var world_url := "https://preview.myapping.com/world.json"   # overridden from window.location on web
var build_id := ""
var enemy_catalog: Array = []       # [{id, url}] from the asset manifest — kind-name -> model lookup
var _spawn_model: Dictionary = {}   # kind -> resolved model url, filled by preload_spawn_kinds()
var _spawn_queue: Array = []        # spawns requested before the first area root existed
var _spawned: Array = []            # live rule-spawned entities (despawn / teleport_entity address these)
var props_pool: Array = []

# --- rule-owned player state (phase 6 actions) ---
# These three are the ONLY things `set_speed` / `freeze` / `set_spawn` touch. They live on main
# rather than on the director because a world may ship its OWN director: a flag parked on the stock
# game_shell would silently do nothing in exactly the games elaborate enough to replace it.
var move_speed := BASE_MOVE_SPEED   # walk/run m/s; swim scales with it so a speed buff works in water too
var input_frozen := false           # `freeze` — movement AND attacks halt; HUD buttons still work
var _spawn_point = null             # `set_spawn` checkpoint (Vector3) — null = the area's authored spawn

var world_data := {}
var quests_data := {}
var _world_raw := ""          # last raw world.json text (change-detect for the poll)
var _polling := false

var env: Environment
var sun: DirectionalLight3D
var player: CharacterBody3D
var _capsule_body: MeshInstance3D = null   # placeholder capsule mesh — hidden when a native hero_model attaches
var cam: Camera3D
var cam_rig: Node3D
var cam_spring: SpringArm3D
var cam_yaw := 0.0
var cam_pitch := -0.55
var look_idx := -1
# The touch currently owned by a HUD button, or -1. NOT the same question as move_idx/look_idx: a
# surrendered touch leaves BOTH of those at -1, which is exactly the state that armed the
# mouse-motion look fallback in _input — so a press that correctly went to a button still orbited the
# camera, through the emulated-mouse path. "No touch is driving the camera" and "no touch exists" are
# different facts, and conflating them is what made every smudged button press whip the view.
var _gui_touch_idx := -1
var look_last := Vector2.ZERO
var swing_t := 0.0                 # melee swing window (visual + re-tap gate) — decays in _process
# Wave 4 equipped-weapon state. GEquip owns the attached visual; main tracks the "GEquipSlot"
# node it hangs on the player (the swing pivot AND the ranged muzzle origin) and keeps the
# visual in sync with rpg.equipped_weapon (_sync_equip_visual).
var weapon_slot: Node3D = null     # the GEquipSlot on the player (BoneAttachment3D or fixed offset)
var _equipped_visual_id := ""      # weapon id the attached visual represents (sync guard)
var _equip_busy := false           # _sync_equip_visual re-entrancy latch (its model fetch awaits)
var _fire_cd := 0.0                # ranged/thrown cooldown (1.0 / def rate) — decays in _process
var _weapon_stowed := false        # Wave 1.5: weapon visual hidden while DRIVING A VEHICLE (kept on mounts)
var _tap_start := Vector2.ZERO      # touch-down point, for telling a build TAP from a look DRAG
var _tap_moved := false
var _jump_queued := false           # a JUMP press (Space / HUD button) waiting to be consumed on the floor
var _ground_stuck := false          # last frame the player was pinned to the analytic terrain (no collider yet) — counts as grounded for jump/gravity
var _foot_raw := 0.0                 # DEBUG: render-pose lowest-foot height above the body origin (measured at skeleton_updated)
var _weapon_btn: Button = null     # HUD draw/holster toggle (updates its own DRAW/SHEATHE label)
## The hero's animation state machine. ONE INSTANCE PER ANIMATED CHARACTER — this is the
## local player's; netsync holds one per remote peer. These were four globals on main, which
## is precisely why only one character in the scene could ever animate and every peer in a
## multiplayer room slid around frozen in its rest pose.
const GHeroAnim = preload("res://hero_anim.gd")
var _hero_anim_state := GHeroAnim.new()
var _hero_avatar: Node3D = null         # the attached hero GLB — hidden when the camera collapses onto it

var rpg: RpgState
var director = null   # OPTIONAL game-director plug-in (res://game_director.gd) — null on games that ship none
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var netsync: Node = null        # engine-side multiplayer (netsync.gd); null until a world enables it
var building: Node3D = null     # player-side BUILDING (building.gd); null until a world enables it
var quest: QuestSystem
var weather: Weather3D

# --- chunk-mode resident-ring streaming (behind world.mode=="chunk") ---
var chunk_manager: ChunkManager
var chunk_mode := false

# --- drivable vehicles (world-level "vehicles", vehicle.gd) — PERSISTENT, never cell-parented ---
var vehicle_root: Node3D = null   # persistent layer: chunk eviction / zone transitions never touch it
var vehicles: Array = []          # live Vehicle nodes
var active_vehicle: Vehicle = null   # the car being driven (input routed here; null = on foot)
var _vehicles_spec: Array = []    # snapshot of world "vehicles" for the hot-reload diff
var _on_web := OS.has_feature("web")   # cached: gates the mobile texture-cap telemetry
var _vram_t := 0.0              # throttle accumulator for the GOGI_VRAM_MB mobile-OOM telemetry
var auto_roam := false          # ?soak=1 -> player auto-roams so peak memory can be measured headlessly
var _roam_t := 0.0
var _roam_leg := false          # areas-mode soak: which end of the diagonal is the current waypoint
var _pstate_t := 0.0            # soak-only: seconds since the last GOGI_PSTATE line
var _roam_leg_t := 0.0          # time on this leg, so a player wedged on geometry still turns around
var _js_set_time_cb = null      # window.gogiSetTime callback (web) — held so JavaScriptBridge doesn't GC it
var _js_get_player_cb = null    # window.gogiGetPlayer callback (web, verify) — held so it isn't GC'd
var _js_solids_cb = null        # window.gogiSolids callback (web, verify) — held so it isn't GC'd
var _js_rotveh_cb = null        # window.gogiRotVeh debug callback (find the AI vehicle model yaw offset)
var _js_board_cb = null         # window.gogiBoard debug callback (board/exit nearest interactable = try_use)
var _gogi_push_tick := 0        # counts _push_gogi_state ticks so solids sweep on a slower cadence than the player

var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO

# Wave 2 FEEL state.
var swimming := false          # true while the player floats in deep water (see _chunk_physics)
var climbing = null            # CONTRACT C ladder state Dictionary {pos, base_y, top_y, facing}; null = off-ladder
var _pit_stuck_t := 0.0        # s the on-foot player has pressed into a wall with ~no progress
var _pit_lift = null           # active gentle-lift {from,to,t,dur}; null = not escaping (mirrors `climbing`)

var hud_layer: CanvasLayer
var _minimap: Control = null   # in-game minimap (minimap.gd), sized/placed in _relayout_ui
var _hp_bg: ColorRect = null   # health-bar backing plate; repositioned with the stats block
var stats: Label
var hp_bar: ColorRect
var _hud_btns: Dictionary = {}   # name -> Button, repositioned by _relayout_ui on resize
# Names a rule has hidden via `hud_hide`. Kept as state rather than just flipping `.visible`,
# because _relayout_ui RE-DECIDES visibility for the optional buttons on every resize — a rotation
# would otherwise put back a control the game deliberately took away.
var _hud_hidden: Dictionary = {}
var hud_debug := false           # ?hudgrid=1 / --hudgrid — overlay the live HUD geometry on screen
## ?capture=1 / --capture — hide the HUD so a recorded preview shows the GAME, not its controls.
##
## A feed card is a few seconds of gameplay filling a phone screen, and JUMP / USE / CHECKPOINTS /
## the minimap in every frame make it read as a screenshot of a UI rather than a world. The controls
## are the one part of the picture a viewer who has not tapped yet cannot use.
##
## Recording ONLY. It is never set during real play, and the automated recorder drives the hero with
## the keyboard (or a raw left-half touch, which is not a HUD button) — so nothing it needs to do
## depends on the controls being drawn.
var capture_mode := false
# Internal 3D resolution while recording, as a fraction of the capture viewport. Set from ?rscale=,
# which the recorder always passes, so this number is really just the fallback for a capture driven
# by something else.
#
# It defaults to the mobile 0.58 because MEASURED, this is the sharpest setting that still moves:
# the recorder rasterizes on the CPU, cost is quadratic here, and 1.0 took a real 30s capture from
# 7.0fps to 2.5fps. Sharper frames that arrive twice a second are a worse card than soft ones that
# animate. Do not raise the default without also removing the recorder's real-time constraint.
var capture_render_scale := 0.58
var _hud_dbg_lbl: Label = null
## ?mpdebug=1 / --mpdebug — peer sync health on screen. Exists because the whole netsync rewrite is
## INVISIBLE on a phone: a correctly-interpolated peer and one being held by a starved buffer look
## identical while walking, and the console that would say which is unreachable on a device.
var mp_debug := false
var _mp_dbg_lbl: Label = null
## Directional damage indicator: [angle_from_screen_up, seconds_remaining] per recent hit.
var _dmg_marks: Array = []
var _dmg_layer: Control = null
const DMG_MARK_S := 1.1
## One-shot: combat nodes are built on the first frame the world exists (see _process).
var _combat_warmed := false
var _world_rect := Rect2()       # authored grid bounds (chunk mode) — the always-on border clamp
var _dismount_btn: Button = null   # contextual GET-OFF button: hidden on foot, shown while driving/riding


func _ready() -> void:
	# Belt and braces: pause and bus-mute are ENGINE-GLOBAL and survive reload_current_scene, so a
	# game must never inherit them from whatever was suspended before it. Cleared here inline (not
	# via _host_resume) so a normal boot does not print a resume it never needed.
	get_tree().paused = false
	AudioServer.set_bus_mute(0, false)
	# RESPONSIVE FULL-SCREEN FILL: force expand at runtime (first-frame web canvas race) and
	# relayout the HUD against the LIVE viewport on every resize/rotation.
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.size_changed.connect(_relayout_ui)
	_fit_ui_scale()
	if OS.has_feature("web"):
		var o = JavaScriptBridge.eval("window.location.origin", true)
		if typeof(o) == TYPE_STRING and String(o) != "":
			origin = String(o)
		var dir = JavaScriptBridge.eval("window.location.href.replace(/[^/]*$/, '')", true)
		if typeof(dir) == TYPE_STRING and String(dir) != "":
			world_url = String(dir) + "world.json"
		# Build id = the first path segment ONLY when it actually looks like one (cloud-*/news-cloud-*).
		# Serving from a bare root (localhost verify, custom domain) otherwise captured "index.html"
		# as the build id and the self-heal re-rooted every asset onto a bogus /index.html/… path.
		var bid = JavaScriptBridge.eval("(function(){var s=location.pathname.split('/').filter(Boolean)[0]||'';return /^(news-)?cloud-/.test(s)?s:'';})()", true)
		if typeof(bid) == TYPE_STRING and String(bid) != "":
			build_id = String(bid)
		# `hud_debug` was declared and READ and never once assigned — the ?hudgrid=1 overlay could
		# not be switched on by any means. A diagnostic that cannot be enabled is worse than none:
		# it reads as available in the source and silently is not.
		if _query_flag("soak"):
			auto_roam = true
		if _query_flag("hudgrid"):
			hud_debug = true
		if _query_flag("mpdebug"):
			mp_debug = true
		if _query_flag("capture"):
			capture_mode = true
			capture_render_scale = clampf(_query_num("rscale", capture_render_scale), 0.25, 1.0)
			print("GOGI_CAPTURE render_scale=%.2f" % capture_render_scale)
	elif _pending_world_url == "":
		# Launch value. Skipped entirely on a runtime swap, or the command line would be adopted first
		# and then immediately overwritten — harmless but it logs two different worlds per reload,
		# which is exactly the sort of noise that makes a real mis-target hard to spot.
		_apply_cmdline_world()

	# A world requested at runtime outranks the launch value: this is the rebuilt scene after a swap.
	if _pending_world_url != "":
		_adopt_world_url(_pending_world_url)
		_pending_world_url = ""
		# The room travels WITH the world it was requested for, and is read exactly once. Taking it
		# here (rather than re-reading the command line later) is what stops a second multiplayer
		# link inheriting the room the app happened to BOOT with: argv is frozen at process start,
		# so on every swap it still names the first game's room. An empty value is a real answer —
		# "this world was opened without a room" — and must overwrite, not fall through.
		_current_room = _pending_room
		_pending_room = ""
	else:
		# First world of the launch: the room can only have arrived on the command line.
		_current_room = _cmdline_room()

	_connect_host_bridge()

	_build_env()
	_build_player()
	# Prompt-driven sky + weather owns the env/sun from here; defaults to clear day
	# until world.json's "sky" block is read in _boot. (See _apply_weather.)
	weather = Weather3D.new()
	add_child(weather)
	weather.setup(env, sun, cam_rig)
	_setup_web_time_hooks()   # window.gogiSetTime / gogiGetTime (web only) — needs `weather` to exist
	_build_hud()
	AudioManager.show_tap_overlay()   # web: gesture-gate so audio unlocks (autoplay policy) + a loading veil

	rpg = RpgState.new()
	add_child(rpg)
	rpg.changed.connect(_update_stats)
	rpg.changed.connect(_on_rpg_changed)   # Wave 4: chest auto-equip -> swap the weapon visual
	# Rule-layer item lifecycle. Connected HERE, at construction, rather than when the director is
	# built — so the wiring cannot be missed on whichever of the two director paths a world takes.
	# Nothing fires before the director exists because the handlers check for it.
	rpg.item_added.connect(_on_item_added)
	rpg.item_used.connect(_on_item_used)

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.world_url = world_url   # lets _region_base_dir() resolve region_*.json next to world.json
	builder.env = env
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)
	quest.objective_changed.connect(_update_stats)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	interaction.main_ref = self   # Wave 3: _nearest reads active_vehicle so seats are gated while driving/riding
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)   # reach_area objectives progress on arrival
	scene_manager.area_entered.connect(_on_area_entered)    # rule-layer `enter_area` + spawn cleanup

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(player, builder, self, env, interaction, rpg)
	chunk_manager.area_entered.connect(quest.notify_area)   # chunk-mode reach_area parity (only the active streamer emits)

	# poll world.json so a chat edit (qgcheck-gated, written to R2) hot-reloads live
	var poll := Timer.new()
	poll.wait_time = 4.0
	poll.autostart = true
	poll.timeout.connect(_poll_world)
	add_child(poll)

	# Wave 4: attach the default melee weapon NOW (parametric — no fetch), replacing the old
	# hardcoded sword MeshInstance, so the player isn't bare-handed while world.json streams.
	# _boot re-syncs if "start_weapon" names something else.
	_sync_equip_visual()

	# OPTIONAL game-director plug-in: a game may ship `res://game_director.gd` exposing setup(main)
	# (+ optional world_ready / world_reloaded / input_locked / _shake_cam / toggle_stable_panel —
	# every call site is null-guarded) to own a title screen (mode select), regions/weather, beacons,
	# taming/stable,
	# campaign chain, persistence, and input gating. The SHARED engine stays game-agnostic: no
	# director ships by default, so a game without one boots straight into the world.
	#
	# `world_ready()` is called ONCE at boot — put one-time setup there (start the chain, board the
	# player, apply the opening weather). `world_reloaded()` is called after EVERY applied world.json
	# poll (a live chat edit), so it must be pure re-read: refresh cached regions/beacons/tuning from
	# main.world_data and nothing else. Implementing it is what makes region + quest edits take effect
	# live instead of needing a reload; NEVER re-run world_ready()'s setup from it.
	# PRECEDENCE: a game-authored script wins when present (older games are untouched). A game with
	# NO script but a `director` block in world.json gets the shared, data-driven GameShell instead —
	# same seven-method interface, configured rather than coded. A game with neither boots straight
	# into the world, exactly as before.
	if ResourceLoader.exists("res://game_director.gd"):
		var _ds := load("res://game_director.gd")
		if _ds != null:
			director = _ds.new()
			add_child(director)
			if director.has_method("setup"):
				director.setup(self)

	_update_stats()
	await get_tree().process_frame
	await get_tree().process_frame
	_relayout_ui()   # the web canvas size is NOT final on the first frame
	_boot()


func _boot() -> void:
	# manifest -> props pool (best effort)
	var man := HTTPRequest.new()
	add_child(man)
	man.request(origin + "/godot-assets/manifest.json")
	var mr = await man.request_completed
	man.queue_free()
	if mr[1] == 200:
		_parse_manifest(mr[3])
	builder.props_pool = props_pool

	# world.json (required) — a loose file served next to index.html
	var wq := HTTPRequest.new()
	add_child(wq)
	wq.request(world_url)
	var wr = await wq.request_completed
	wq.queue_free()
	if wr[1] != 200:
		stats.text = "world.json fetch failed (HTTP %s) @ %s" % [str(wr[1]), world_url]
		return
	var raw := (wr[3] as PackedByteArray).get_string_from_utf8()
	var world = JSON.parse_string(raw)
	if not (world is Dictionary):
		stats.text = "world.json parse error"
		return
	world_data = world
	_world_raw = raw
	# DATA-DRIVEN DIRECTOR. Created HERE, not in _ready(): the shell is configured from
	# world_data["director"], and world_data does not exist until this fetch lands. A game-authored
	# res://game_director.gd (loaded in _ready) always wins — this only fills the gap for a game that
	# ships no script. preload, not load, so a parse error in game_shell.gd fails the EXPORT rather
	# than shipping a game with no title screen.
	# ALSO created for a world that authors `rules`/`vars` and NO director. GameShell hosts the rule
	# layer, so gating its creation on a `director` block alone would silently drop every rule in a
	# game that wanted behavior but no title screen — which is most of them. Found by testing: the
	# rules loaded fine and simply never ran, with nothing in the log to say why.
	if director == null and (world.get("director", null) is Dictionary
			or world.has("rules") or world.has("vars")):
		var _shell = preload("res://game_shell.gd")
		if _shell != null:
			director = _shell.new()
			add_child(director)
			director.setup(self)
	_apply_weather(world)
	rpg.load_weapons(world.get("weapons", {}))   # Wave 4: world "weapons" merge over inline ITEMS
	# Resolve + fetch every spawnable kind now. A rule bound to `start` can fire within the first
	# frames, and _do() cannot await a download, so this has to complete before gameplay begins.
	await preload_spawn_kinds()

	# quests.json (fetched alongside world.json — the same data qgcheck validates)
	var qq := HTTPRequest.new()
	add_child(qq)
	qq.request(world_url.replace("world.json", "quests.json"))
	var qr = await qq.request_completed
	qq.queue_free()
	if qr[1] == 200:
		var qdata = JSON.parse_string((qr[3] as PackedByteArray).get_string_from_utf8())
		if qdata is Dictionary:
			quests_data = qdata
			quest.load_quests(qdata)
			# Start every quest flagged `"auto_start": true` in quests.json.
			# A quest only advances while status=="active" (quest.gd), so an unstarted
			# quest ignores every kill/pickup/arrival forever — its on_complete_flags
			# never fire and any seam locked by them stays shut, making the world
			# unwinnable. Opting IN per-quest keeps the game-director design intact: a
			# title-screen game simply marks nothing auto_start and calls quest.start()
			# from res://game_director.gd itself.
			for _q in qdata.get("quests", []):
				if _q is Dictionary and bool(_q.get("auto_start", false)):
					quest.start(String(_q.get("id", "")))

	# world-level drivable vehicles — spawned ONCE onto the persistent layer BEFORE the streamer
	# starts, so their builder._ensure can't interleave with a cell build's parallel downloads.
	await _spawn_vehicles(world)

	# Wave 4: "start_weapon" equips at spawn. Its model prefetch is SERIALIZED here (like the
	# vehicles above) so a library//BUILD_ID weapon GLB can't interleave with the streamer's
	# parallel downloads; "parametric:*" models need no fetch at all.
	var start_id := String(world.get("start_weapon", ""))
	if start_id != "":
		if not rpg.has_item(start_id):
			rpg.add_item(start_id)
		rpg.equip(start_id, true)   # force: the authored start weapon wins regardless of damage
	await _sync_equip_visual()

	# Wave 1.5: a world-level "hero_model" wears a real character over the placeholder capsule.
	# Serialized here (like the vehicles/start_weapon prefetch) so its GLB fetch can't interleave
	# with the streamer's parallel downloads.
	await _attach_hero_model()

	# AUTH BEFORE MULTIPLAYER, and only when the world needs it. A game that asks for neither
	# `multiplayer` nor `auth` never sees a sign-in screen and needs no backend at all — its saves
	# are local. Awaited, because peers must be identifiable before the first packet goes out.
	await _gate_auth()

	# SAVES, after auth (the cloud backend needs a session) and before the shell exists (rules
	# restore persisted vars in setup, so the state has to be in hand by then). A world that
	# persists nothing and builds nothing never touches storage.
	await _setup_save(world)

	# Multiplayer, if the WORLD asks for it. Started here, after the hero exists, because peers are
	# bodies in the scene and the remote-avatar factory clones the same model the local player wears.
	_setup_multiplayer()

	# BUILDING, if the world asks for it. After saves (it restores what was built), after the
	# director (placement costs are charged against rule-layer vars) and after multiplayer (a
	# placement is broadcast the moment it happens).
	if world.get("building", null) is Dictionary and building == null:
		building = preload("res://building.gd").new()
		building.name = "GBuilding"
		add_child(building)
		building.configure(self, world)

	if String(world.get("mode", "")) == "chunk":
		chunk_mode = true
		scene_manager._fade.visible = false   # chunk mode never fades -> hide the opaque black overlay
		# SHADOWS OFF on the mobile/web open-world path: the sun shadow re-renders EVERY caster (all the high-poly
		# Meshy props/creatures + terrain) a second time into the shadow map each frame — a big slice of a weak
		# mobile GPU's budget, and the low framerate it causes is what stutters ("jitter"). Dropping shadows is the
		# single largest safe FPS win; the scene reads slightly flatter but runs far smoother. (Trivially reversible.)
		sun.shadow_enabled = not _on_web
		sun.shadow_normal_bias = 2.0
		sun.directional_shadow_max_distance = 32.0
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		await chunk_manager.start(world)
		_wire_vehicle_terrain()   # GTerrain exists only after start() — hand it to the parked cars
		# Wave 3 spawn-clearance: vehicles spawn (line ~235) BEFORE any cell is built, so a vehicle
		# authored on top of a building can't be de-wedged at spawn time — do it now that the start
		# ring's structures exist. Pushes only a genuinely-wedged vehicle onto clear ground.
		for v in vehicles:
			if is_instance_valid(v):
				v.global_position = chunk_manager.nudge_out(v.global_position, 2.5)
		interaction.terrain = chunk_manager.terrain   # Wave 3: grounds the stand-up-from-a-seat spot
		# BOUNDS (true outer edges), never grid_world_rect() (cell CENTRES, for auto-roam) — centres
		# fence the player half a cell inside the border walls they can see. Rationale: chunk_manager.
		_world_rect = chunk_manager.grid_bounds_rect()   # QA W-2 always-on border clamp reads it every tick
		# Telemetry, same reason as GOGI_MP/GOGI_VRAM_MB: containment is invisible from outside, so a
		# clamp that quietly steals a half-cell ring looks identical to a correct one until someone
		# walks the edge. Printing the rect makes the property assertable by a harness.
		print("GOGI_WORLD_BOUNDS x=", _world_rect.position.x, "..", _world_rect.end.x,
			" z=", _world_rect.position.y, "..", _world_rect.end.y)
		if director != null:
			director.world_ready()   # beacons/regions/taming need terrain + vehicles
	else:
		scene_manager.start(world)
		# ZONE MODE GETS world_ready() TOO. It never did: the call sat inside the chunk branch only,
		# so every multi-area (non-chunk) world silently skipped _apply_mode() — no opening weather,
		# no granted items, no mode spawn, no story chain, and a title-screen button that set `mode`
		# and then did nothing, because _choose() defers to `_world_ready` and that stayed false
		# forever. Found while testing the rule layer, whose `start` event runs from the same call.
		if director != null:
			director.world_ready()


# QA W-2: _terrain_border_walls only exist once the edge cell BUILDS, so a player sprinting at a
# still-streaming border could walk off the authored grid onto empty terrain. Clamp the player
# (and the driven vehicle — aircraft cross a border fastest) to the grid bounds every tick.
func _clamp_to_world() -> void:
	if not chunk_mode or _world_rect.size.x <= 0.0:
		return
	var lo_x := _world_rect.position.x + 1.0
	var hi_x := _world_rect.end.x - 1.0
	var lo_z := _world_rect.position.y + 1.0
	var hi_z := _world_rect.end.y - 1.0
	var pp := player.global_position
	if pp.x < lo_x or pp.x > hi_x or pp.z < lo_z or pp.z > hi_z:
		player.global_position = Vector3(clampf(pp.x, lo_x, hi_x), pp.y, clampf(pp.z, lo_z, hi_z))
	if active_vehicle != null and is_instance_valid(active_vehicle):
		var vp: Vector3 = active_vehicle.global_position
		if vp.x < lo_x or vp.x > hi_x or vp.z < lo_z or vp.z > hi_z:
			active_vehicle.global_position = Vector3(clampf(vp.x, lo_x, hi_x), vp.y, clampf(vp.z, lo_z, hi_z))


func _physics_process(delta: float) -> void:
	if player == null:
		return
	if input_frozen or (director != null and director.input_locked()):
		return   # title screen open, or a rule froze the player — the world holds still
	_clamp_to_world()   # border walls only exist once the edge cell BUILDS — this is the always-on containment
	if active_vehicle != null:
		# DRIVING: feed the car the SAME input vector that walks the player (one input path, no
		# second binding). The vehicle integrates it in its own physics tick and parks the hidden
		# player on itself, so chunk streaming + reach_area quest notifications (both read
		# player.global_position) keep following the driven position.
		if not is_instance_valid(active_vehicle):
			active_vehicle = null   # freed under us (hot-reload edge) — fall through to on-foot
		else:
			# CONTRACT A: feed the vehicle a CAMERA-relative world-XZ desired heading (length =
			# throttle 0..1). The raw drive_input(Vector2) path stays intact on vehicle.gd for the
			# verify harness — we just route the on-screen drive through drive_input_world here.
			var v := _keyboard_vec() + move_vec
			if v.length() > 1.0:
				v = v.normalized()
			var d3 := Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
			# Untyped hop: this compiles green while vehicle.gd's drive_input_world half lands in
			# parallel (a typed Vehicle call would parse-fail until the method exists).
			var av = active_vehicle
			av.drive_input_world(Vector2(d3.x, d3.z))
			return
	# Wave 3 (sittable furniture): a SEATED player doesn't move — but movement input IS the intent
	# to leave, so it stands them up first (interaction restores the pose + places them beside the
	# seat, grounded); motion resumes next tick. This ONE gate covers BOTH the zone and chunk
	# physics paths below. The camera is untouched — the SpringArm rig follows the seated player.
	if interaction != null and interaction.player_seated:
		if (_keyboard_vec() + move_vec).length() > 0.1:
			interaction.stand_player()
		return
	if chunk_mode:
		_chunk_physics(delta)
		return
	if scene_manager == null:
		return
	if scene_manager.transitioning or scene_manager.current_root == null:
		return
	var v := _keyboard_vec() + move_vec
	if auto_roam:
		v = _roam_vec_areas(delta)
	if v.length() > 1.0:
		v = v.normalized()
	# Camera-relative: forward = away from the camera, rotated by the orbit yaw. The soak roam is the
	# exception — it computes a WORLD-space heading, so the orbit yaw must not rotate it (same rule
	# the chunk path follows).
	var dir := Vector3(v.x, 0.0, v.y) if auto_roam else Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	# Wave 2 canonical vertical motion: horizontal drive + airborne-only gravity + floor snap, so
	# descents hug the ground (no ledge hover) and the full 45° slope stays climbable (stairs/ramps).
	player.velocity.x = dir.x * move_speed
	player.velocity.z = dir.z * move_speed
	if player.is_on_floor():
		player.velocity.y = JUMP_SPEED if _jump_queued else 0.0   # launch a queued jump off the ground
	else:
		player.velocity.y -= GRAVITY * delta
	_jump_queued = false
	player.floor_snap_length = 0.0 if player.velocity.y > 0.1 else 0.8   # don't let floor-snap cancel a jump
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_step_up_assist(dir)


## Soak roam for an AREAS world — the counterpart to the chunk-grid ping-pong in _chunk_physics.
##
## Without this, `--soak` / `?soak=1` in an areas world moves the player NOWHERE: the only roam the
## engine had lived inside _chunk_physics, which never runs here. That silently caps every automated
## check at "whatever fires while standing on the spawn point" — no region crossings, no boarding, no
## placement — and a probe that cannot move looks exactly like a probe that found nothing wrong.
##
## WAYPOINTS, not a lerped target. A continuously-moving target outruns a walking player, who then
## oscillates near the middle and never reaches either extreme (measured: the centre region fired,
## both ends never did). Driving to one corner, then the other, makes coverage independent of player
## speed. The per-leg timeout exists because an area full of walls WILL wedge the player, and without
## it the roam would stall against geometry forever.
func _roam_vec_areas(delta: float) -> Vector2:
	if scene_manager == null or not scene_manager.areas.has(scene_manager.current_id):
		return Vector2.ZERO
	_roam_leg_t += delta
	var rec: Dictionary = scene_manager.areas[scene_manager.current_id]
	var s := float(rec.get("size", 13)) * 0.6
	var goal := Vector3(s, 0.0, s) if _roam_leg else Vector3(-s, 0.0, -s)
	var to := goal - player.global_position
	var flat := Vector2(to.x, to.z)
	if flat.length() < 2.0 or _roam_leg_t > 12.0:
		_roam_leg = not _roam_leg
		_roam_leg_t = 0.0
	return flat


func _chunk_physics(delta: float) -> void:
	# CONTRACT C: a ladder takes over vertical motion entirely (the ONE no-vertical-face exception).
	if climbing != null:
		_climb_physics(delta)
		return
	# TRAPPED-IN-PIT: an armed gentle lift owns motion entirely (like the ladder) until it completes.
	if _pit_lift != null:
		_pit_escape_physics(delta)
		return
	var v := _keyboard_vec() + move_vec
	if auto_roam and chunk_manager != null:
		_roam_t += delta
		# diagonal ping-pong across the whole grid -> the resident ring shifts + evicts repeatedly
		var rect := chunk_manager.grid_world_rect()
		var tt := fmod(_roam_t * 0.05, 2.0)
		var f := tt if tt <= 1.0 else (2.0 - tt)
		var target := Vector3(rect.position.x, 0.0, rect.position.y).lerp(
			Vector3(rect.end.x, 0.0, rect.end.y), f)
		var to := target - player.global_position
		v = Vector2(to.x, to.z)
	if v.length() > 1.0:
		v = v.normalized()
	# Camera-relative when the player drives; world-relative during the headless
	# soak roam (auto_roam computes a world-space target, cam_yaw must not rotate it).
	var dir := Vector3(v.x, 0.0, v.y) if auto_roam else Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)

	# CONTRACT D: swim/wade is decided from chunk_manager's water fields (READ-only). `depth` is how
	# far the water level sits above the ground beneath the player's feet.
	var px := player.global_position.x
	var pz := player.global_position.z
	var wl := chunk_manager.water_level if (chunk_manager != null and chunk_manager.water_cfg != null) else -1e9
	var gy := chunk_manager._ground_y(px, pz) if chunk_manager != null else 0.0
	var depth := wl - gy                                 # water column above the seabed at this XZ
	var below := wl - player.global_position.y           # how far the body sits under the surface (feet-origin)
	# Engage swim when the player stands in a column deeper than a wade OR the body itself has dropped
	# below the surface by more than a wade. The player-Y branch is INDEPENDENT of the seabed reading,
	# so a too-high seabed, a steep unwadeable shore, or a dive-in can no longer suppress swim (the old
	# depth-only gate + a redundant `player.y < wl-0.2` AND-clause meant a shallow noise-lake never
	# triggered — the player just stood on a bottom ~0.3m under the surface, reading as lying ON the lake).
	# Exit only once the seabed has risen to the waterline AND the body is back near the surface (hysteresis).
	# The seabed-depth clause must ALSO see the player IN the water column (feet at/near/under the surface).
	# A BRIDGE/pier/boat deck OVER a water-filled gorge has a deep seabed -> depth>WADE, which would engage
	# swim and the body-snap below would drop the DECKED player to the surface ("falls from the bridge").
	# below > -0.3  ==  player.y < wl+0.3: true when wading the submerged seabed, false standing on a deck.
	if not swimming and wl > -1e8 and ((depth > WADE_DEPTH and below > -0.3) or below > WADE_DEPTH):
		_enter_swim()
	elif swimming and depth <= WADE_DEPTH and below <= 0.2:
		_exit_swim()   # ground rose to the waterline -> hand back to walk

	if swimming:
		# SHORE CLIMB-OUT (steep/cliff banks): if the swimmer is pushing toward shore and walkable ground
		# sits just ahead at/above the wade line and within a reachable lift, leave the water onto it. The
		# normal exit gate needs the seabed UNDER the feet to rise to the waterline, which never happens at
		# a steep bank (the water there stays deep) — so without this the player is trapped bobbing at the wall.
		if dir.length() > 0.1 and chunk_manager != null:
			var ah := player.global_position + dir.normalized() * 0.9
			var ag := chunk_manager._ground_y(ah.x, ah.z)
			if ag >= wl - WADE_DEPTH and ag <= player.global_position.y + SWIM_CLIMB_REACH:
				player.global_position = Vector3(ah.x, ag + 0.05, ah.z)
				player.velocity = Vector3.ZERO
				_exit_swim()
				return
		# Float the body at the surface (head/shoulders above, always VISIBLE), move horizontally,
		# NO gravity — the water holds the player up.
		# Swim scales with the walk speed, so a `set_speed` buff is not silently cancelled the moment
		# the buffed player steps into water.
		var swim_spd := SWIM_SPEED * (move_speed / BASE_MOVE_SPEED)
		player.velocity.x = dir.x * swim_spd
		player.velocity.z = dir.z * swim_spd
		player.velocity.y = 0.0
		if dir.length() > 0.1:
			var slook := player.global_position - dir
			player.look_at(Vector3(slook.x, player.global_position.y, slook.z), Vector3.UP)
		player.move_and_slide()
		player.global_position.y = maxf(gy - 0.2, wl - SWIM_SURFACE_OFF)   # ride the surface offset, but never sink the feet through the seabed in marginal-depth water
		return

	# WALK: horizontal drive at 6 m/s + airborne-only gravity + floor snap (canonical vertical
	# motion — hugs descents, restores the full 45° climbable slope, no mid-air ledge hover).
	player.velocity.x = dir.x * move_speed
	player.velocity.z = dir.z * move_speed
	# GROUNDED = on a real collider OR pinned to the terrain by last frame's ground-stick (below). A
	# running player can outrun the one-cell-per-frame collider build (much worse on a low-fps phone),
	# so is_on_floor() alone reads "airborne" over not-yet-collided terrain — which BOTH blocked jumps
	# AND let gravity run, so the hero free-fell and yo-yoed on the old catcher (the "running floats").
	var grounded := player.is_on_floor() or _ground_stuck
	if grounded:
		player.velocity.y = JUMP_SPEED if _jump_queued else 0.0   # launch a queued jump off the ground
	else:
		player.velocity.y -= GRAVITY * delta
	_jump_queued = false
	player.floor_snap_length = 0.0 if player.velocity.y > 0.1 else 0.8   # don't let floor-snap cancel a jump
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	var pit_pre := player.global_position   # horizontal progress this tick (step-up/ground-stick only change Y)
	player.move_and_slide()
	_step_up_assist(dir)
	# GROUND-STICK (replaces the old 2 m fall-catcher): _ground_y reads the heightmap ANALYTICALLY (no
	# collider needed). Whenever the on-foot player is NOT rising from a jump and sits at/under the
	# terrain surface, pin the feet exactly to it — so a running player stays glued to the ground even
	# when the cell's trimesh collider hasn't streamed in yet (or a low-fps phone falls behind the
	# one-per-frame build). It no longer free-falls + bounces on the catcher, so the floating stops.
	# A rising jump (velocity.y>0.5) and anything standing ABOVE the ground on a structure/step are left
	# to real physics — the pin only engages at or below the terrain surface.
	var floor_y := chunk_manager._ground_y(player.global_position.x, player.global_position.z) if chunk_manager != null else 0.0
	_ground_stuck = false
	if player.velocity.y <= 0.5 and player.global_position.y <= floor_y + 0.1:
		player.global_position.y = floor_y
		player.velocity.y = 0.0
		_ground_stuck = true
	_update_pit_escape(delta, dir, pit_pre)


# CONTRACT C (player half): joystick-Y climbs Y between base_y/top_y at CLIMB_SPEED, pinned to the
# ladder xz so the player can't drift off; at the top step FORWARD onto the surface and detach; below
# the base or a strong sideways push also detaches. velocity.y drives motion — the one place a
# vertical face is walkable. `climbing` is the Dictionary interaction.gd's ladder USE handed us.
func _climb_physics(_delta: float) -> void:
	var c: Dictionary = climbing
	var pos: Vector3 = c["pos"]
	var base_y := float(c["base_y"])
	var top_y := float(c["top_y"])
	var facing: Vector3 = c["facing"]
	var v := _keyboard_vec() + move_vec
	if absf(v.x) > 0.7:
		climbing = null                      # strong sideways input -> step off the ladder
		return
	player.velocity = Vector3(0.0, -v.y * CLIMB_SPEED, 0.0)   # screen-up (-y) ascends
	player.move_and_slide()
	player.global_position.x = pos.x         # pin to the ladder xz (no drift)
	player.global_position.z = pos.z
	if player.global_position.y >= top_y:
		player.global_position.y = top_y
		player.global_position += facing.normalized() * 0.6   # step forward onto the top surface
		climbing = null
		return
	if player.global_position.y <= base_y:
		player.global_position.y = base_y
		if v.y > 0.1:                        # still pushing down at the foot -> dismount at the base
			climbing = null


func _enter_swim() -> void:
	swimming = true
	# Make sure a real clip is RUNNING before GPose freezes the rig. Spawning straight into deep water
	# engages swim on the first physics frame, and freezing a rig that has never been posed captures
	# its rest pose — a T-pose. (GPose._freeze_anim also forces the pose to apply; this covers the
	# other half, where no clip had been requested at all.)
	_hero_anim_state.play("idle")
	GPose.swim(player)                       # self-guards: a capsule (unrigged) player is a no-op


func _exit_swim() -> void:
	swimming = false
	GPose.stand(player)


# Wave 2 UNIVERSAL STEP-UP ASSIST: when a grounded walk is blocked by a low lip (is_on_wall while
# pushing into it) but a walkable surface sits just ahead no higher than STEP_MAX, lift the feet onto
# it. This is the shoreline-exit + low-ledge fix. A DOWN-ray from just above STEP_MAX finds the
# surface; anything higher (a true wall) is left alone so the player is never launched up a face.
# Works in BOTH modes/tiers via the physics ray — no dependency on the terrain heightfield.
func _step_up_assist(dir: Vector3) -> void:
	if player == null or dir.length() < 0.1:
		return
	if not (player.is_on_wall() and (player.is_on_floor() or _ground_stuck)):
		return
	var into := dir.normalized()
	if into.dot(-player.get_wall_normal()) < 0.3:
		return                               # not actually moving into the wall we hit
	var feet := player.global_position.y
	# Probe PAST the capsule radius (0.4): at exactly the radius the down-ray lands tangent to a
	# sharp ledge face and hits the ground IN FRONT of it (step≈0) instead of the lip on top, so
	# low sharp ledges never lifted. 0.6 = radius + margin, landing the ray solidly on the lip.
	var ahead := player.global_position + into * 0.6
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(ahead.x, feet + STEP_MAX + 0.1, ahead.z),
		Vector3(ahead.x, feet - 0.5, ahead.z), L_WORLD)
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var step := float(hit["position"].y) - feet
	if step > 0.05 and step <= STEP_MAX:
		player.global_position.y = float(hit["position"].y) + 0.02   # onto the lip


# TRAPPED-IN-PIT detector: arms ONLY when grounded (on the pit floor, not jumping), actively pushing, and
# stalled (near-zero horizontal progress this tick = pressing into a wall too steep to climb). Any real
# progress, letting go, or leaving the floor disarms instantly. Lives in the WALK path only, so
# vehicle/seated/swim/ladder (all early-returns above) never reach it.
func _update_pit_escape(delta: float, dir: Vector3, pre_pos: Vector3) -> void:
	if chunk_manager == null:
		_pit_stuck_t = 0.0
		return
	var grounded := player.is_on_floor() or _ground_stuck
	var pushing := dir.length() > 0.1
	var moved := Vector2(player.global_position.x - pre_pos.x, player.global_position.z - pre_pos.z).length()
	var speed := moved / maxf(delta, 0.0001)
	if not (grounded and pushing and player.velocity.y <= 0.5 and speed < PIT_PROGRESS_EPS):
		_pit_stuck_t = 0.0
		return
	_pit_stuck_t += delta
	if _pit_stuck_t < PIT_STUCK_TIME:
		return
	var target = _find_pit_rim(dir.normalized())
	if target == null:
		_pit_stuck_t = PIT_STUCK_TIME * 0.5   # bleed down so an open stall doesn't re-search every frame
		return
	_pit_lift = {"from": player.global_position, "to": target, "t": 0.0, "dur": PIT_LIFT_TIME}
	_pit_stuck_t = 0.0


# Gentle scripted lift to the rim: smoothstep position-lerp, velocity zeroed (cannot launch). Mirrors how
# _climb_physics owns vertical motion; on completion hands back to walk with the feet on the rim.
func _pit_escape_physics(delta: float) -> void:
	var s: Dictionary = _pit_lift
	s["t"] = float(s["t"]) + delta
	var k := clampf(float(s["t"]) / float(s["dur"]), 0.0, 1.0)
	var e := k * k * (3.0 - 2.0 * k)
	player.global_position = (s["from"] as Vector3).lerp(s["to"] as Vector3, e)
	player.velocity = Vector3.ZERO
	if k >= 1.0:
		player.global_position = s["to"]
		_pit_lift = null
		_pit_stuck_t = 0.0
		_ground_stuck = true


# Search the SHARED heightfield outward along `into` for the nearest standable rim (Vector3) or null.
# Requires passing THROUGH a genuine wall (terrain rising > STEP_MAX above the feet) before accepting a
# rim, so pushing into a building/prop over flat ground never triggers a lift — only true terrain walls do.
func _find_pit_rim(into: Vector3):
	if chunk_manager == null or into.length() < 0.1:
		return null
	var feet := player.global_position.y
	var found_wall := false
	var d := PIT_PROBE_STEP
	while d <= PIT_MAX_DIST:
		var sx := player.global_position.x + into.x * d
		var sz := player.global_position.z + into.z * d
		var gy := chunk_manager._ground_y(sx, sz)
		if gy > feet + STEP_MAX:
			found_wall = true
		if found_wall and gy >= feet + PIT_MIN_RISE and _terrain_slope(sx, sz) <= PIT_WALK_SLOPE:
			return Vector3(sx, gy + 0.05, sz)
		d += PIT_PROBE_STEP
	return null


# Local terrain slope as tan(angle) via central differences on the same heightfield the mesh renders.
func _terrain_slope(x: float, z: float) -> float:
	if chunk_manager == null:
		return 0.0
	var e := 0.5
	var hx := (chunk_manager._ground_y(x + e, z) - chunk_manager._ground_y(x - e, z)) / (2.0 * e)
	var hz := (chunk_manager._ground_y(x, z + e) - chunk_manager._ground_y(x, z - e)) / (2.0 * e)
	return sqrt(hx * hx + hz * hz)


func _process(delta: float) -> void:
	# AIRBORNE render-scale: the wide top-down view when flying is fill-rate-bound, so drop the 3D resolution
	# while airborne (bilinear-upscaled — barely visible from altitude) and restore it on the ground. Set only
	# on CHANGE; reallocating the 3D buffer every frame would stutter.
	# fill-rate cut for mobile: the sustained camp lag is per-pixel 3D shading, so render the 3D at a lower
	# internal resolution (bilinear-upscaled). 0.75->0.58 ground / 0.5->0.44 air — a big pixel-count cut a weak
	# mobile GPU feels directly; barely visible with the 2D HUD at full res.
	# CAPTURE IS NOT A PHONE — but it is something WORSE. The recorder has no GPU at all; swiftshader
	# rasterizes every pixel on the CPU, so this scale costs frame rate quadratically and there is no
	# hardware headroom to absorb it. At 0.58 the 3D is rasterized at 209x452 and stretched on the
	# phone, which is genuinely soft; at 1.0 it is sharp and arrives 2.5 times a second, which is
	# worse. Both arms were measured on the live service, 30s of the same game: 7.0fps vs 2.5fps.
	#
	# So this stays a knob (?capture=1&rscale=0.75), and the knob is not where the real win is. The
	# recorder is bound by having to produce frames in REAL TIME; the sharpness ceiling moves when
	# that constraint goes, not when this number does.
	var want_scale := capture_render_scale if capture_mode else \
		(0.44 if (active_vehicle != null and is_instance_valid(active_vehicle) and active_vehicle._airborne) else 0.58)
	if not is_equal_approx(get_viewport().scaling_3d_scale, want_scale):
		get_viewport().scaling_3d_scale = want_scale
	if cam_rig and player:
		# Rig follows the player; yaw/pitch come from drag-look. The SpringArm
		# keeps the camera aimed at the head and pulls it in through walls.
		var head := CAM_HEAD
		# HIDDEN driver (closed-cabin modeled vehicle / tank swap-in): the player is parked at
		# the body origin, so the head pivot sits INSIDE the hull — lift it so the orbit reads
		# over the roof. Keyed on visibility, not body type: any hidden-driver ride has this.
		if active_vehicle != null and is_instance_valid(active_vehicle) and not player.visible:
			head += 0.6
		# CONTRACT B: while driving AND not drag-looking, ease the orbit behind the vehicle. Manual
		# drag-look (look_idx != -1) overrides so the player keeps camera control. Composes with the
		# Wave 1.5 hidden-driver head-lift above (both keyed on active_vehicle).
		if active_vehicle != null and is_instance_valid(active_vehicle) and look_idx == -1:
			cam_yaw = lerp_angle(cam_yaw, active_vehicle.rotation.y + PI, minf(1.0, 3.0 * delta))
		# physics_interpolation is ON, so player.global_position is the STEPPED physics transform; reading it in
		# _process would make the interpolated world slide against the camera. Follow the INTERPOLATED origin so
		# the camera tracks exactly what the renderer draws (identical to global_position when FPS==tick rate).
		cam_rig.global_position = player.get_global_transform_interpolated().origin + Vector3(0.0, head, 0.0)
		cam_rig.rotation.y = cam_yaw
		cam_spring.rotation.x = cam_pitch
		# SpringArm collapse guard: when a prop/wall squeezes the camera onto the player, the view
		# renders from INSIDE the hero mesh (a full-screen smear of cape/armor). Hide the avatar
		# while the camera is that close — standard near-camera treatment.
		if _hero_avatar != null and is_instance_valid(_hero_avatar):
			var cd := cam.global_position.distance_to(cam_rig.global_position)
			_hero_avatar.visible = cd > 1.35
	# Wave 4: attack timers + the melee swing visual moved HERE from the two physics paths
	# (which early-return while DRIVING) so a MOUNTED rider's swing still animates/decays and
	# the ranged cooldown keeps ticking — riders fire too. Same 0.22s window and the exact
	# hardcoded-sword formula, now routed at the GEquipSlot pivot. Non-melee weapons keep the
	# orientation GEquip gave them (no -10° idle stomp on a bow).
	swing_t = maxf(0.0, swing_t - delta)
	_fire_cd = maxf(0.0, _fire_cd - delta)
	# idle/walk/run/attack state machine (on foot; riders are GPose-posed). Motion is passed as
	# DATA so the SAME machine drives a network peer off an interpolated transform (netsync) —
	# see hero_anim.gd. Guard mirrors the old in-function one: no body, no motion, no update.
	if player != null and is_instance_valid(player):
		_hero_anim_state.update(delta, {
			"speed": Vector2(player.velocity.x, player.velocity.z).length(),
			"vy": player.velocity.y,
			"on_floor": player.is_on_floor(),
			"swimming": swimming,
			"mounted": active_vehicle != null and is_instance_valid(active_vehicle),
		})
	_fade_near_camera_enemies()   # #6: hide any enemy pressed against the camera lens so it can't "pop up"
	# Mobile-OOM telemetry: the QA gate (verify.mjs) reads the PEAK GOGI_VRAM_MB over the world-start
	# window to fail-close a build that would blow a phone's GPU budget. RENDER_TEXTURE_MEM_USED is the
	# dominant, controllable term (streamed Meshy textures) — the WEB texture cap (GSurf) shrinks it.
	# Throttled ~every 2s; web-only (the number is meaningless / unread on native).
	if _on_web:
		_vram_t += delta
		if _vram_t >= 2.0:
			_vram_t = 0.0
			var texmb := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
			var vidmb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
			print("GOGI_VRAM_MB tex=%.1f video=%.1f" % [texmb, vidmb])
	# SOAK-ONLY PLAYER STATE DUMP. Headless probes could always prove a rule FIRED (GOGI_RULE_FIRED)
	# and never that firing CHANGED anything — every player-facing bug this pass found was caught by
	# a human looking at the screen instead. One line a second, only under --soak/?soak=1, makes
	# position / health / speed / frozen / weapon checkable from a log.
	if auto_roam:
		_pstate_t += delta
		if _pstate_t >= 1.0:
			_pstate_t = 0.0
			var pp2 := player.global_position if player != null else Vector3.ZERO
			print("GOGI_PSTATE pos=%.1f,%.1f,%.1f hp=%.0f/%.0f spd=%.1f frozen=%s wpn=%s live=%d" % [
				pp2.x, pp2.y, pp2.z,
				(rpg.hp if rpg != null else 0.0), (rpg.max_hp if rpg != null else 0.0),
				move_speed, str(input_frozen),
				(rpg.equipped_weapon if rpg != null else "-"), _spawned.size()])
	# COMBAT WARM-UP, on the first frame the world actually exists.
	#
	# _boot was the obvious home for this and it is too early: `current_root` is still null there,
	# because the streamer has not built the first area yet — the call sat behind a guard that never
	# opened and printed nothing, which is precisely the silent no-op this whole engine keeps growing.
	# Driven from here it also covers chunk mode and world swaps, both of which replace current_root.
	if not _combat_warmed:
		var ws = chunk_manager if chunk_mode else scene_manager
		if ws != null and ws.current_root != null and is_instance_valid(ws.current_root) and player != null:
			_combat_warmed = true
			GProjectile.prewarm(ws.current_root, player.global_position + Vector3(0.0, 0.6, 0.0))

	_tick_damage_marks(delta)

	# Peer-sync health, on screen, every frame. Drawn here rather than in _relayout_ui (where the
	# hudgrid overlay lives) because buffer depth changes constantly — a snapshot of it taken once at
	# layout time would be worse than useless, it would look authoritative and be stale.
	if mp_debug:
		if _mp_dbg_lbl == null or not is_instance_valid(_mp_dbg_lbl):
			_mp_dbg_lbl = Label.new()
			_mp_dbg_lbl.add_theme_font_size_override("font_size", 18)
			_mp_dbg_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
			_mp_dbg_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
			_mp_dbg_lbl.add_theme_constant_override("shadow_offset_y", 2)
			_mp_dbg_lbl.z_index = 100
			hud_layer.add_child(_mp_dbg_lbl)
		_mp_dbg_lbl.text = netsync.debug_line() if netsync != null else "mp: no netsync"
		_mp_dbg_lbl.reset_size()
		var si2 := _safe_insets()
		_mp_dbg_lbl.position = Vector2(si2.x + 12.0, si2.y + 12.0)

	if weapon_slot != null and is_instance_valid(weapon_slot) \
			and String(_equipped_def().get("kind", "melee")) == "melee":
		weapon_slot.rotation_degrees.x = (-90.0 + (1.0 - swing_t / 0.22) * 120.0) if swing_t > 0.0 else -10.0
	if chunk_mode and chunk_manager != null:
		chunk_manager.tick(delta)
	if stats:
		_refresh_stats()


# ---------------- HUD ----------------

func _update_stats() -> void:
	_refresh_stats()
	if hp_bar and rpg:
		hp_bar.size.x = 220.0 * clamp(rpg.hp / rpg.max_hp, 0.0, 1.0)


func _refresh_stats() -> void:
	if rpg == null:
		return
	var inv := rpg.inventory_summary()
	if inv.length() > 46:
		inv = inv.substr(0, 43) + "..."
	stats.text = "Lv %d  HP %d/%d  XP %d/%d  Gold %d\nWpn: %s\nInv: %s" % [
		rpg.level, int(rpg.hp), int(rpg.max_hp), rpg.xp, rpg.xp_next, rpg.gold,
		rpg.item_name(rpg.equipped_weapon), inv]


# ---------------- combat / hooks ----------------

# The ONE attack entry (the HUD ATTACK button): routes by the equipped weapon's kind.
# melee -> the Wave-1 swing, byte-identical semantics (2.6u reach, forward half-cone,
# enemy.take_hit). ranged/thrown -> _fire_ranged (auto-aim + pooled GProjectile). The button
# stays LIVE while DRIVING/MOUNTED — only _physics_process's movement routing is gated on
# active_vehicle, Button.pressed never passes through it — so riders fire too.
## Hide any enemy that presses against the camera lens (#6) so a body up close can't fill the frame like
## a "popup". main runs the distance test because the SpringArm masks world-only and never collides with
## enemies (layer 4). Giant enemies are also scale-capped at spawn (enemy.gd MAX_ENEMY_H).
func _fade_near_camera_enemies() -> void:
	if cam == null or not is_instance_valid(cam):
		return
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer == null:
		return
	var cp := cam.global_position
	for e in streamer.enemies:
		if is_instance_valid(e) and e.has_method("set_camera_near"):
			# measure to the body CENTRE, not the feet origin — the camera rides ~1.5-2m up, so a
			# feet-distance test never fired for tall models and a melee monster walled the frame
			var bh := 1.8
			var bhv = e.get("body_h")
			if bhv != null:
				bh = float(bhv)
			e.set_camera_near(cp.distance_to(e.global_position + Vector3(0.0, 0.5 * bh, 0.0)))


func _attack() -> void:
	if _weapon_stowed:
		_toggle_weapon()   # draw the weapon to strike — a sheathed weapon never blocks combat
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer == null or streamer.transitioning:
		return
	var def := _equipped_def()
	var kind := String(def.get("kind", "melee"))
	if kind == "ranged" or kind == "thrown":
		_fire_ranged(def, streamer)
		return
	if swing_t > 0.0:
		return
	swing_t = 0.22
	_hero_anim_state.attack_t = 0.45   # play the melee swing body animation
	_hero_anim_state.play("attack")
	AudioManager.play_sfx("attack")
	var dmg := rpg.weapon_damage()
	var fwd := player.global_transform.basis.z   # forward=+Z (look_at(pos-dir) faces +Z); -basis.z hit BEHIND (inverted cone)
	# DIRECT HIT: strike only the SINGLE CLOSEST foe inside a real forward swing arc — not every body in
	# a ~150° hemisphere. The old `length < 2.6 and dot > 0.25` sprayed FULL damage across the whole
	# surrounding pack (one tap wiped a group) and let a near-miss "kill by proximity". Acquire the
	# nearest foe roughly ahead, turn to face it (the blow reads as aimed), then land ONE hit.
	var target = null
	var target_d := 2.4   # melee reach, metres
	for e in streamer.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var to: Vector3 = e.global_position - player.global_position
		to.y = 0.0
		var d := to.length()
		if d > 0.001 and d < target_d and fwd.dot(to / d) > 0.35:
			target = e
			target_d = d
	if target == null:
		# AIM ASSIST (mobile): nothing in the forward cone, but a foe is within REACH — acquire the
		# nearest one in ANY direction. A stationary ATTACK tap must never whiff while an enemy
		# gnaws at the player's back (enemies circle their surround slots, so "behind" is common).
		# Still ONE target, still full reach, and the look_at below turns the body so the blow
		# reads as aimed — not a proximity kill.
		target_d = 2.4
		for e in streamer.enemies:
			if not is_instance_valid(e) or e.dead:
				continue
			var to2: Vector3 = e.global_position - player.global_position
			to2.y = 0.0
			var d2 := to2.length()
			if d2 > 0.001 and d2 < target_d:
				target = e
				target_d = d2
	if target != null:
		var tp: Vector3 = target.global_position
		player.look_at(Vector3(tp.x, player.global_position.y, tp.z), Vector3.UP)   # face the struck foe
		target.take_hit(dmg)
		_hit_spark(tp + Vector3(0.0, 1.0, 0.0))


# JUICE FLOOR: a one-shot spark burst at the melee impact point (ranged already puffs via
# GProjectile) — a hit you can't SEE land reads as broken combat.
func _hit_spark(at: Vector3) -> void:
	var streamer = chunk_manager if chunk_mode else scene_manager
	var root: Node3D = streamer.current_root if streamer != null else null
	if root == null or not is_instance_valid(root):
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 16
	p.lifetime = 0.45
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 7.0
	p.direction = Vector3(0, 1, 0)
	p.spread = 70.0
	p.gravity = Vector3(0, -9, 0)
	p.scale_amount_min = 0.06
	p.scale_amount_max = 0.16
	p.color = Color(1.0, 0.9, 0.5)
	root.add_child(p)
	p.global_position = at
	p.emitting = true
	var tw := p.create_tween()
	tw.tween_interval(0.8)
	tw.tween_callback(p.queue_free)


# The live equipped-weapon def: GEquip stamps "gequip_def" on the character at equip time;
# before the first equip lands (async boot) fall back to the catalog def for the equipped id.
func _equipped_def() -> Dictionary:
	if player != null and player.has_meta("gequip_def"):
		var d = player.get_meta("gequip_def")
		if d is Dictionary:
			return d
	return rpg.weapon_def(rpg.equipped_weapon) if rpg != null else {}


# Wave 4 ranged/thrown fire — mobile-first AUTO-AIM: the NEAREST live enemy inside the
# FIRE_CONE_DEG cone of the character's facing AND inside weapon range is aimed at its chest
# (+1.0m); none in the cone -> straight ahead. The per-weapon rate gates repeat taps.
# MOUNTED riders compose for free: the GEquipSlot rides the player, which vehicle.gd's
# _track_driver parks (and faces) on the boardable every tick — origin + facing follow, no
# special casing. Facing is +basis.z, the stack convention (characters FACE +Z — see
# vehicle.gd / GPose); melee's legacy -basis.z half-cone above is untouched by contract.
func _fire_ranged(def: Dictionary, streamer) -> void:
	if _fire_cd > 0.0:
		return
	var root: Node3D = streamer.current_root
	if root == null or not is_instance_valid(root):
		return
	_fire_cd = 1.0 / maxf(0.1, float(def.get("rate", 1.2)))
	var fwd: Vector3 = player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.BACK
	var rng := maxf(1.0, float(def.get("range", 20.0)))
	var cone := cos(deg_to_rad(FIRE_CONE_DEG * 0.5))
	var best: Node3D = null
	var bd := rng   # nearest-wins inside the cone
	# AUTO-AIM READS THE SAME LIST DAMAGE DOES. It used to iterate streamer.enemies directly, so the
	# assist that makes ranged combat playable on a touchscreen simply did not see other players —
	# you could damage someone the game would never help you point at.
	for e in _live_enemies():
		if not is_instance_valid(e) or e.get("dead"):
			continue
		var to: Vector3 = (e as Node3D).global_position - player.global_position
		to.y = 0.0
		var d := to.length()
		if d < 0.01 or d > bd:
			continue
		if fwd.dot(to / d) < cone:
			continue
		bd = d
		best = e
	# muzzle = the GEquipSlot (weapon tip-ish) + a small forward offset; slot not attached
	# yet (async equip in flight) -> chest height on the player. in_tree guard: NEVER read a
	# global transform off a detached node (doctrine).
	var muzzle: Vector3 = player.global_position + Vector3(0.0, 1.2, 0.0)
	if weapon_slot != null and is_instance_valid(weapon_slot) and weapon_slot.is_inside_tree():
		muzzle = weapon_slot.global_position
	muzzle += fwd * MUZZLE_FWD
	var dir: Vector3 = fwd
	if best != null:
		dir = ((best.global_position + Vector3(0.0, 1.0, 0.0)) - muzzle).normalized()
	AudioManager.play_sfx("attack")
	GProjectile.flash(muzzle, root)
	GProjectile.fire(root, muzzle, dir, def, _live_enemies)
	# EVERY OTHER PLAYER HAS TO SEE THIS SHOT. Projectiles were purely local, so a victim was hit by
	# nothing, from nowhere — no tracer, no muzzle flash, no sound with a direction. Being shot at was
	# literally invisible, which is not a feedback problem so much as an absence of the event itself.
	if netsync != null and netsync.has_method("report_shot"):
		netsync.report_shot(muzzle, dir, def)
	if director != null and director.has_method("fire"):
		director.fire("weapon_fired", {"id": String(def.get("id", "")), "kind": String(def.get("kind", ""))})


# enemies_provider handed to GProjectile.fire — always the ACTIVE streamer's live union
# (chunk resident ring / zone area), so a projectile in flight never holds a stale list.
func _live_enemies() -> Array:
	var streamer = chunk_manager if chunk_mode else scene_manager
	var out: Array = streamer.enemies.duplicate() if streamer != null else []
	# OTHER PLAYERS ARE TARGETS. This one line is what a bullet needed to know they exist — the hit
	# test was never about enemies specifically, only about a list it was handed, and peers were
	# never in it. Duplicated rather than appended in place: this array IS the streamer's own live
	# enemy list, and pushing players into it would leak them into every AI query in the engine.
	if netsync != null and netsync.has_method("peer_bodies"):
		out.append_array(netsync.peer_bodies())
	return out


# Keep the ATTACHED weapon visual in sync with rpg.equipped_weapon (boot start_weapon, chest
# auto-equip upgrades, hot-reload re-stats). "parametric:*" models attach with no fetch;
# library//BUILD_ID GLBs prefetch through the SHARED builder cache (the vehicles' path).
# Loops because equipped_weapon can change again during the await; GEquip.equip is
# idempotent, one weapon at a time.
func _sync_equip_visual() -> void:
	if _equip_busy or player == null or rpg == null:
		return
	_equip_busy = true
	while _equipped_visual_id != rpg.equipped_weapon:
		var id: String = rpg.equipped_weapon
		var def: Dictionary = rpg.weapon_def(id)
		var model: Node3D = null
		var mu := String(def.get("model", ""))
		if mu != "" and not mu.begins_with("parametric:"):
			var u := _norm(mu)
			if u != "":
				await builder._ensure([u])
				if builder.cache.has(u) and builder.cache[u] != null:
					model = (builder.cache[u] as Node).duplicate() as Node3D
		GEquip.equip(player, def, model)
		weapon_slot = player.find_child("GEquipSlot", true, false) as Node3D
		if weapon_slot != null:
			weapon_slot.visible = not _weapon_stowed   # a mid-ride re-equip must not un-stow (Wave 1.5)
		_equipped_visual_id = id
	_equip_busy = false


func _on_rpg_changed() -> void:
	if rpg != null and _equipped_visual_id != rpg.equipped_weapon:
		# a newly equipped weapon DRAWS immediately (found in a chest / cycled on the HUD) —
		# equipping into a sheathed hand read as "weapons don't equip". Vehicle stow is kept.
		if _weapon_stowed and (active_vehicle == null or not is_instance_valid(active_vehicle)):
			_set_weapon_stowed(false)
			if _weapon_btn != null and is_instance_valid(_weapon_btn):
				_weapon_btn.text = "SHEATHE"
		_sync_equip_visual()   # fire-and-forget — the latch + loop absorb re-entry


func take_damage(d: float) -> void:
	AudioManager.play_sfx("hurt")
	_flash_hurt(false)   # brief red flash so the hit READS — non-modal, never a banner/popup/dialog
	if director != null:
		director._shake_cam(0.15)   # small kick so a hit taken lands physically, not just as a tint
		director.fire("player_damaged", {"amount": d})
	var fatal := false
	if chunk_mode:
		fatal = rpg.take_damage(d)
	else:
		if scene_manager == null or scene_manager.transitioning:
			return
		fatal = rpg.take_damage(d)
	if not fatal:
		return

	# DEATH IS OPT-IN, AND THE OPT-IN IS THE GAME'S OWN RULES (game_shell.wants_death). A world that
	# never mentions `player_died` or `lose` keeps the original behaviour exactly: heal to full, carry
	# on, never interrupt play. A world that DOES handle dying gets a real failure state instead of
	# having the engine quietly undo it.
	if director != null and director.has_method("wants_death") and director.wants_death():
		rpg.hp = 0.0
		director.fire("player_died", {})
		if director.has_method("_show_defeat"):
			director._show_defeat()
		return

	rpg.hp = rpg.max_hp
	_flash_hurt(true)              # stronger pulse marks the recovery instead of a modal "you died"
	# CHECKPOINT FIRST. `set_spawn` is only a checkpoint if the engine's own recovery honours it —
	# a spawn point that just sits there until an author remembers to also write `respawn` is a
	# setting that does nothing, which is the failure this whole pass exists to remove.
	if _spawn_point != null:
		player.global_position = _spawn_point
		player.velocity = Vector3.ZERO
		return
	if chunk_mode:
		return                     # in place — no area transition exists in chunk mode
	# AREA RELOAD ONLY WHEN THERE IS SOMETHING TO RELOAD. This used to fire unconditionally, which
	# rebuilt the area root and silently destroyed every rule-spawned enemy standing in it — a wave
	# game reset its own difficulty each time it managed to overwhelm the player, with nothing in the
	# log. Respawning in place keeps the wave intact and the reset visible in health, not in geometry.
	if _spawned.is_empty():
		scene_manager.goto_area(scene_manager.current_id, scene_manager.areas[scene_manager.current_id].spawns.keys()[0])
	else:
		var sp = scene_manager.areas[scene_manager.current_id].get("spawns", {})
		if sp is Dictionary and not (sp as Dictionary).is_empty():
			var first = (sp as Dictionary).values()[0]
			if first is Array and (first as Array).size() >= 3:
				player.global_position = Vector3(float(first[0]), float(first[1]), float(first[2]))


# ---------------- rule-layer player state (phase 6) ----------------
#
# Eight actions the rule vocabulary has always NAMED and never had: teleport_player, set_health,
# give_weapon, set_speed, freeze, unfreeze, respawn, set_spawn. Every one lands here rather than in
# rules.gd, because each needs something only main owns (the body, the streamer, the equip visual),
# and because a director-owned version would go dead in any world that ships its own director.
#
# All of them return a bool: rules.gd logs the failures instead of pretending they took.


## The ground height under a point, from whichever streamer this world runs. Returns `y` unchanged
## when neither can answer, so a teleport into an un-streamed cell still lands somewhere sane.
func _ground_at(x: float, z: float, fallback: float) -> float:
	if chunk_manager != null and chunk_manager.has_method("_ground_y"):
		return chunk_manager._ground_y(x, z)
	return fallback


## Move the player. `to.y` is honoured when the caller means it (a tower, a balcony); pass
## `snap_ground` for the common case of "put them over there" where the author gave a floor-level y
## that the terrain has since risen above.
func teleport_player_to(to: Vector3, snap_ground := true) -> bool:
	if player == null:
		return false
	var y := to.y
	if snap_ground:
		y = maxf(to.y, _ground_at(to.x, to.z, to.y))
	player.global_position = Vector3(to.x, y, to.z)
	player.velocity = Vector3.ZERO   # arrive standing still — carried momentum reads as a shove
	if active_vehicle != null and is_instance_valid(active_vehicle):
		active_vehicle.global_position = player.global_position   # the rider takes the ride along
	print("GOGI_TELEPORT player -> %.1f,%.1f,%.1f" % [to.x, y, to.z])
	return true


## Where `respawn` and the engine's forgiving recovery put the player: the `set_spawn` checkpoint if
## one was set, else the area's first authored spawn, else where they already stand.
func player_spawn_point() -> Vector3:
	if _spawn_point != null:
		return _spawn_point
	if not chunk_mode and scene_manager != null and scene_manager.areas.has(scene_manager.current_id):
		var sp = (scene_manager.areas[scene_manager.current_id] as Dictionary).get("spawns", {})
		if sp is Dictionary and not (sp as Dictionary).is_empty():
			var f = (sp as Dictionary).values()[0]
			if f is Array and (f as Array).size() >= 3:
				return Vector3(float(f[0]), float(f[1]), float(f[2]))
	return player.global_position if player != null else Vector3.ZERO


func set_spawn_point(to: Vector3) -> bool:
	_spawn_point = Vector3(to.x, maxf(to.y, _ground_at(to.x, to.z, to.y)), to.z)
	print("GOGI_SPAWNPOINT %.1f,%.1f,%.1f" % [_spawn_point.x, _spawn_point.y, _spawn_point.z])
	return true


## Back to the spawn point, alive. NOT a restart: spawned enemies, vars, quests and the clock all
## carry on — this is the "you fell in the pit" recovery, not the "start over" one.
func respawn_player(heal := true) -> bool:
	if player == null:
		return false
	teleport_player_to(player_spawn_point(), false)
	if heal and rpg != null:
		rpg.hp = rpg.max_hp
		rpg.changed.emit()
	# Respawning is a statement that the run CONTINUES, so a DEFEATED modal must not survive it. Left
	# up, it blocks input over a player who is alive, healed and standing at their spawn point.
	if director != null and director.has_method("clear_defeat"):
		director.clear_defeat()
	return true


## Absolute walk speed in m/s (base 6). Swim scales with it; jump, climb and vehicles do not — those
## have their own physics and a "fast" potion that also doubled jump height would read as a bug.
func set_player_speed(v: float) -> bool:
	move_speed = clampf(v, 0.0, MAX_MOVE_SPEED)
	print("GOGI_SPEED %.1f" % move_speed)
	return true


func set_frozen(on: bool) -> bool:
	input_frozen = on
	if on and player != null:
		player.velocity = Vector3.ZERO   # stop dead, don't coast on into the wall
	print("GOGI_FREEZE %s" % ("on" if on else "off"))
	return true


## Set health outright. `mx > 0` also raises/lowers the ceiling (a max-hp upgrade), applied FIRST so
## `{"hp": 200, "max": 200}` in one action does what it reads like.
##
## Hitting zero routes through the same opt-in death switch as damage does, so a rule that sets
## health to 0 kills the player in a world with a failure state and heals them in one without —
## rather than parking the HUD at 0 hp and playing on, which is what a bare assignment would do.
func set_player_health(hp: float, mx: float) -> bool:
	if rpg == null:
		return false
	if mx > 0.0:
		rpg.max_hp = mx
	rpg.hp = clampf(hp, 0.0, rpg.max_hp)
	rpg.changed.emit()
	if rpg.hp <= 0.0:
		if director != null and director.has_method("wants_death") and director.wants_death():
			director.fire("player_died", {})
			if director.has_method("_show_defeat"):
				director._show_defeat()
		else:
			rpg.hp = rpg.max_hp
			rpg.changed.emit()
			respawn_player(false)
	return true


## Put a weapon in the player's hands. Unknown ids are REGISTERED as weapons first (normalized
## defaults) — an author naming a weapon the world's catalog never declared gets a working sword
## rather than a silent no-op, and the id is then equippable like any other.
func give_weapon(id: String, equip_it: bool) -> bool:
	if rpg == null or id == "":
		return false
	rpg.ensure_weapon(id)
	if not rpg.has_item(id):
		rpg.add_item(id)
	if equip_it:
		rpg.equip(id, true)   # force: an explicitly granted weapon beats the DPS auto-equip gate
		_sync_equip_visual()  # not awaited — the per-frame watcher finishes the attach either way
	return true


## Drop freed entities from the streamer's target list so weapons never chase a dead reference.








func _prune_enemy_list() -> void:
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer != null:
		streamer.enemies = streamer.enemies.filter(func(x): return is_instance_valid(x))


## Start the run over. The defeat panel's button used to be the VICTORY button's callback — it hid
## the panel and nothing else, so "TRY AGAIN" left the player standing at zero health beside the boss
## that had just killed them, unable to do anything. A restart has to actually restart: reloading the
## scene re-runs boot, re-fetches world.json and rebuilds every system from scratch, which is the
## only version of this that cannot leave a half-reset state behind.
func restart_run() -> void:
	print("GOGI_RESTART")
	# IN-PLACE, NOT A SCENE RELOAD. Reloading was triggered from inside a Button's input dispatch on
	# a tree about to be freed; on web the page came back drawn but unresponsive. A retry does not
	# need new nodes, it needs start values — so nothing is rebuilt and the input path is never torn
	# down. Deferred so the click that asked for it finishes first.
	call_deferred("_do_restart")


func _do_restart() -> void:
	for e in _spawned:
		if is_instance_valid(e):
			e.queue_free()
	_spawned.clear()
	_spawn_queue.clear()
	_prune_enemy_list()
	# Rule-set player state is part of the run, so it resets with it. A retry that kept the freeze
	# that killed you, or the checkpoint from the attempt before, is not a retry.
	move_speed = BASE_MOVE_SPEED
	input_frozen = false
	_spawn_point = null
	if rpg != null:
		rpg.hp = rpg.max_hp
	if player != null and scene_manager != null and scene_manager.areas.has(scene_manager.current_id):
		var sp = (scene_manager.areas[scene_manager.current_id] as Dictionary).get("spawns", {})
		if sp is Dictionary and not (sp as Dictionary).is_empty():
			var f = (sp as Dictionary).values()[0]
			if f is Array and (f as Array).size() >= 3:
				player.global_position = Vector3(float(f[0]), float(f[1]), float(f[2]))
	if director != null and director.has_method("reset_run"):
		director.reset_run()


## `collect` / `use_item`. Fired for EVERY acquisition and every consumption, whatever the route —
## a chest, a quest reward, the potion button, or a rule's own `grant`. Including rule-driven ones
## is deliberate: "the player now has the key" is the same fact however the key arrived, and the
## cascade budget already guards the one risk (a collect rule that grants what it watches for).
func _on_item_added(id: String, qty: int) -> void:
	if director == null or not director.has_method("fire"):
		return
	director.fire("collect", {"id": id, "qty": qty, "count": rpg.item_count(id)})


func _on_item_used(id: String) -> void:
	if director == null or not director.has_method("fire"):
		return
	director.fire("use_item", {"id": id, "count": rpg.item_count(id)})


# ---------------- entity lookup for rule CONDITIONS (`alive`, `distance_to`) ----------------
#
# Deliberately scans BOTH registries. `_spawned` holds what rules spawned; the streamer holds what
# the world authored. A condition that only saw one of them would be right in the probe that built
# its enemy the same way the author of the check did, and quietly wrong everywhere else — an
# `{"alive": "boss"}` on an area-authored boss reading false while the boss walks around.


## Every live entity matching `name`, tested against its rule id first and its kind second, so
## `{"alive": "boss"}` works whether "boss" was a spawn id or an enemy kind.
func find_entities(name: String) -> Array:
	var out: Array = []
	if name == "":
		return out
	var pools: Array = [_spawned]
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer != null and streamer.get("enemies") != null:
		pools.append(streamer.enemies)
	for pool in pools:
		for e in (pool as Array):
			if not is_instance_valid(e) or out.has(e):
				continue
			if String(e.get_meta("gogi_id", "")) == name or String(e.get("kind")) == name:
				out.append(e)
	return out


func entity_alive(name: String) -> bool:
	return not find_entities(name).is_empty()


## Distance from the player to the NEAREST match, or -1.0 when nothing matches. -1 rather than a
## huge number so callers can tell "far away" from "does not exist" — they mean different things to
## a `distance_to` comparison and collapsing them makes `<` silently true for a dead boss.
func entity_distance(name: String) -> float:
	if player == null:
		return -1.0
	var best := -1.0
	for e in find_entities(name):
		var d: float = player.global_position.distance_to((e as Node3D).global_position)
		if best < 0.0 or d < best:
			best = d
	return best


## Point every live spawned enemy of `kind` (or all of them) at the player. `set_target` maps here
## too — the engine has exactly one target, so both actions mean "notice the player now".
func aggro_enemies(kind: String) -> int:
	var n := 0
	for e in _spawned:
		if not is_instance_valid(e):
			continue
		if kind != "" and String(e.get("kind")) != kind:
			continue
		e.set("player", player)
		n += 1
	return n


# Non-modal damage feedback: pulse the red overlay and fade it out. `strong` = a bigger pulse for the
# in-place recovery (hp hit 0). NEVER a popup/banner/dialog — a hit must never interrupt play.
func _flash_hurt(_strong: bool) -> void:
	# DISABLED by request: no on-hit screen overlay at all. The full-screen red flash read as an
	# intrusive "popup" when the player was attacked. Damage still registers (hp, audio, camera kick);
	# there is simply no visual interrupt. Kept as a no-op so every existing call site stays valid.
	return


## Note where damage came from, in SCREEN space, so the arc points the right way as the camera turns.
## The angle is stored relative to the camera's yaw at the moment of the hit and re-resolved every
## frame — bake a screen angle once and it lies the instant the player looks around, which is exactly
## what they do when shot.
func _mark_damage_from(world_pos: Vector3) -> void:
	if player == null:
		return
	var to := world_pos - player.global_position
	to.y = 0.0
	if to.length() < 0.01:
		return
	_dmg_marks.append([atan2(to.x, to.z), DMG_MARK_S])
	if _dmg_marks.size() > 4:
		_dmg_marks.pop_front()


func _tick_damage_marks(delta: float) -> void:
	if _dmg_marks.is_empty():
		if _dmg_layer != null and is_instance_valid(_dmg_layer):
			_dmg_layer.visible = false
		return
	var keep: Array = []
	for m in _dmg_marks:
		m[1] = float(m[1]) - delta
		if float(m[1]) > 0.0:
			keep.append(m)
	_dmg_marks = keep
	if _dmg_layer == null or not is_instance_valid(_dmg_layer):
		_dmg_layer = Control.new()
		_dmg_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		_dmg_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never eat a tap meant for the game
		_dmg_layer.z_index = 90
		_dmg_layer.draw.connect(_draw_damage_marks)
		hud_layer.add_child(_dmg_layer)
	_dmg_layer.visible = true
	_dmg_layer.queue_redraw()


func _draw_damage_marks() -> void:
	var vp := _dmg_layer.size
	var mid := vp * 0.5
	var radius: float = minf(vp.x, vp.y) * 0.36
	for m in _dmg_marks:
		var world_ang := float(m[0])
		var life := float(m[1]) / DMG_MARK_S
		# Relative to where the camera is looking RIGHT NOW, so turning toward the shooter walks the
		# arc to the top of the screen and turning away pushes it behind you.
		var screen_ang := world_ang - cam_yaw
		var col := Color(0.95, 0.25, 0.2, clampf(life, 0.0, 1.0) * 0.85)
		var pts := PackedVector2Array()
		var half := deg_to_rad(19.0)
		for i in range(13):
			var a := screen_ang - half + (2.0 * half) * (float(i) / 12.0)
			pts.append(mid + Vector2(sin(a), -cos(a)) * radius)
		_dmg_layer.draw_polyline(pts, col, 7.0, true)


func on_enemy_killed(type: String) -> void:   # called by enemy.gd on death
	AudioManager.play_sfx("death")
	if rpg:
		rpg.grant_xp(15)
	if quest:
		quest.notify_kill(type)
	if director != null and director.has_method("on_kill"):
		director.on_kill(type)   # optional victory hook (boss defeat -> win screen)


# ---------------- live hot-reload from chat edits ----------------

## Parse JSON to a Dictionary WITHOUT the engine printing "Parse JSON failed" on a bad body (a 503 error
## page, a truncated edge-cache response, or an in-flight write). The static JSON.parse_string() pushes a
## global ERROR on a malformed body even when the caller handles the null; JSON.new().parse() returns an
## error code silently. Returns {} on any failure. (#17 — boot/poll JSON hardening.)
func _json_dict(text: String) -> Dictionary:
	var j := JSON.new()
	if j.parse(text) != OK:
		return {}
	return j.data if j.data is Dictionary else {}


# Re-fetch quests.json and push the DEFINITIONS into the live quest system, preserving progress.
# Called from _poll_world after an applied world.json change (the two files are authored + gated
# together by qgcheck, so an edit to one is the right moment to re-read the other). Deliberately
# does NOT re-run the boot-time `auto_start` sweep: those quests were already started at boot, and
# re-starting them would reset a completed chain back to active every time the world is edited.
func _reload_quests() -> void:
	var qq := HTTPRequest.new()
	add_child(qq)
	qq.request(world_url.replace("world.json", "quests.json") + "?t=" + str(Time.get_ticks_msec()))
	var qr = await qq.request_completed
	qq.queue_free()
	if qr[1] != 200:
		return
	var qdata = JSON.parse_string((qr[3] as PackedByteArray).get_string_from_utf8())
	if not (qdata is Dictionary):
		return   # silent — a truncated/error poll body degrades quietly, matching _poll_world
	quests_data = qdata
	quest.reload_quests(qdata)
	# A quest ADDED by the edit has never been started; honour its auto_start so a newly-authored
	# chain becomes playable without a reload. Already-known ids are untouched (reload_quests kept
	# their state, and start() no-ops on anything not "inactive").
	for _q in qdata.get("quests", []):
		if _q is Dictionary and bool(_q.get("auto_start", false)):
			quest.start(String(_q.get("id", "")))


func _poll_world() -> void:
	# re-fetch world.json; if a chat edit changed it (qgcheck already gated it server-side),
	# hot-reload the current area live. Cache-buster bypasses the edge cache.
	if scene_manager == null or scene_manager.transitioning or world_data.is_empty() or _polling:
		return
	_polling = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request(world_url + "?t=" + str(Time.get_ticks_msec()))
	var res = await req.request_completed
	req.queue_free()
	_polling = false
	if res[1] != 200:
		return
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw == _world_raw or raw.strip_edges() == "":
		return
	var w := _json_dict(raw)   # #17: silent parse — a truncated/error poll body degrades quietly, no console spam
	if w.is_empty():
		return
	# chunk worlds carry "cells"/"grid" (not "areas"); zone worlds carry "areas"
	if chunk_mode:
		if not w.has("cells"):
			return
	elif not w.has("areas"):
		return
	_world_raw = raw
	world_data = w
	_apply_weather(w)
	# QUESTS + REGIONS hot-reload. Both were previously boot-only: quests.json was fetched ONCE in
	# _boot and never again, and the director cached its region list in world_ready() at startup —
	# so a chat edit to a quest's target/count, or to a region's music/ambient/bounds, changed
	# NOTHING in the running game even though the edit path advertises a ~4s live update. The player
	# had to reload to see it, which quietly broke live iteration for exactly the data most worth
	# tweaking. Re-fetch alongside world.json and re-notify the director on every applied poll.
	# Quest PROGRESS is preserved: this goes through quest.reload_quests() (NOT load_quests(), which
	# resets st[] and is boot-only) — definitions refresh, live status/counters survive.
	await _reload_quests()
	# OPT-IN reload hook — deliberately NOT world_ready(). world_ready() is a BOOT lifecycle call and
	# real directors do one-time setup in it: a story director may start the quest chain, reset its
	# stage index, fire an opening toast and board the player onto a vehicle. Re-calling it on every world
	# edit would teleport the player back to the opening cutscene and restart their campaign — far
	# worse than the stale regions this is meant to fix. So directors advertise live-reload support
	# explicitly by implementing `world_reloaded()`, which must ONLY re-read data (regions, beacons,
	# tuning) and never re-run setup. A director without it is simply left alone — zero behavior
	# change for every existing game.
	if director != null and director.has_method("world_reloaded"):
		director.world_reloaded()
	# RELEASE A FREEZE ACROSS A LIVE EDIT. `freeze` is only ever undone by a later rule, and a chat
	# edit can delete or rewrite that rule — which would leave the player permanently immobile with
	# nothing left in the world able to release them. Speed is restored for the same reason. The
	# spawn checkpoint is NOT cleared: that is progress, not a modal state.
	if input_frozen:
		set_frozen(false)
	move_speed = BASE_MOVE_SPEED
	# Wave 4: a chat edit can re-stat "weapons" (damage/model/…). Reload the merged catalog and
	# re-attach the visual ONLY when the equipped def's content actually changed (deep ==).
	# Awaited so a weapon-model fetch is serialized BEFORE the streamer reload's downloads.
	var eq_before: Dictionary = rpg.weapon_def(rpg.equipped_weapon)
	rpg.load_weapons(w.get("weapons", {}))
	# The multiplayer interest radius is derived from weapon RANGES, so a re-stat that lengthens a
	# gun has to move it too — netsync.configure() runs only when a room is joined and never again.
	# Without this the projectile flies the new distance while peers past the OLD radius still have
	# no body, so shots at them pass through. Ahead of the awaits below on purpose: it is one loop
	# over a dict, and it must not be able to land after a model fetch.
	if netsync != null and netsync.has_method("refresh_interest"):
		netsync.refresh_interest(w.get("weapons", null))
	if rpg.weapon_def(rpg.equipped_weapon) != eq_before:
		_equipped_visual_id = ""
		await _sync_equip_visual()
	# vehicles-only rebuild when the world "vehicles" list changed (never touches the player or the
	# streamer). Awaited so its model fetch is serialized BEFORE the streamer reload's downloads.
	await _reload_vehicles(w)
	if chunk_mode:
		chunk_manager.reload(world_data)   # rebuild only CHANGED resident cells in place — no player move
	else:
		scene_manager.reload(world_data)   # no re-export — the live area rebuilds


# ---------------- drivable vehicles (world-level "vehicles", vehicle.gd) ----------------

# Spawn the world's "vehicles" ONCE onto a persistent layer (a direct child of main — chunk cell
# eviction and zone area frees can never reclaim it). Zone worlds get the same world-space
# placement. Models fetch through the SHARED builder cache (parallel, dedup'd); a world with no
# "vehicles" returns immediately — zero behavior change.
func _spawn_vehicles(world: Dictionary) -> void:
	var list = world.get("vehicles", [])
	if not (list is Array) or (list as Array).is_empty():
		_vehicles_spec = []
		return
	_vehicles_spec = (list as Array).duplicate(true)   # snapshot for the hot-reload diff
	if vehicle_root == null:
		vehicle_root = Node3D.new()
		add_child(vehicle_root)
	var urls: Array = []
	for spec in list:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		for u in _vehicle_part_urls(spec):   # body + (assembled) wheel + prop GLBs
			if u != "" and not urls.has(u):
				urls.append(u)
	await builder._ensure(urls)
	for spec in list:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		var pos = spec.get("pos", [])
		if not (pos is Array) or (pos as Array).size() < 2:
			continue
		var mu := _vehicle_model_url(spec)
		var model: Node3D = null
		if mu != "" and builder.cache.has(mu) and builder.cache[mu] != null:
			model = (builder.cache[mu] as Node).duplicate() as Node3D
		# Phase 3: an assembled vehicle also carries a wheel/prop GLB the engine instances into movers
		var parts := {}
		_add_part(parts, "wheel", spec.get("wheel_url", ""))
		_add_part(parts, "prop", spec.get("prop_url", ""))
		var car := Vehicle.new()
		car.player_ref = player
		car.set_meta("spec", spec)   # director reads stable_id/tamed_name for taming + summon
		car.setup(spec, model, parts)   # scale-normalize + AABB-ground + box collider + (assembled) moving wheels/prop
		vehicle_root.add_child(car)
		car.global_position = Vector3(float(pos[0]), 0.0, float(pos[1]))
		# HEADING: an explicit world.json vehicle "rot" (degrees about +Y) wins; otherwise a parked
		# AIRCRAFT auto-aligns DOWN the runway — the road strip in its own cell. Without this a parked
		# plane keeps its default +Z heading and sits ACROSS an east-west airstrip. The nose is oriented
		# to the body's +Z, so "ew" (east-west road) -> face +X (rot 90); "ns" -> keep +Z (rot 0).
		if spec.has("rot"):
			car.rotation.y = deg_to_rad(float(spec.get("rot", 0.0)))
		elif String(spec.get("profile", "car")) == "plane":
			var rdir := _runway_dir_at(world, float(pos[0]), float(pos[1]))
			if rdir == "ew":
				car.rotation.y = PI * 0.5   # nose -> +X, down an east-west runway
			elif rdir == "ns":
				car.rotation.y = 0.0        # nose -> +Z, down a north-south runway (already the default)
		car.drive_state_changed.connect(_on_vehicle_drive_state)
		interaction.add_vehicle(car)   # same touch/USE mechanism chests/NPCs use -> enter/exit
		vehicles.append(car)


# Dominant road direction ("ew" | "ns" | "") of the runway a parked aircraft sits on: tally the road
# `dir`s across the 3x3 cells around the plane's own cell (an airstrip spans several cells; a lone cell
# can be a bare pad). A crossroads cell ("x") counts for BOTH axes. "" when there is no road nearby
# (the plane keeps its default heading). Cells are the world.json chunk grid: [{cell:[cx,cz], roads:[…]}].
func _runway_dir_at(world: Dictionary, wx: float, wz: float) -> String:
	var cells = world.get("cells", [])
	if not (cells is Array):
		return ""
	var cs := float(world.get("grid", {}).get("cell_size", 16.0))
	if cs <= 0.0:
		cs = 16.0
	var cx := int(floor(wx / cs))
	var cz := int(floor(wz / cs))
	var ew := 0
	var ns := 0
	for c in cells:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc = c.get("cell")
		if not (cc is Array) or (cc as Array).size() < 2:
			continue
		if absi(int(cc[0]) - cx) > 1 or absi(int(cc[1]) - cz) > 1:
			continue
		var rds = c.get("roads")
		if not (rds is Array):
			continue
		for r in rds:
			if typeof(r) != TYPE_DICTIONARY:
				continue
			var d := String(r.get("dir", "")).to_lower()   # match chunk_manager's tolerant road parser
			if d == "ew":
				ew += 1
			elif d == "ns":
				ns += 1
			elif d == "x" or d == "cross" or d == "+":
				ew += 1
				ns += 1
	if ew == 0 and ns == 0:
		return ""
	return "ew" if ew >= ns else "ns"


# world.json vehicle "model" (or url/asset) -> absolute URL. Defaults are
# PER-PROFILE (Wave 3): mounts resolve their pinned library creature
# (farm_Horse / farm_Cow / monster_Dragon via Vehicle.default_model_path);
# parametric profiles (car/tank/boat/plane) return "" — the Vehicle builds
# its own body, so prefetching the sedan for them would be wasted.
func _vehicle_model_url(spec: Dictionary) -> String:
	# body_url (assembled Phase-3 vehicle) wins; else the fused model/url/asset key; else a mount's library default
	var u := String(spec.get("body_url", spec.get("model", spec.get("url", spec.get("asset", "")))))
	if u == "":
		u = Vehicle.default_model_path(String(spec.get("profile", "car")))
	if u == "":
		return ""   # parametric profile with no explicit model — nothing to fetch
	return _norm(u)


# All GLB urls an assembled/modeled vehicle spec needs prefetched: the body plus, for a Phase-3
# assembled vehicle, its single wheel GLB and its optional prop/rotor GLB.
func _vehicle_part_urls(spec: Dictionary) -> Array:
	var out: Array = []
	var b := _vehicle_model_url(spec)
	if b != "":
		out.append(b)
	for k in ["wheel_url", "prop_url"]:
		var s := String(spec.get(k, ""))
		if s != "":
			out.append(_norm(s))
	return out


# Duplicate a cached part GLB into the parts dict under `key`; a missing/failed fetch is skipped and the
# assembler simply omits that mover (wheels/prop optional). Called with the raw spec url string.
func _add_part(parts: Dictionary, key: String, raw) -> void:
	var s := String(raw)
	if s == "":
		return
	var u := _norm(s)
	if builder.cache.has(u) and builder.cache[u] != null:
		parts[key] = (builder.cache[u] as Node).duplicate() as Node3D


# Hot-reload: the polled world.json changed — if (and only if) its "vehicles" list differs from the
# spawned snapshot, rebuild the vehicles alone. The player is untouched UNLESS they are driving a
# rebuilt car, in which case they step out first (a hidden player must never be left attached to a
# freed node).
func _reload_vehicles(w: Dictionary) -> void:
	var list = w.get("vehicles", [])
	if not (list is Array):
		list = []
	if (list as Array) == _vehicles_spec:   # deep == on nested Arrays/Dictionaries
		return
	if active_vehicle != null and is_instance_valid(active_vehicle):
		active_vehicle.exit()   # clears active_vehicle via _on_vehicle_drive_state
	active_vehicle = null
	for v in vehicles:
		if is_instance_valid(v):
			(v as Node).queue_free()
	vehicles = []
	interaction.remove_vehicles()
	await _spawn_vehicles(w)
	_wire_vehicle_terrain()


# Vehicles spawn before ChunkManager builds GTerrain — hand them the heightfield afterwards so a
# parked car snaps onto the rendered surface (no-op for flat/zone worlds: terrain stays null -> y=0).
func _wire_vehicle_terrain() -> void:
	if not chunk_mode or chunk_manager == null:
		return
	for v: Vehicle in vehicles:
		if is_instance_valid(v):
			v.set_terrain(chunk_manager.terrain)
			# Wave 3: boats ride the water surface — hand them the level when
			# the world opted into water (else they keep the terrain degrade).
			if chunk_manager.water_cfg != null:
				v.set_water(chunk_manager.water_level)


# Enter/exit bookkeeping: route input to the active car and exclude its body from the camera
# SpringArm sweep (the car is on the world layer the arm collides with — without the exclusion the
# arm hits the car's own box and jams the camera against the roof).
func _on_vehicle_drive_state(v: Vehicle, is_driving: bool) -> void:
	if is_driving:
		active_vehicle = v
		cam_spring.add_excluded_object(v.get_rid())
		_set_weapon_stowed(not v.is_mount())   # Wave 1.5: stow the weapon in VEHICLES, keep it on mounts
		# SNAP the orbit directly behind the vehicle on board so camera-relative "forward"
		# (drive_input_world) maps to the nose from frame 1. Without this, cam_yaw keeps its
		# on-foot value and only eases to rotation.y+PI at 3*delta (~0.5s); during that window a
		# forward push is a world heading along the OLD camera direction, so a driver who boarded
		# facing the vehicle's front gets err > REVERSE_ENTER and the reverse latch backs the
		# vehicle UP instead of driving it forward (a side approach yaws 90 degrees).
		cam_yaw = v.rotation.y + PI
		look_idx = -1   # drop any in-progress look-drag so the behind-vehicle realign owns the camera
	else:
		if active_vehicle == v:
			active_vehicle = null
		cam_spring.remove_excluded_object(v.get_rid())
		_set_weapon_stowed(false)   # back on foot — the weapon reappears
	if _dismount_btn != null and is_instance_valid(_dismount_btn):
		_dismount_btn.visible = active_vehicle != null   # show GET-OFF only while aboard
	# `vehicle_enter`/`vehicle_exit` vs `mount`/`dismount` — the SAME transition, reported under the
	# name that matches what the player is on. Raised here rather than from vehicle.gd because this
	# is already the one funnel both boarding paths converge on; a hook in each would be two places
	# to forget. `is_mount()` is the profile's own flag, so a world's horse can never report as a car.
	if director != null and director.has_method("fire"):
		var ride := v.is_mount()
		director.fire(("mount" if ride else "vehicle_enter") if is_driving else ("dismount" if ride else "vehicle_exit"),
			{"id": String(v.get("display_name")), "profile": String(v.get("profile"))})


# Weapon-visual STOW (Wave 1.5). While DRIVING A VEHICLE the equipped weapon is hidden (a driver
# isn't brandishing a blade); MOUNTS keep it — firing from the saddle is a Wave-4 feature. Toggled
# ONLY on the board/exit transitions above, and re-asserted by _sync_equip_visual so a mid-ride
# chest auto-equip re-attaches HIDDEN. The HUD (Wpn: label, ATTACK button) is untouched — combat
# still fires; only the on-body visual disappears while stowed.
func _set_weapon_stowed(stow: bool) -> void:
	_weapon_stowed = stow
	if weapon_slot != null and is_instance_valid(weapon_slot):
		weapon_slot.visible = not stow


# ---------------- input ----------------

func _input(event: InputEvent) -> void:
	if scene_manager == null or scene_manager.transitioning:
		return
	if input_frozen or (director != null and director.input_locked()):
		# Returning WITHOUT consuming leaves the GUI layer live, so HUD buttons still respond.
		return   # title screen owns the pointer, or a rule froze the player
	if event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_SPACE:
		_jump_queued = true   # consumed next physics frame if the player is on the floor
		return
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventScreenTouch:
		if event.pressed:
			# _input runs BEFORE the GUI hit-tests, so an unguarded claim here turned every HUD
			# button press-and-slide into a camera orbit (and joystick-zone buttons into movement).
			# A touch that lands on a visible HUD button belongs to the button — don't claim it.
			if _touch_on_hud(event.position):
				_gui_touch_idx = event.index
				return
			_tap_start = event.position
			_tap_moved = false
			if event.position.x < half and move_idx == -1:
				move_idx = event.index
				move_origin = event.position
				move_vec = Vector2.ZERO
			elif event.position.x >= half and look_idx == -1:
				# right half of the screen = drag to orbit the camera
				look_idx = event.index
				look_last = event.position
		else:
			# BUILD TAP. A release that never became a drag is a TAP, and in build mode a tap on the
			# world places or removes at that exact point. This is what replaced aim-the-camera-then-
			# press-PLACE: the only cue that aiming positioned the block was the ghost, and nothing on
			# screen said so. Drag still orbits — the distance test is what separates the two, so
			# looking around never drops a block.
			if not _tap_moved and building != null and is_instance_valid(building) \
					and building.in_build_mode() and not _touch_on_hud(event.position):
				building.tap_world(event.position)
			if event.index == _gui_touch_idx:
				_gui_touch_idx = -1
			if event.index == move_idx:
				move_idx = -1
				move_vec = Vector2.ZERO
			elif event.index == look_idx:
				look_idx = -1
	elif event is InputEventScreenDrag:
		if event.position.distance_to(_tap_start) > 14.0:
			_tap_moved = true          # past the slop radius -> this gesture is a drag, not a tap
		if event.index == move_idx:
			move_vec = ((event.position - move_origin) / 80.0).limit_length(1.0)
		elif event.index == look_idx:
			_apply_look(event.position - look_last)
			look_last = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 \
			and move_idx == -1 and look_idx == -1 and _gui_touch_idx == -1:
		# desktop drag-look. The old guard read "no active touches", but it only proved no touch was
		# DRIVING one of the two sticks — a touch surrendered to a HUD button satisfied it too.
		_apply_look(event.relative)


func _touch_on_hud(p: Vector2) -> bool:
	if hud_layer == null:
		return false
	# Nothing is drawn in capture mode, so nothing may claim a touch. Checking the layer rather than
	# each button because `b.visible` is the node's OWN flag — it stays true when an ancestor
	# CanvasLayer is hidden, and an invisible button that still swallows input would silently break
	# the recorder's movement drive.
	if capture_mode:
		return false
	for k in _hud_btns:
		var b: Button = _hud_btns[k]
		if b != null and is_instance_valid(b) and b.visible and Rect2(b.position, b.size).has_point(p):
			return true
	# building.gd draws its own controls into this same layer and they were NOT consulted here, so a
	# press on a palette button ALSO started a camera orbit — the button fired and the view swung.
	if building != null and is_instance_valid(building) and building.ui_hit(p):
		return true
	# rules.gd draws its OWN buttons into this same layer (WEAPON >, any authored action button) and
	# was likewise unknown here — so a press on one was claimed as a camera orbit: the button did not
	# fire AND the view swung ~150 degrees off a 120px slide. Every layer that draws controls needs a
	# line here; that is the standing cost of _input running before the GUI hit-test.
	if director != null and director.get("rules") != null \
			and director.rules.has_method("ui_hit") and director.rules.ui_hit(p):
		return true
	return false


func _apply_look(d: Vector2) -> void:
	cam_yaw -= d.x * LOOK_SENS
	cam_pitch = clampf(cam_pitch - d.y * LOOK_SENS_PITCH, CAM_PITCH_MIN, CAM_PITCH_MAX)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	return v


# ---------------- manifest ----------------

# ---------------- rule-layer spawning ----------------
#
# WHY PRELOAD, AND WHY IT IS NOT OPTIONAL.
# Models arrive over HTTP through builder._ensure(), which AWAITS. Rule actions run in rules.gd's
# _do(), which is synchronous — a `spawn_wave` cannot wait for a download, and a wave that arrives
# four seconds late (or never, on a slow link) is indistinguishable from the bug this phase exists to
# fix. So every kind a game can spawn is resolved and fetched during boot, and spawning is then a
# cache lookup that cannot fail for network reasons.
#
# That is affordable precisely because the set is STATICALLY KNOWABLE: rules are data, so the kinds
# are readable off the rule list before the first frame. The cost is a real limit — a game can only
# spawn kinds named in its own rules — which is the correct trade for a config format.

## Kind name -> model url. `enemy_kinds` in world.json wins when present (an author naming a specific
## model or custom stats); otherwise the name is matched against the manifest catalog, so
## `spawn_wave: {"kind": "imp"}` works with NO authoring at all. Falls back to the default skeleton
## rather than spawning nothing — an obviously-wrong creature is debuggable, an empty wave is not.
func resolve_enemy_model(kind: String) -> String:
	var k := kind.to_lower().strip_edges()
	var kinds = world_data.get("enemy_kinds", {})
	if kinds is Dictionary and (kinds as Dictionary).has(kind):
		var spec = (kinds as Dictionary)[kind]
		if spec is Dictionary and String((spec as Dictionary).get("model", "")) != "":
			return _norm(String((spec as Dictionary)["model"]))
	if k != "":
		for e in enemy_catalog:                       # exact id first, then a contains-match
			if String((e as Dictionary)["id"]) == k:
				return String((e as Dictionary)["url"])
		for e2 in enemy_catalog:
			if k in String((e2 as Dictionary)["id"]):
				return String((e2 as Dictionary)["url"])
	push_warning("[Spawn] no model for kind '%s' — using the default skeleton" % kind)
	print("GOGI_SPAWN_FALLBACK kind=", kind)
	return origin + "/godot-assets/enemies/skeleton_warrior.glb"


## Per-kind stat overrides, passed straight into enemy.gd setup()'s `opts`.
func enemy_opts(kind: String) -> Dictionary:
	var kinds = world_data.get("enemy_kinds", {})
	if kinds is Dictionary and (kinds as Dictionary).has(kind):
		var spec = (kinds as Dictionary)[kind]
		if spec is Dictionary:
			var o: Dictionary = (spec as Dictionary).duplicate()
			o.erase("model")
			return o
	return {}


## Every kind reachable from the rule list, resolved + downloaded before the first rule can fire.
func preload_spawn_kinds() -> void:
	var kinds: Dictionary = {}
	for r0 in world_data.get("rules", []):
		if typeof(r0) != TYPE_DICTIONARY:
			continue
		for a0 in (r0 as Dictionary).get("then", []):
			if typeof(a0) != TYPE_DICTIONARY:
				continue
			var a: Dictionary = a0
			for key in ["spawn", "spawn_wave"]:
				if a.has(key) and a[key] is Dictionary:
					var kn := String((a[key] as Dictionary).get("kind", ""))
					if kn != "":
						kinds[kn] = true
	var ek = world_data.get("enemy_kinds", {})
	if ek is Dictionary:
		for kn2 in (ek as Dictionary):
			kinds[String(kn2)] = true
	if kinds.is_empty():
		return
	var urls: Array = []
	for kn3 in kinds:
		var u := resolve_enemy_model(String(kn3))
		if u != "" and not (u in urls):
			urls.append(u)
			_spawn_model[String(kn3)] = u
	await builder._ensure(urls)
	print("GOGI_SPAWN preloaded kinds=%d urls=%d" % [kinds.size(), urls.size()])


## Create `count` enemies of `kind` around the player. Synchronous by design — see the block comment.
func spawn_enemies(kind: String, count: int, radius: float, ent_id := "") -> int:
	if player == null or scene_manager == null or scene_manager.current_root == null:
		# THE WORLD IS NOT BUILT YET, AND THIS IS THE COMMON CASE — a rule bound to `start` fires
		# before the first area root exists, so the most natural authoring there is ("spawn the boss
		# when the game begins") hit this and returned silently. Queue it instead of dropping it, and
		# say so: an early return with no trace is exactly the failure this layer keeps producing.
		_spawn_queue.append({"kind": kind, "count": count, "radius": radius, "id": ent_id})
		print("GOGI_SPAWN queued kind=%s count=%d (world not ready)" % [kind, count])
		return 0
	var url: String = _spawn_model.get(kind, resolve_enemy_model(kind))
	if not builder.cache.has(url):
		# Not preloaded: the kind was never named in a rule (a live chat edit, most likely). Spawning
		# nothing here would be the silent failure all over again, so say so.
		push_warning("[Spawn] kind '%s' was not preloaded — nothing spawned" % kind)
		print("GOGI_SPAWN_MISS kind=", kind)
		return 0
	var src := builder.cache[url] as Node
	var opts := enemy_opts(kind)
	# LIVE CAP. `spawn_wave` on a repeating timer accumulates FOREVER — nothing in the rule layer
	# removes an enemy, so a survival game quietly grows a crowd until the player is walled in by
	# bodies (player.collision_mask includes L_ENEMY, so enemies are solid) and the frame rate dies.
	# Recycling the OLDEST rather than refusing the new spawn matters: refusing would make later waves
	# silently do nothing, which is the exact failure mode this whole layer keeps producing.
	_spawned = _spawned.filter(func(x): return is_instance_valid(x))
	var over := (_spawned.size() + maxi(1, count)) - SPAWN_LIVE_CAP
	if over > 0:
		var recycled := 0
		var keep0: Array = []
		for e0 in _spawned:
			if not is_instance_valid(e0):
				continue
			if recycled < over:
				e0.queue_free()   # end-of-frame free, so drop it from the registry HERE
				recycled += 1
			else:
				keep0.append(e0)
		_spawned = keep0
		_prune_enemy_list()
		print("GOGI_SPAWN recycled=%d (live cap %d)" % [recycled, SPAWN_LIVE_CAP])

	# KEEP THEM INSIDE THE ROOM. The requested radius is a WISH, not a coordinate: an author asking
	# for 14 in a 13-unit hall put the boss through the wall, where it fell out of the world and was
	# never seen — the spawn "worked", the log said so, and the arena was empty. Clamp to the area's
	# own half-extent and re-check each placement against it.
	var half := 13.0
	if scene_manager.areas.has(scene_manager.current_id):
		half = float((scene_manager.areas[scene_manager.current_id] as Dictionary).get("size", 13))
	var lim := maxf(2.0, half * 0.78)
	var d := clampf(radius, 2.5, lim)
	# A SWARM, NOT A RING. Even angular slices at one fixed distance put every enemy on a perfect
	# circle — it reads as a spawn pattern rather than creatures arriving. Worse, the slices are
	# derived from the index alone, so wave two landed on wave one's exact footprint. A per-wave
	# phase plus per-enemy angle and distance jitter breaks both: still roughly surrounding, never
	# geometric.
	var n := maxi(1, count)
	var phase := randf() * TAU
	var made := 0
	var dmin := 1e9
	var dmax := 0.0
	for i in range(n):
		var e := CharacterBody3D.new()
		e.set_script(EnemyScript)
		scene_manager.current_root.add_child(e)
		var ang := phase + TAU * (float(i) + randf_range(-0.32, 0.32)) / float(n)
		var dist := d * randf_range(0.45, 1.0)
		var pos := player.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		pos.x = clampf(pos.x + randf_range(-1.1, 1.1), -lim, lim)
		pos.z = clampf(pos.z + randf_range(-1.1, 1.1), -lim, lim)
		pos.y = player.global_position.y          # same floor as the player, never mid-air
		e.global_position = pos
		var pd := Vector2(pos.x - player.global_position.x, pos.z - player.global_position.z).length()
		dmin = minf(dmin, pd)
		dmax = maxf(dmax, pd)
		e.setup(player, src.duplicate(), self, i, count, kind, opts)
		if ent_id != "":
			e.set_meta("gogi_id", ent_id)
		_spawned.append(e)
		# REGISTER WITH THE COMBAT SYSTEM. _attack and GProjectile both search the STREAMER's enemy
		# list, which only the area builder ever filled. A rule-spawned enemy was in the scene, drawn,
		# chasing and hitting the player — and invisible to every weapon, so swinging at it did
		# nothing at all. Being in the tree is not the same as being a target.
		var streamer0 = chunk_manager if chunk_mode else scene_manager
		if streamer0 != null:
			streamer0.enemies.append(e)
		made += 1
	_spawned = _spawned.filter(func(x): return is_instance_valid(x))
	_prune_enemy_list()
	print("GOGI_SPAWN kind=%s count=%d live=%d spread=%.1f..%.1f (r=%.1f lim=%.1f)" % [kind, made, _spawned.size(), dmin, dmax, d, lim])
	return made


## Remove spawned entities by kind, by id, or all of them.
func despawn_entities(kind: String, ent_id: String) -> int:
	# DROP BY IDENTITY, NOT BY VALIDITY. `queue_free()` defers the free to the END of the frame, so
	# an `is_instance_valid` filter run right after it still sees every node as alive and keeps all
	# of them. The registry then reported entities that were already gone: `live=` in the soak dump
	# read 1 after the only spawn was despawned, and the live cap counted ghosts against its budget
	# until the next spawn happened to prune them. Building the survivor list as we go is exact.
	var gone := 0
	var keep: Array = []
	for e in _spawned:
		if not is_instance_valid(e):
			continue
		var match_id := ent_id != "" and String(e.get_meta("gogi_id", "")) == ent_id
		var match_kind := ent_id == "" and (kind == "" or String(e.get("kind")) == kind)
		if match_id or match_kind:
			e.queue_free()
			gone += 1
		else:
			keep.append(e)
	_spawned = keep
	_prune_enemy_list()
	return gone


## Move a spawned entity (addressed by id, else the first of a kind) to a world position.
func teleport_entity_to(ent_id: String, kind: String, to: Vector3) -> bool:
	for e in _spawned:
		if not is_instance_valid(e):
			continue
		if ent_id != "" and String(e.get_meta("gogi_id", "")) != ent_id:
			continue
		if ent_id == "" and kind != "" and String(e.get("kind")) != kind:
			continue
		(e as Node3D).global_position = to
		return true
	return false


## Area arrival: raise the rule-layer event, and reconcile the spawn registry.
##
## SPAWNED ENTITIES BELONG TO THE AREA THEY WERE SPAWNED IN. goto_area frees the area root, and
## rule-spawned enemies are children of it, so a transition already destroyed them — the registry
## just went on holding freed references and reporting live counts that were fiction (measured: a
## wave count oscillating 3/6/3/6 while the player was shoved through a seam by the very wave that
## had just spawned around them).
##
## They are NOT reparented to something permanent, deliberately. Every area is rebuilt at the origin,
## so a skeleton that survived the trip would stand at its old coordinates inside a different room.
## Freeing them is the honest behaviour for this world model; the log makes it visible instead of
## silent, which is the whole difference between a rule and a mystery.
func _on_area_entered(id: String) -> void:
	var stale := _spawned.size()
	for e in _spawned:
		if is_instance_valid(e):
			e.queue_free()
	_spawned.clear()
	if stale > 0:
		print("GOGI_SPAWN area_change cleared=%d area=%s" % [stale, id])
	if director != null and director.has_method("fire"):
		director.fire("enter_area", {"id": id})
	# Flush anything a boot-time rule asked for before there was a world to put it in.
	if not _spawn_queue.is_empty():
		var q := _spawn_queue.duplicate()
		_spawn_queue.clear()
		for r in q:
			spawn_enemies(String(r["kind"]), int(r["count"]), float(r["radius"]), String(r["id"]))


func _parse_manifest(body: PackedByteArray) -> void:
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary):
		return
	# Scatter = ambient NATURE clutter ONLY (rocks/plants/trees/logs). The manifest tags every prop
	# with a `category`; pulling the WHOLE library scattered buildings/walls/swords/pipes into every
	# area (incongruous, odd-shaped "floating" junk). Named PALETTE props are a separate path, unaffected.
	# ENEMY CATALOG — kept so the rule layer's `spawn`/`spawn_wave` can turn a KIND NAME into a model
	# with no authoring. Without this the engine knew exactly one enemy: a hard-coded skeleton path,
	# which is why a wave of "imp" had nothing to instance.
	for e in data.get("enemies", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var eu := _norm(String(e.get("file", "")))
		if eu != "":
			enemy_catalog.append({"id": String(e.get("id", "")).to_lower(), "url": eu})

	for p in data.get("props", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if String(p.get("category", "")) != "nature":
			continue
		# within "nature", skip terrain/tiling pieces (cliffs, paths, beach/road edges) — those tile
		# the ground, they're not free-standing scatter clutter
		var fn := String(p.get("file", "")).get_file().to_lower()
		if "terrain" in fn or "path" in fn or "cliff" in fn or "beach" in fn or "railway" in fn or "road" in fn or "fence" in fn:
			continue
		var u := _norm(String(p.get("file", "")))   # relative → resolves against origin (portable)
		if u != "" and "/godot-assets/props/" in u:
			props_pool.append(u)


func _collect(v, out_arr: Array) -> void:
	match typeof(v):
		TYPE_STRING:
			if (v as String).to_lower().ends_with(".glb"):
				out_arr.append(v)
		TYPE_DICTIONARY:
			for k in v:
				_collect(v[k], out_arr)
		TYPE_ARRAY:
			for e in v:
				_collect(e, out_arr)


func _norm(s: String) -> String:
	if s.begins_with("http"):
		return s
	if s.begins_with("/"):
		# Self-heal build-coupled paths: a rebuilt world.json bakes the AUTHORING build's id into
		# absolute /cloud-<id>/… (and /news-cloud-<id>/…) asset URLs, so after a rebuild to a NEW id
		# every one 404s and renders as a gray placeholder. Re-root any such path onto the CURRENT
		# build_id so the build's own committed assets resolve regardless of which id authored them.
		if s.begins_with("/cloud-") or s.begins_with("/news-cloud-"):
			var slash := s.find("/", 1)   # the '/' after the leading /<buildid> segment
			if slash > 0:
				# No build id in the page URL (localhost verify, custom domain) -> the export is
				# served at the ROOT, so strip the stale prefix instead of keeping a dead path.
				if build_id == "":
					return origin + s.substr(slash)
				return origin + "/" + build_id + s.substr(slash)
		return origin + s
	if "/" in s:
		return origin + "/godot-assets/" + s
	return ""


# Prompt-driven sky/weather: the agent sets a top-level "sky" block in world.json
# (a fixed {time,weather} or a {cycle:[...],loop}). Re-applied on hot-reload.
func _apply_weather(world: Dictionary) -> void:
	if weather == null:
		return
	var sky = world.get("sky", null)
	if sky is Dictionary:
		weather.apply(sky)


# ---------------- web time-of-day hooks (window.gogiSetTime / gogiGetTime) ----------------

# Let page JS drive the sky for preview/QA harnesses. gogiSetTime(state) pins the time-of-day
# INSTANTLY (Weather3D.set_time snaps — no lerp) keeping the current weather; gogiGetTime() reads
# the last-applied state back. Accepts any Weather3D TIME key ("day"/"night"/"sunrise"/"sunset").
# No-op off the web. The callback is stored in a member — JavaScriptBridge callbacks are GC'd the
# instant nothing references them.
func _setup_web_time_hooks() -> void:
	if not OS.has_feature("web") or weather == null:
		return
	_js_set_time_cb = JavaScriptBridge.create_callback(_on_gogi_set_time)
	var win = JavaScriptBridge.get_interface("window")
	if win != null:
		win.gogiSetTime = _js_set_time_cb
	JavaScriptBridge.eval("window.__gogiTime='%s';window.gogiGetTime=function(){return window.__gogiTime;};" % weather.time_state, true)
	# Wave 5: publish window.gogiGetPlayer() + window.gogiSolids() so verify.mjs's live probes (drive /
	# swim / collision / spawn / ascent / streaming) activate. Each raw callback returns a JSON STRING
	# (the only reliably-marshalled return type); a thin JS wrapper JSON.parses it to the object/array
	# the probes expect (verify.mjs:1255-1258). Web + verify only; no cost off the web.
	_js_get_player_cb = JavaScriptBridge.create_callback(_on_gogi_get_player)
	_js_solids_cb = JavaScriptBridge.create_callback(_on_gogi_solids)
	_js_rotveh_cb = JavaScriptBridge.create_callback(_on_gogi_rotveh)
	_js_board_cb = JavaScriptBridge.create_callback(_on_gogi_board)
	if win != null:
		win.__gogiGetPlayerRaw = _js_get_player_cb
		win.__gogiSolidsRaw = _js_solids_cb
		win.gogiRotVeh = _js_rotveh_cb
		win.gogiBoard = _js_board_cb
	# JavaScriptBridge callback RETURN VALUES do not marshal back to JS in the web export (the raw call
	# yields null), so a wrapper that only reads `__gogi*Raw()` is permanently dead — the same reason the
	# director PUSHES its own state global on a timer. Both wrappers therefore fall back to a PUSHED
	# snapshot; see _push_gogi_state.
	#
	# gogiSolids ALSO latches `__gogiSolidsWant` on first call. Solids are only computed for a caller
	# that actually asked, so a real player never pays for the scene walk (see _push_gogi_state). The
	# cost of that: the FIRST call returns [] and the snapshot lands on the next push — callers must
	# prime-then-poll, which verify.mjs's readSolids() does.
	JavaScriptBridge.eval(
		"window.__gogiSolids=[];window.__gogiSolidsWant=0;" +
		"window.gogiGetPlayer=function(){var s=window.__gogiGetPlayerRaw();return s?JSON.parse(s):(window.__gogiPlayer||null);};" +
		"window.gogiSolids=function(){window.__gogiSolidsWant=1;var s=window.__gogiSolidsRaw();" +
		"return s?JSON.parse(s):(window.__gogiSolids||[]);};", true)
	var pt := Timer.new()
	pt.wait_time = 0.3
	pt.autostart = true
	pt.timeout.connect(_push_gogi_state)
	add_child(pt)


# Push QA state into JS, because callback return values never make it back (see _setup_web_time_hooks).
#
# The player snapshot is a handful of floats, so it goes out every tick unconditionally. SOLIDS walk the
# resident cell roots and JSON-encode an AABB per body — real work on a dense world — so they are gated
# on `__gogiSolidsWant`, which only a caller of gogiSolids() ever sets. A player who never opens a
# console pays for neither the walk nor the encode, and the probes still get live data.
func _push_gogi_state() -> void:
	JavaScriptBridge.eval("window.__gogiPlayer=" + _on_gogi_get_player([]) + ";", true)
	_gogi_push_tick += 1
	if _gogi_push_tick < 3:   # ~0.9s between sweeps; solids change at streaming speed, not frame speed
		return
	_gogi_push_tick = 0
	var want = JavaScriptBridge.eval("window.__gogiSolidsWant?1:0", true)
	if want == null or int(want) != 1:
		return
	JavaScriptBridge.eval("window.__gogiSolids=" + _on_gogi_solids([]) + ";", true)


# DEBUG: window.gogiRotVeh(deg) — yaw the active vehicle's model to find the forward-alignment offset.
func _on_gogi_rotveh(args) -> void:
	if active_vehicle != null and is_instance_valid(active_vehicle):
		var deg := float(args[0]) if (args is Array and args.size() > 0) else 0.0
		active_vehicle.debug_yaw_model(deg)


func _on_gogi_board(_args) -> String:
	if interaction != null and is_instance_valid(interaction):
		interaction.try_use()   # board the nearest vehicle / interact / (if seated) stand up
	return "ok"


func _on_gogi_set_time(args: Array) -> void:
	if weather == null or args.is_empty():
		return
	var state := String(args[0])
	weather.set_time(state)   # immediate where the state resolves; a lerp only if a cycle chase is mid-flight
	JavaScriptBridge.eval("window.__gogiTime='%s';" % weather.time_state, true)
	print("GOGI_TIME ", weather.time_state)


# window.gogiGetPlayer() — live player state as a JSON string (the JS wrapper parses it). Fields match
# the verify.mjs probe contract (verify.mjs:1255-1258). Off-ladder `climbing` is null -> false.
func _on_gogi_get_player(_args: Array) -> String:
	if player == null or not is_instance_valid(player):
		return "null"
	var p := player.global_position
	var d := {
		"x": p.x, "y": p.y, "z": p.z,
		"in_vehicle": active_vehicle != null and is_instance_valid(active_vehicle),
		"cam_yaw": cam_yaw,
		"climbing": climbing != null,
		"swimming": swimming,
		"on_floor": player.is_on_floor(),   # verify.mjs floating-avatar gate: grounded unless swim/climb/vehicle
		"vy": player.velocity.y,             # DEBUG run-float: vertical speed (grounded run should be ~0)
		"anim": _hero_anim_state.anim,       # DEBUG run-float: semantic anim (run/walk/idle/jump)
		"clip": (_hero_anim_state.ap.current_animation if _hero_anim_state.ap != null and is_instance_valid(_hero_anim_state.ap) else ""),
		"air_t": _hero_anim_state.air_t,
		"wall": player.is_on_wall(),         # DEBUG run-float
		"fps": Engine.get_frames_per_second(),   # DEBUG run-float: low fps in headless = physics artifact
	}
	# DEBUG run-float: analytic ground height + nearest collider below the feet (gap, -1 = no collider)
	if chunk_manager != null and is_instance_valid(chunk_manager):
		d["gy"] = chunk_manager._ground_y(p.x, p.z)
	var _space := player.get_world_3d().direct_space_state
	var _q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.3, 0), p + Vector3(0, -5.0, 0))
	_q.exclude = [player.get_rid()]
	var _hit := _space.intersect_ray(_q)
	d["ray"] = (p.y - float(_hit["position"].y)) if not _hit.is_empty() else -1.0
	# DEBUG run-float: current pose's lowest foot height ABOVE the body origin (~0.05 grounded, >0 = model floats)
	d["foot_raw"] = _foot_raw   # render-pose foot height above origin, measured at skeleton_updated (non-circular)
	if active_vehicle != null and is_instance_valid(active_vehicle):
		d["vehicle_yaw"] = active_vehicle.rotation.y
		d["vehicle_airborne"] = active_vehicle._airborne   # verify flight-brake probe
		d["vehicle_profile"] = active_vehicle.profile      # verify boat/mount probes (car/boat/plane/horse/…)
		# DEBUG flyer-sideways: model up.y (~1 upright, ~0 barrel-rolled) + nose vs travel alignment
		var _vis: Node3D = active_vehicle._visual
		if _vis != null and is_instance_valid(_vis):
			var _vb: Basis = _vis.global_transform.basis.orthonormalized()
			d["veh_up_y"] = _vb.y.y
			var _nose: Vector3 = _vb.z   # model forward (+Z) in world
			var _fwd: Vector3 = active_vehicle.global_transform.basis.z   # vehicle travel forward
			d["veh_nose_dot_fwd"] = _nose.normalized().dot(_fwd.normalized())   # ~+1 nose-first, ~-1 backward, ~0 sideways
	if _dismount_btn != null and is_instance_valid(_dismount_btn):
		# verify: the DISMOUNT affordance's visibility + UI rect (+ the UI viewport size, so the
		# harness can convert UI coords -> CSS px under canvas_items/expand content scaling)
		var vps := get_viewport().get_visible_rect().size
		d["dismount_visible"] = _dismount_btn.visible
		d["dismount_rect"] = [_dismount_btn.global_position.x, _dismount_btn.global_position.y,
			_dismount_btn.size.x, _dismount_btn.size.y, vps.x, vps.y]
	return JSON.stringify(d)


# window.gogiSolids() — world AABBs of the SOLID bodies (structures/props/roads) in the resident ring,
# as a JSON string of [{min:[x,y,z], max:[x,y,z]}]. Excludes the terrain floor (group "gogi_terrain")
# so a player standing ON the ground never reads as "inside a solid". On-demand only (verify probes).
func _on_gogi_solids(_args: Array) -> String:
	var out: Array = []
	if chunk_manager != null and is_instance_valid(chunk_manager):
		for k in chunk_manager.resident:
			var rec = chunk_manager.resident[k]
			var root = rec.get("root")
			if root != null and is_instance_valid(root):
				_collect_solids(root, out)
	return JSON.stringify(out)


func _collect_solids(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is StaticBody3D and not (c as Node).is_in_group("gogi_terrain"):
			var ab := _body_world_aabb(c as StaticBody3D)
			if ab.size.length() > 0.01:
				out.append({
					"min": [ab.position.x, ab.position.y, ab.position.z],
					"max": [ab.end.x, ab.end.y, ab.end.z]})
		_collect_solids(c, out)


# Merged world AABB of a static body's collision shapes. Shape3D.get_debug_mesh() yields a local AABB
# for ANY shape (box/sphere/trimesh), transformed by the shape node's world transform.
func _body_world_aabb(body: StaticBody3D) -> AABB:
	var merged := AABB()
	var first := true
	for cs in body.get_children():
		if cs is CollisionShape3D and (cs as CollisionShape3D).shape != null:
			var dm := (cs as CollisionShape3D).shape.get_debug_mesh()
			if dm == null:
				continue
			var wa: AABB = (cs as CollisionShape3D).global_transform * dm.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


# ---------------- world build (persistent player/env/hud) ----------------

# NATIVE COUNTERPART TO THE `if OS.has_feature("web")` BLOCK IN _ready.
#
# On web, which world to load is implied by the page the game is served from, so `world_url` is read
# off window.location. A native host has no window.location, so the engine's command line carries it:
#
#     --world-url https://<host>/<build>/world.json      (or --world-url=<...>)
#     --soak                                             (desktop twin of the web `?soak=1`)
#
# `--soak` turns on auto_roam so a headless run drives the player around instead of standing still.
# It is the only way to exercise anything that needs MOVEMENT — region crossings, vehicle boarding,
# placement — from a script. A stationary probe can only ever prove what fires at spawn.
#
# Everything else is then derived from that one value exactly as the web path derives it from the URL
# bar — `origin` for asset roots, `build_id` for the self-heal re-rooting, and the sibling
# region_*.json / quests.json lookups that _region_base_dir() and _boot do by string-replacing
# "world.json".
#
# WITHOUT THIS a native build silently keeps whatever `world_url` was declared to at the top of this
# file. That is not a crash and logs nothing: the fetch 404s, no regions are ever built, and a
# completely healthy engine renders a black screen. Web behaviour is untouched — this runs only on
# the non-web branch.
## Is `?<name>=1` present in the page URL? Web only; false everywhere else.
##
## Written this way because JavaScriptBridge.eval does NOT hand a JS boolean back as a Godot bool —
## on 4.7.1 `x >= 0` arrives as TYPE_INT 1. Every `typeof(v) == TYPE_BOOL` guard therefore evaluated
## false no matter what the URL said, which is why ?soak=1, ?hudgrid=1 and ?mpdebug=1 were all dead
## on web. (_setup_web_time_hooks already worked around it locally with `?1:0`.) Reading the answer
## loosely, rather than trusting one marshalled type, is what keeps the next flag from dying the
## same silent death.
func _query_flag(name: String) -> bool:
	if not OS.has_feature("web"):
		return false
	var v = JavaScriptBridge.eval("window.location.search.indexOf('%s=1')>=0?1:0" % name, true)
	match typeof(v):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT, TYPE_FLOAT:
			return float(v) != 0.0
		TYPE_STRING:
			return String(v) == "1" or String(v) == "true"
	return false


# Numeric query parameter, with the same defensive typing as _query_flag.
#
# JavaScriptBridge.eval does NOT reliably hand back the type you asked for — a JS boolean arrives as
# TYPE_INT, and that trap has silently disabled flags here before. A JS number can arrive as INT or
# FLOAT depending on whether it happens to be integral, and as a STRING through some paths, so all
# three are accepted and anything else falls back rather than reading as 0.
func _query_num(name: String, fallback: float) -> float:
	if not OS.has_feature("web"):
		return fallback
	var v = JavaScriptBridge.eval(
		"(new URLSearchParams(window.location.search)).get('%s')" % name, true)
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING:
			var t := String(v).strip_edges()
			return float(t) if t.is_valid_float() else fallback
	return fallback


func _apply_cmdline_world() -> void:
	# Read both lists so either calling convention works: args after a `--` separator (the documented
	# way to pass custom arguments, and the only way that cannot collide with an engine flag) and the
	# raw argument list (what a host embedding libgodot naturally appends).
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())

	var url := ""
	var i := 0
	while i < args.size():
		var a := String(args[i])
		if a.begins_with("--world-url="):
			url = a.substr("--world-url=".length())
		elif a == "--world-url" and i + 1 < args.size():
			url = String(args[i + 1])
			i += 1
		elif a == "--hudgrid":
			hud_debug = true
		elif a == "--mpdebug":
			mp_debug = true
		elif a == "--capture":
			capture_mode = true
		elif a.begins_with("--mode="):
			# Test hook: pick a title-screen mode without a click, so a headless run can exercise a
			# specific mode — including a MAP mode, whose whole point is which room you land in.
			# Without it the map chooser is only testable by hand on two phones, which is how a
			# matchmaking bug stays invisible until a player reports that shooting does nothing.
			boot_mode = a.substr("--mode=".length())
		elif a == "--soak" or a == "--soak=1":
			# Desktop/headless twin of the web `?soak=1`. Set BEFORE the empty-url return so a soak
			# run works against a world supplied by any other route, not only the command line.
			auto_roam = true
		i += 1

	if url == "":
		return
	_adopt_world_url(url)


# Point this boot at `url`, deriving everything the rest of the game reads from it.
# Shared by the launch path (_apply_cmdline_world) and the runtime swap (_switch_world) so a world
# opened later is configured identically to one opened at startup — no second, drifting copy of this.
func _adopt_world_url(url: String) -> void:
	world_url = url

	# origin = scheme://host — the same value window.location.origin yields on the web path.
	var scheme_end := url.find("://")
	if scheme_end != -1:
		var host_end := url.find("/", scheme_end + 3)
		origin = url.substr(0, host_end) if host_end != -1 else url

	# build id = the first path segment, and ONLY when it looks like one — same rule as the web regex,
	# which exists because a bare root otherwise captured "index.html" and re-rooted every asset onto a
	# bogus path.
	build_id = ""
	var tail := url.substr(origin.length()).lstrip("/")
	if tail != "":
		var seg := tail.split("/")[0]
		if seg.begins_with("cloud-") or seg.begins_with("news-cloud-"):
			build_id = seg

	print("GOGI_WORLD_URL native ", world_url, " origin=", origin, " build_id=", build_id)


# ---------------------------------------------------------------------------------------------
# RUNTIME WORLD SWAP (native player)
#
# The host app cannot restart the engine to open a different game. libgodot refuses a second
# instance outright — `libgodot_destroy_godot_instance` deliberately leaves its instance pointer set
# ("Note: When Godot Engine supports reinitialization, clear the instance pointer here"), so a second
# `libgodot_create_godot_instance` fails with "Only one Godot Instance may be created". One engine
# per process launch, permanently.
#
# So "open another game" has to mean rebuilding the world inside the engine that is already running.
# This does that as a FULL teardown — reload_current_scene() frees the entire scene and builds it
# again from scratch — rather than selectively resetting state. Partial reuse would be faster and is
# the wrong trade: anything missed leaks from one game into the next, and that class of bug surfaces
# as a boat from the previous world floating in this one. Autoloads survive by design, which is why
# AudioManager is reset explicitly below.
# ---------------------------------------------------------------------------------------------

# Name of the node SwiftGodotKit parents to the scene-tree ROOT for host<->game messaging.
const HOST_BRIDGE_NODE := "__swiftgodotkit_bridge__"

# Survives the scene reload because a static belongs to the SCRIPT, not the instance — the whole
# point, since the instance that receives the request is freed before the new one reads it.
static var _pending_world_url := ""

# The multiplayer room requested alongside that world, same static trick and same reason. Consumed
# in _ready next to _pending_world_url; "" means the swap carried no room, which is a real answer.
static var _pending_room := ""

# The room this world is actually playing in — resolved once during _ready (swap value, else the
# command line) so nothing downstream has to know which of the two paths it came from.
var _current_room := ""

# Multiplayer is held at boot because the world's title screen offers a map choice, and the map is
# part of the room. Cleared by begin_multiplayer() when the player picks. See _setup_multiplayer.
var _mp_awaiting_map := false

# `--mode=ID` — auto-pick a title-screen mode at boot. Test hook only; empty in every real run.
var boot_mode := ""


func _connect_host_bridge() -> void:
	# The bridge is created by the HOST, from its readiness poll, which can land before or after this
	# scene is ready. Handle both: take it if present, otherwise wait for it to appear.
	var existing := get_tree().root.get_node_or_null(NodePath(HOST_BRIDGE_NODE))
	if existing != null:
		_bind_host_bridge(existing)
		return
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if String(n.name) == HOST_BRIDGE_NODE:
		_bind_host_bridge(n)


func _bind_host_bridge(n: Node) -> void:
	# Accept either spelling of the signal. SwiftGodot declares it as `messageFromHost`; whether the
	# binding generator registers it verbatim or snake_cases it is its business, not something worth
	# betting a silent no-op on.
	for sig in ["messageFromHost", "message_from_host"]:
		if n.has_signal(sig) and not n.is_connected(sig, _on_host_message):
			n.connect(sig, _on_host_message)
			print("GOGI_BRIDGE connected via ", sig)
			return
	push_warning("host bridge node has no recognised messageFromHost signal")


func _on_host_message(msg) -> void:
	var d := msg as Dictionary
	if d == null:
		return
	var action := String(d.get("action", ""))
	if action == "suspend":
		_host_suspend()
		return
	if action == "resume":
		_host_resume()
		return
	if action != "loadWorld":
		return
	var url := String(d.get("url", ""))
	if url == "":
		push_warning("loadWorld with no url — ignored")
		return
	# A swap must never inherit a suspended engine, or the next game boots frozen and silent.
	_host_resume()
	_switch_world(url, String(d.get("room", "")))


# ── HOST SUSPEND / RESUME ─────────────────────────────────────────────────────────────────────────
# The native player CANNOT stop the engine. libgodot deliberately leaves its instance pointer set
# after destroy ("When Godot Engine supports reinitialization, clear the instance pointer here"), so
# a second create fails outright and GamePlayer keeps ONE engine for the life of the process.
# "Closing" a game there only takes the view off screen: the scene, its _process work, its netsync
# broadcasts and its AUDIO all keep running behind the chat UI. The symptom that got reported was
# music still playing after leaving a game; the same root cause also left the player standing in the
# multiplayer room, still broadcasting a position nobody was driving.
func _host_suspend() -> void:
	AudioManager.stop_audio("all")     # music + ambient + weather beds, and frees their streams
	# stop_audio does NOT reach positional world loops (a waterfall, a campfire) or in-flight one-shot
	# SFX — and an explicit list of every emitter is exactly the kind of list that goes stale the next
	# time someone adds one. Muting the master bus is unconditional and covers whatever comes later.
	AudioServer.set_bus_mute(0, true)
	get_tree().paused = true
	print("GOGI_HOST suspend")


# Mute is GLOBAL and survives a scene reload, so a missed resume would strand the NEXT game silent —
# a worse bug than the one this fixes. Hence three independent paths back: the host asking, a
# loadWorld swap, and _ready on every scene load. Any one of them is enough.
func _host_resume() -> void:
	get_tree().paused = false
	AudioServer.set_bus_mute(0, false)
	print("GOGI_HOST resume")


func _switch_world(url: String, room: String = "") -> void:
	print("GOGI_WORLD_SWITCH -> ", url, (" room=" + room) if room != "" else " (no room)")
	_pending_world_url = url
	# Always assigned, including to "": a swap that carries no room must CLEAR the previous one, or
	# the next world silently joins the last game's room.
	_pending_room = room

	# Autoloads outlive the scene, so anything they hold is exactly what leaks between games.
	AudioManager.reset_for_world_change()

	# DEFERRED, not immediate: this runs inside a signal callback from the bridge node, and freeing
	# the scene tree out from under an in-flight signal is a use-after-free.
	get_tree().call_deferred("reload_current_scene")


func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	# Look upgrade (env is shared; the Weather3D system reuses it and only overrides sky/ambient, so
	# these survive). ACES tonemap = warm/filmic vs the flat linear default; a touch of contrast +
	# saturation so nothing reads washed-out. Both are Compatibility/WebGL2-safe (Environment GLOW is
	# NOT — neon is faked with emissive + an additive quad per art.md, never env.glow_enabled).
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	# tonemap_white MUST be > 1.0: at the default (1.0) ACES clips ALL radiance >= 1.0 to pure
	# white, so any albedo >= ~0.72 under the noon sun+ambient renders as a detail-free blob
	# (stucco/plaster/limestone/marble all become the same white). 4.0 restores highlight
	# headroom and N.L shading separation on pale walls, day AND night.
	env.tonemap_white = 4.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.12
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -45.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true   # contact shadows GROUND props. In CHUNK mode _boot tightens the cascade +
	add_child(sun)              # the floor slab is cast_shadow=OFF, so props cast but the flat floor can't acne.


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD | L_ENEMY | L_PEER   # L_PEER: players stop walking through each other
	player.floor_snap_length = 0.8   # Wave 2: feet stay stuck to descents/stairs (no mid-air hover)
	player.floor_max_angle = deg_to_rad(55)   # climb steep alien hills/ramps (Godot's 45° default read them as walls)
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.6
	cs.shape = cap
	cs.position.y = 0.85
	player.add_child(cs)
	# DEFAULT body = a placeholder capsule. To use a real character, load a .glb
	# (library OR Meshy — SAME path) and SEAT it so its feet rest on the floor
	# (character GLB origins sit at the hips, so feet sink under the floor without this):
	#     var avatar := load("res://models/hero.glb").instantiate() as Node3D
	#     player.add_child(avatar)
	#     _seat_avatar(avatar)            # feet at y=0; then remove the capsule body
	#     # size the CollisionShape capsule from the model's height if it differs.
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.6
	body.mesh = cm
	body.position.y = 0.85
	# Neutral until the room tells us our own id — see _on_identified. Painting a hopeful blue here
	# and never revisiting it is what made every player see themselves in a colour nobody else used.
	body.material_override = _mat(Color(0.55, 0.60, 0.68))
	player.add_child(body)
	_capsule_body = body   # kept so a native hero_model attach can hide the placeholder (see _attach_hero_model)
	# Wave 4: the old hardcoded sword MeshInstance is GONE — GEquip attaches the equipped
	# weapon's visual on a "GEquipSlot" node instead (_sync_equip_visual, called from _ready
	# once RpgState exists). The swing routine in _process rotates that slot, same formula.
	# Third-person SpringArm orbit rig: a yaw pivot that follows the player, a
	# collision-aware spring arm (pulls the cam in at walls), and the camera on
	# the tip — empirically the cam lands at +Z*length, auto-aimed at the pivot.
	# Pitch is clamped so it can never dive to the floor; movement is camera-relative.
	cam_rig = Node3D.new()
	add_child(cam_rig)
	# The rig is driven EVERY RENDER FRAME in _process (and already reads the player's INTERPOLATED transform),
	# so it must NOT also be engine-interpolated — otherwise it blends against a stale prior-tick snapshot and
	# lags/quantizes to the physics tick while the world renders sub-tick = a constant view shimmer (the residual
	# "still jittering"). OFF makes the camera use its _process transform directly, tracking the world exactly.
	cam_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cam_spring = SpringArm3D.new()
	cam_spring.spring_length = CAM_DIST
	cam_spring.collision_mask = L_WORLD
	cam_spring.margin = 0.3
	cam_spring.rotation.x = cam_pitch
	cam_rig.add_child(cam_spring)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.1     # up from the 0.05 default — better distant depth precision
	cam.far = 500.0    # pulled in from the 4000 default for depth precision + to frustum-cull empty distance (mobile); comfortably clears the chunk-streaming skyline (SKYLINE_RADIUS ~160m, ~226m at the diagonal) with headroom for larger authored worlds
	cam_spring.add_child(cam)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


# Seat a MODEL avatar so its feet rest on the floor (y=0 at the body origin).
# Library/Meshy character GLBs often have their origin at the hips/centre, so
# without this the feet sink under the floor — props get the same treatment in
# the AreaBuilder; this is the player-side equivalent. Call after add_child().
const AVATAR_FOOT_LIFT := 0.05   # lowest skeleton bone is the ankle/toe; nudge up a hair so soles sit ON the ground, not a toe-thickness into it

func _seat_avatar(node: Node3D) -> void:
	# Seat the avatar so its FEET rest at the body origin. Prefer the SKELETON's lowest bone over the
	# raw mesh AABB: a Meshy/library character's lowest MESH point is often a robe/cape/tail/weapon that
	# hangs BELOW the soles, so seating the mesh-bottom at y=0 lifted the whole body ~0.5-0.8m — it
	# "floated above its shadow" while walking (root-caused live). Bone poses ignore dangling cloth.
	# Falls back to the mesh AABB only when the model is unrigged (no Skeleton3D).
	var foot := _skeleton_min_y(node)
	if is_finite(foot):
		node.position.y -= (foot - AVATAR_FOOT_LIFT)
	else:
		node.position.y -= _subtree_aabb(node).position.y
	# verify.mjs floating-avatar gate: the SEATED mesh's lowest point in player-local space. A correct
	# seat leaves it near 0 (feet at the ground origin; a rigged cape may drag slightly below). Well
	# above 0 means the whole avatar was lifted off the ground — it "floats above its shadow".
	print("GOGI_HERO_SEAT %.3f" % _subtree_aabb(node).position.y)


# PER-FRAME FOOT GROUNDING. _seat_avatar() sets the model's Y ONCE from the ATTACH pose — a straight-
# legged rest/idle pose where the feet hang at their LOWEST. The run/walk clips BEND the knees and tuck
# the feet HIGHER relative to the hips, so a static seat left the RUNNING avatar floating ~0.5m above
# its shadow (idle sat fine, run floated — no single seat grounds both). This re-pins the lowest FOOT
# bone to the ground every frame, so every locomotion pose stays grounded. On foot only (a mounted
# rider is posed by GPose). Cheap: one skeleton bone-scan for the single hero.
func _ground_hero_feet() -> void:
	# is_instance_valid() is NOT enough. A scene teardown DETACHES nodes before freeing them, so
	# through that window the avatar is a live object that is no longer in the tree — and
	# `global_transform` on an out-of-tree Node3D is an error return, not a value. This runs every
	# frame, so the gap produced ~50 "Condition !is_inside_tree() is true" errors per world swap.
	if _hero_avatar == null or not is_instance_valid(_hero_avatar) or not _hero_avatar.is_inside_tree():
		return
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return
	var foot_world := _skeleton_min_y(_hero_avatar)   # world Y of the current pose's lowest foot bone
	if not is_finite(foot_world):
		return
	_foot_raw = foot_world - player.global_position.y   # DIAGNOSTIC: TRUE render-pose foot height (before any correction)
	# _hero_avatar.position.y -= (_foot_raw - AVATAR_FOOT_LIFT)   # correction OFF while measuring the raw float


func _skeleton_min_y(root: Node) -> float:
	var skels := root.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		return INF
	var skel := skels[0] as Skeleton3D
	# Same out-of-tree window as _ground_hero_feet guards — checked here too, since this reads
	# `global_transform` and any other caller would hit it identically.
	if skel == null or not skel.is_inside_tree():
		return INF
	# Seat by the true FOOT bones. A rigged cape/cloak/skirt/tail/coat hangs BELOW the soles, so
	# taking the raw lowest bone picks the cloth tip and over-lifts the whole body — it "floats above
	# its shadow" while walking even though the mesh-AABB fix was already in place (the caped Warden
	# defeated it because its cloth is RIGGED, not just mesh). Skip those bones by name; if a rig
	# leaves them all filtered (unnamed Meshy cloth), fall back to the unfiltered min so we never
	# return INF for a rigged model.
	# Seat by the LOWEST bone POSITIVELY identified as a foot (allowlist), not the lowest
	# bone-minus-a-cloth-BLOCKLIST. A blocklist can never enumerate every rigged thing that hangs
	# below the soles (cape/tail AND scabbard, sheath, quiver, holster, bag, or a generically-named
	# Meshy auto-rig bone); any un-listed one becomes the lowest sample, so the seat lifts the whole
	# avatar until that tip reaches y=0 and the FEET float above the ground. The allowlist can't be
	# fooled that way. Fall back to lowest-non-cloth, then lowest-of-all, so an unnamed/non-humanoid
	# rig still seats and we never return INF for a rigged model.
	var best_foot := INF
	var best_cloth := INF
	var best_any := INF
	for i in skel.get_bone_count():
		var wy: float = (skel.global_transform * skel.get_bone_global_pose(i).origin).y
		best_any = minf(best_any, wy)
		var bn := skel.get_bone_name(i).to_lower()
		if _is_foot_bone(bn):
			best_foot = minf(best_foot, wy)
		if not _is_cloth_bone(bn):
			best_cloth = minf(best_cloth, wy)
	if is_finite(best_foot):
		return best_foot
	return best_cloth if is_finite(best_cloth) else best_any


# Dangling cloth / appendage bones that can hang below the soles and must not be treated as the foot.
func _is_cloth_bone(bn: String) -> bool:
	for kw in ["cape", "cloak", "cloth", "skirt", "robe", "coat", "dress", "tail", "scarf", "sash", "tassel", "ribbon", "hair", "beard"]:
		if kw in bn:
			return true
	return false


# Bones that ARE the ground contact — seat the avatar by the LOWEST of these. An allowlist, unlike
# the cloth blocklist, can't be defeated by an un-enumerated below-sole appendage (scabbard/sheath/
# quiver/tail/…). Covers Mixamo ("LeftFoot"/"LeftToeBase"), Rigify ("foot.L"/"toe.L"/"heel.02.L"),
# and Meshy ("LeftFoot"/"RightFoot") naming.
func _is_foot_bone(bn: String) -> bool:
	for kw in ["foot", "toe", "ankle", "heel"]:
		if kw in bn:
			return true
	return false


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


# ---------------- native hero_model (world.json "hero_model") ----------------

# A world-level "hero_model" wears a real character GLB in place of the placeholder capsule — the
# NATIVE form of the _build_player recipe. The GLB is fetched (same GLTFDocument.append_from_buffer
# idiom as area_builder), scaled to the capsule height, feet-seated, and idle-autoplayed. GUARDS:
#  (a) a builder that already wired an avatar the documented way (ANY Skeleton3D under the player)
#      wins — we skip; (b) a single fetch RETRY (QA P1 finding) before degrading to the capsule.
# Relative paths resolve through _norm, exactly like vehicle/weapon model URLs.
# ---------------- auth (world.json "auth" / implied by "multiplayer") ----------------

# Credentials live in the WORLD, not the template — same rule as multiplayer. The anon key is
# publishable and identifies the project only; it is never a session.
# SAVE SETUP. The world does not have to ask for saving — it is IMPLIED by wanting something kept:
# any var marked `persist`, or a `building` block (a build nobody can come back to is not a build).
# Backend defaults to local, which needs no account and works offline; a world opts into cloud only
# when it genuinely wants cross-device or shared state. This is the same rule as auth: never make a
# solo player sign in to remember their own high score.
func _setup_save(world: Dictionary) -> void:
	if Save == null:
		return
	var wants := false
	var vs = world.get("vars", {})
	if vs is Dictionary:
		for k in (vs as Dictionary):
			var sp = (vs as Dictionary)[k]
			if sp is Dictionary and bool((sp as Dictionary).get("persist", false)):
				wants = true
				break
	if world.get("building", null) is Dictionary:
		wants = true
	if not wants:
		Save.backend = "off"
		return
	var sc = world.get("save", {})
	var scfg: Dictionary = sc if sc is Dictionary else {}
	Save.configure(build_id, String(scfg.get("backend", "local")))
	await Save.load_state()
	if director != null and director.has_method("save_loaded"):
		director.save_loaded()   # the shell exists BEFORE this point — see game_shell.save_loaded


func _gate_auth() -> void:
	var mp: Variant = world_data.get("multiplayer", null)
	var cfg: Dictionary = mp if mp is Dictionary else {}
	var url := str(world_data.get("supabase_url", cfg.get("supabase_url", "")))
	var key := str(world_data.get("supabase_anon_key", cfg.get("supabase_anon_key", "")))
	var gate_script: GDScript = preload("res://auth_gate.gd")
	if not gate_script.Self_required(world_data):
		return
	if url == "" or key == "":
		push_warning("[Auth] world requires sign-in but carries no supabase_url/anon_key — skipping gate")
		return
	Auth.supabase_url = url
	Auth.supabase_anon_key = key
	var gate: CanvasLayer = gate_script.new()
	add_child(gate)
	await gate.gate(world_data)
	print("GOGI_AUTH gate passed uid=", Auth.uid)


# ---------------- multiplayer (world.json "multiplayer") ----------------

# The engine owns the netcode so a networked game stays DATA — see netsync.gd. Everything here is
# wiring: create the node, hand it the player and a way to build a remote body, and let world.json
# decide whether any of it runs.
func _setup_multiplayer() -> void:
	# MAP CHOOSER = MATCHMAKING. When the title screen offers maps (a director mode with a `map`),
	# the chosen map becomes part of the room, so two players who pick different maps land in
	# DIFFERENT rooms and never see each other. Without that they would share one room while
	# standing in different areas: netsync would faithfully render each peer at coordinates from a
	# map you are not in — players walking through walls, shots hitting nothing. That reads as
	# broken netcode and is impossible to diagnose from a phone.
	#
	# The connection therefore has to WAIT for the choice, because the room is fixed at connect
	# time and this runs during boot, long before the player touches a button. Held here, resumed
	# by game_shell._apply_mode -> begin_multiplayer(). Worlds with no map on any mode are
	# untouched: they connect right now, exactly as before.
	if _modes_offer_maps():
		_mp_awaiting_map = true
		return
	_start_multiplayer("")


## True iff any director mode names a `map`, i.e. the title screen is a map chooser. Read from
## world_data rather than the shell because this runs during boot and must not depend on the shell
## having finished building the title.
func _modes_offer_maps() -> bool:
	if not (world_data.get("multiplayer", null) is Dictionary):
		return false
	var d = world_data.get("director", null)
	if not (d is Dictionary):
		return false
	var ms = (d as Dictionary).get("modes", null)
	if not (ms is Array):
		return false
	for m in (ms as Array):
		if m is Dictionary and String((m as Dictionary).get("map", "")) != "":
			return true
	return false


## Called by game_shell once the player picks a mode. `map_id` is "" for a mode that names no map
## (a mixed world where only some modes are maps) — that connects to the unsuffixed room, which is
## the correct answer: those modes all share one match.
func begin_multiplayer(map_id: String) -> void:
	if not _mp_awaiting_map:
		return
	_mp_awaiting_map = false
	_start_multiplayer(map_id)


## Compose the room a given map plays in. Pure and separate from _start_multiplayer so the nettest
## harness can assert the property that actually matters — same map, same room; different map,
## different room — against THIS code rather than a copy of it in a test.
func _room_for_map(base: String, map_id: String) -> String:
	if map_id == "":
		return base
	return base + "#" + map_id


func _start_multiplayer(map_id: String) -> void:
	if netsync == null:
		netsync = preload("res://netsync.gd").new()
		netsync.name = "GNetSync"
		add_child(netsync)
	else:
		netsync.reset_for_world_change()
	# A room from the host beats whatever the world names, so a shared link drops you into your
	# friend's room rather than the world's default. `_current_room` was resolved in _ready and is
	# correct for BOTH entry paths — the command line on the first world, the swap message on every
	# one after it.
	var mp: Variant = world_data.get("multiplayer", null)
	if mp is Dictionary:
		var cfg: Dictionary = mp
		if _current_room != "":
			cfg["room"] = _current_room
		elif str(cfg.get("room", "")) == "":
			# THE BUILD IS THE ROOM. Without this, a player with no room in their link gets a random
			# code that is never displayed anywhere — so they cannot share it and nobody can join
			# them. Deriving it from the build means everyone who opens the same game link lands in
			# the same room automatically, with nothing to copy and no query string to remember.
			# An explicit ?room= / --room= still wins, for a private room.
			cfg["room"] = _room_from_build()
		# The map rides on TOP of whichever room won above — an explicit ?room= link, the world's
		# own room, or the build-derived one. Suffix, never replace: friends sharing a private room
		# still share it, they just split by map inside it, and "#" cannot collide with a room code.
		cfg["room"] = _room_for_map(String(cfg.get("room", "")), map_id)
		# Always report the RESOLVED room, map or not. netsync prints one too, but only once the
		# room answers — so a game that never connects printed nothing at all, and "which room am I
		# in" was unanswerable exactly when it mattered. This line is also the only thing a headless
		# test can read to prove a map-less mode was left unsuffixed.
		print("GOGI_MP resolved map=", map_id if map_id != "" else "-", " room=", cfg["room"])
	if not netsync.identified.is_connected(_on_identified):
		netsync.identified.connect(_on_identified)
	if not netsync.hit_taken.is_connected(_on_hit_taken):
		netsync.hit_taken.connect(_on_hit_taken)
	if not netsync.killed.is_connected(_on_killed_peer):
		netsync.killed.connect(_on_killed_peer)
	if not netsync.peer_shot.is_connected(_on_peer_shot):
		netsync.peer_shot.connect(_on_peer_shot)
	netsync._peer_layer = L_PEER
	netsync.hp_probe = func() -> float: return rpg.hp if rpg != null else 1.0
	netsync.configure(world_data, player, Callable(self, "_make_remote_avatar"), {
		"state": Callable(self, "_net_avatar_state"),
		"equip": Callable(self, "_peer_equip"),
		"vehicle": Callable(self, "_peer_vehicle"),
	})


# A hit claim from another player SURVIVED their validation, so it is real as far as we are concerned.
# Routed through the ordinary take_damage door: that is what gives PvP the hurt flash, the camera
# kick, `player_damaged`, the opt-in death rules and checkpoint respawn, for free and identically to
# every other source of damage in the engine.
func _on_hit_taken(from_id: String, dmg: float) -> void:
	if director != null:
		director.fire("hit_by_player", {"id": from_id, "amount": dmg})
	# WHERE IT CAME FROM is the part a player actually needs. The full-screen red flash was removed
	# on purpose for reading as an intrusive popup, and this is not that: a short arc at the edge of
	# the screen pointing at the shooter, which tells you which way to turn instead of only that
	# something bad happened.
	if netsync != null:
		for b in netsync.peer_bodies():
			if is_instance_valid(b) and String(b.get("peer_id")) == from_id:
				_mark_damage_from((b as Node3D).global_position)
				break
	take_damage(dmg)


# A remote player fired. Draw their shot with damage stripped out: the tracer is a picture of an
# event that already happened elsewhere, and the only thing allowed to hurt us is a validated `hit`.
func _on_peer_shot(_from_id: String, origin: Vector3, dir: Vector3, speed: float, rng: float) -> void:
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer == null:
		return
	var root: Node3D = streamer.current_root
	if root == null or not is_instance_valid(root):
		return
	GProjectile.flash(origin, root)
	AudioManager.play_sfx("attack")
	# No enemies_provider: an empty Callable means the projectile runs its world raycast and can hit
	# NOTHING. Two clients each resolving the same shot is the classic way to double-count damage.
	GProjectile.fire(root, origin, dir,
		{"kind": "ranged", "damage": 0.0, "range": rng, "projectile": {"speed": speed, "arc": false}},
		Callable())


func _on_killed_peer(target_id: String) -> void:
	if director != null:
		director.fire("player_killed", {"id": target_id})


# The room has told us who we are, so the local placeholder can finally take the colour every OTHER
# screen is already drawing us in. Only the placeholder capsule — a world with a hero_model dresses
# every player in the same avatar on purpose, and tinting that would fight its materials.
func _on_identified(id: String) -> void:
	if _capsule_body != null and is_instance_valid(_capsule_body):
		_capsule_body.material_override = _mat(netsync.color_for(id))
	print("GOGI_MP_ME id=", id, " colour=", netsync.color_for(id).to_html(false))


# A room name that is stable for everyone playing this build. Empty when the URL has no usable
# segment (a bare-root local verify server) — net.gd then falls back to generating one.
func _room_from_build() -> String:
	var seg := build_id
	if seg == "":
		var tail := world_url.substr(origin.length()).lstrip("/")
		if tail != "":
			seg = tail.split("/")[0]
	if seg == "" or seg.ends_with(".json"):
		return ""
	# The room becomes part of a Realtime channel topic, so keep it to characters that cannot
	# confuse the topic string.
	var out := ""
	for ch in seg.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-" or ch == "_" else "-"
	return out.substr(0, 40)


# `--room=CODE` after the `--` separator, the same channel `--world-url` arrives on. Empty on web,
# where net.gd reads `?room=` from the page URL instead.
func _cmdline_room() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--room="):
			return a.substr(7).strip_edges()
	return ""


# A remote body: the same character the local player wears, so peers look like players rather than
# like debug capsules. Returns null when the world names no hero model — netsync falls back.
## Play a one-shot emote clip on the LOCAL hero. The rule layer reaches this through
## GameShell.play_emote, which also broadcasts it so every other screen plays the same clip.
func play_emote_local(clip: String, hold := 1.2) -> void:
	_hero_anim_state.action(clip, hold)


## What THIS client broadcasts about its own avatar, merged into the 10Hz position packet by
## netsync. Keep it small and keep it DERIVED — it is read 10x/s, so nothing here may allocate
## or await. Defaults (unarmed, unstowed, dry) are dropped on the wire by the sender.
func _net_avatar_state() -> Dictionary:
	return {
		"w": String(rpg.equipped_weapon) if rpg != null else "",
		"stw": _weapon_stowed,
		"sw": swimming,
		# Which ride we are on, as its index in world.json's "vehicles" — the one identifier every
		# client already agrees on, because they all built that array from the same file in order.
		"mv": vehicles.find(active_vehicle) if (active_vehicle != null and is_instance_valid(active_vehicle)) else -1,
	}


## Resolve a world vehicle by the index a peer broadcast. netsync holds no world state, so it
## asks; -1 and out-of-range both mean "no ride", which is what a stale index during a hot-reload
## looks like.
func _peer_vehicle(index: int):
	if index < 0 or index >= vehicles.size():
		return null
	var v = vehicles[index]
	return v if (v != null and is_instance_valid(v)) else null


## Put a weapon in a PEER's hand. The mirror of _sync_equip_visual, and deliberately the same
## resolve -> prefetch -> GEquip.equip shape: GEquip works on ANY character, and a peer wears the
## same hero_model as the local player, so the hand bone it resolves is the same one. netsync
## calls this through a hook because it must not learn what a weapon def or a builder cache is.
func _peer_equip(avatar: Node3D, id: String, stowed: bool) -> void:
	if avatar == null or not is_instance_valid(avatar):
		return
	if id == "":
		GEquip.unequip(avatar)
		return
	var def: Dictionary = rpg.weapon_def(id) if rpg != null else {}
	if def.is_empty():
		return
	var model: Node3D = null
	var mu := String(def.get("model", ""))
	if mu != "" and not mu.begins_with("parametric:"):
		var u := _norm(mu)
		if u != "":
			await builder._ensure([u])
			if builder.cache.has(u) and builder.cache[u] != null:
				model = (builder.cache[u] as Node).duplicate() as Node3D
	# The fetch above is multi-frame, and interest culling frees peer avatars mid-flight. Without
	# this the equip lands on a freed node — the classic await-then-touch-a-dead-object crash.
	if not is_instance_valid(avatar):
		return
	GEquip.equip(avatar, def, model)
	var slot := avatar.find_child("GEquipSlot", true, false) as Node3D
	if slot != null:
		slot.visible = not stowed


func _make_remote_avatar() -> Node3D:
	var hero := String(world_data.get("hero_model", ""))
	if hero == "":
		return null
	var url := _norm(hero)
	if url == "":
		return null
	var node := await _fetch_glb_scene(url)
	if node == null:
		return null
	# SIZE IT, then seat it. This used to seat only — so a peer rendered at the GLB's authored size
	# while the local hero was normalized to HERO_HEIGHT. With KayKit that is 2.27m of peer against a
	# 1.65m-target hero: every player saw everyone else as a different species, and since peer_body's
	# hit capsule is built to HERO_HEIGHT, the part of a peer sticking out above it was unshootable.
	# Whatever the hero is measured and scaled to, a peer wearing the SAME hero_model must match.
	_normalize_avatar_height(node)
	# Seat it the same way the local hero is seated, or peers stand hip-deep in the floor: character
	# GLB origins sit at the hips, not the feet.
	_seat_avatar(node)
	return node


# Scale a fetched character GLB so it stands HERO_HEIGHT tall. Shared by the local hero and every
# remote peer — the two paths are why this is a function and not two similar blocks: they were two
# similar blocks, and one of them silently lost its scaling step.
func _normalize_avatar_height(node: Node3D) -> float:
	var h := _char_height(node)
	if h > 0.05:
		node.scale *= HERO_HEIGHT / h
		return h
	# Unmeasurable (no rig, no mesh): fall back to the raw subtree AABB rather than shipping the GLB
	# at whatever size it happened to be authored at.
	var ab := _subtree_aabb(node)
	if ab.size.y > 0.001:
		node.scale *= HERO_HEIGHT / ab.size.y
	return 0.0


func _attach_hero_model() -> void:
	if player == null:
		return
	var hero := String(world_data.get("hero_model", ""))
	if hero == "":
		return
	if not player.find_children("*", "Skeleton3D", true, false).is_empty():
		print("GOGI_HERO builder-wired avatar detected — native attach skipped")
		return
	var url := _norm(hero)
	if url == "":
		return
	# Retry the fetch with backoff — a transient GLB fetch failure must not strand the player as the
	# placeholder capsule (no skeleton -> the weapon can't attach to a hand and floats, and there are
	# no body anims). ~4 attempts before degrading.
	var node: Node3D = null
	for attempt in range(4):
		node = await _fetch_glb_scene(url)
		if node != null:
			break
		await get_tree().create_timer(0.4).timeout
	if node == null:
		return
	node.name = "GogiHeroAvatar"
	player.add_child(node)
	_hero_avatar = node
	# Size to the capsule (~1.65 m tall). Same helper the remote-peer factory uses, so a peer and the
	# local player wearing one hero_model are always the same height.
	var h := _normalize_avatar_height(node)
	_seat_avatar(node)                           # skeleton-aware: feet (not dangling cloth) to y=0
	if _capsule_body != null and is_instance_valid(_capsule_body):
		_capsule_body.visible = false            # the placeholder body gives way to the avatar
	_hero_anim_state.attach(node)
	# The avatar streams in from R2, so it can attach LONG after the player entered the water. GPose.swim
	# was a silent no-op back then (the capsule has no skeleton), and nothing would ever retry — the
	# swimmer would run their walk cycle while floating. Apply it now that there is a rig to pose. Stays
	# HERE rather than in the module: a peer has no CharacterBody3D to pose.
	if swimming:
		GPose.swim(player)
	# Ground the feet AFTER the skeleton pose is computed each frame (skeleton_updated fires post-anim,
	# pre-render) — running it in _process grounded the PREVIOUS frame's pose while the render showed the
	# current one, leaving a residual float. This hook reads/corrects the exact pose that gets drawn.
	var _sk := node.find_children("*", "Skeleton3D", true, false)
	if not _sk.is_empty():
		(_sk[0] as Skeleton3D).skeleton_updated.connect(_ground_hero_feet)
	# WEAPON RE-ATTACH: the weapon was equipped in _ready/_boot BEFORE this rigged avatar existed, so
	# GEquip fell back to the fixed capsule-offset slot and the weapon FLOATS beside the body. Now that
	# the skeleton (and its hand bone) is present, clear the sync guard and re-equip so GEquip resolves
	# the real hand BoneAttachment3D and the weapon sits IN the hand. Mirrors the re-stat idiom in _poll_world.
	if rpg != null and String(rpg.equipped_weapon) != "":
		_equipped_visual_id = ""
		await _sync_equip_visual()
	print("GOGI_HERO native avatar attached (char_h=%.3f)" % h)
	# verify.mjs hero-SCALE gate. The pre-scale measurement is not enough on its own — the bug this
	# gate exists for was a WRONG measurement, which looked perfectly healthy in isolation. So print
	# what the avatar ACTUALLY ends up being: if that is not HERO_HEIGHT, the model in front of the
	# player is the wrong size no matter what we measured.
	# NOTE the `* node.scale.y`. char_height reports in the node's OWN frame and therefore does not
	# see the node's own scale — re-calling it after scaling returns the identical number and would
	# assert nothing at all. (Caught by SCALETEST, which is the entire point of having it.)
	print("GOGI_HERO_H %.3f %.3f" % [h, _char_height(node) * node.scale.y])


# TRUE height of a character model — bones UNIONED WITH THE MESH ENVELOPE, so what we measure is
# what the player sees. See GPose.char_height for why the bone span alone is not it: this function
# used to be a bones-only copy, which read KayKit's chibi rig as 1.24m against its real 2.27m and so
# scaled every library hero UP by 1.33x — a 3m player who towered over the cars they drove.
func _char_height(node: Node3D) -> float:
	return GPose.char_height(node)


# Fetch a GLB by absolute URL -> instanced scene root (null on any failure). Mirrors the builder's
# parse path (append_from_buffer -> generate_scene); the caller owns the single retry.
func _fetch_glb_scene(url: String) -> Node3D:
	var req := HTTPRequest.new()
	add_child(req)
	if req.request(url) != OK:
		req.queue_free()
		return null
	var res = await req.request_completed
	req.queue_free()
	if res[1] != 200:
		return null
	var buf := res[3] as PackedByteArray
	if buf.is_empty():
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(buf, "", st) != OK:
		return null
	var scene := doc.generate_scene(st) as Node3D
	GSurf.cap_textures_for_web(scene)   # mobile VRAM cap (web only), same as area_builder's cell templates
	return scene




func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	# Hidden at the LAYER, so everything drawn into it goes at once — the stats block, health bar,
	# minimap, action buttons, and the controls building.gd and rules.gd add later. Hiding each
	# owner separately would mean a new one silently reappearing in recordings.
	hud_layer.visible = not capture_mode
	if capture_mode:
		# Printed so a recording can be PROVEN to have run clean. Without it, "the HUD is hidden" is
		# only checkable by eye on the finished clip, which is exactly the kind of thing that
		# silently regresses.
		print("GOGI_CAPTURE hud hidden")
	stats = Label.new()
	stats.position = Vector2(12, 12)
	stats.add_theme_font_size_override("font_size", 22)
	stats.add_theme_color_override("font_color", Color(0.9, 1.0, 0.9))
	hud_layer.add_child(stats)
	# Held on the instance because _relayout_ui repositions it — see the top-left block there. It used
	# to be a local, which is why it could only ever live at its build-time coordinates.
	_hp_bg = ColorRect.new()
	_hp_bg.color = Color(0, 0, 0, 0.5)
	_hp_bg.position = Vector2(12, 112)
	_hp_bg.size = Vector2(220, 14)
	hud_layer.add_child(_hp_bg)
	hp_bar = ColorRect.new()
	hp_bar.color = Color(0.85, 0.25, 0.25)
	hp_bar.position = Vector2(12, 112)
	hp_bar.size = Vector2(220, 14)
	hud_layer.add_child(hp_bar)
	# full-screen red flash for damage feedback (starts transparent; _flash_hurt pulses it). Ignores
	# mouse so it never eats a HUD button press, and it's non-modal — just juice, no popup.
	var vp := get_viewport().get_visible_rect().size
	_hud_btns["attack"] = _button("ATTACK", vp - Vector2(250, 180), Vector2(220, 130), _attack)
	_hud_btns["use"] = _button("USE", vp - Vector2(250, 330), Vector2(220, 120), func() -> void: interaction.try_use())
	_hud_btns["potion"] = _button("POTION", vp - Vector2(490, 180), Vector2(220, 130), func() -> void: rpg.use_potion())
	_weapon_btn = _button("SHEATHE", vp - Vector2(490, 330), Vector2(220, 120), _toggle_weapon)
	_hud_btns["weapon"] = _weapon_btn
	# JUMP in the RIGHT thumb column (720-wide portrait base: x=vp-250 keeps it on-screen and OUT of the
	# left-half movement joystick — the old x=vp-730 fell off the left edge on mobile).
	_hud_btns["jump"] = _button("JUMP", vp - Vector2(250, 480), Vector2(220, 130), func() -> void: _jump_queued = true)
	# GET-OFF: a dedicated, discoverable dismount control. Exit was bound to USE with NO on-screen
	# affordance, so riders had no way to know how to get off any vehicle/mount. This button is hidden
	# on foot and shown the moment you board (toggled in _on_vehicle_drive_state); it calls the same
	# guarded exit() every profile uses (flight requests a braked descent-then-dismount, so it's safe
	# mid-air too).
	_dismount_btn = _button("DISMOUNT", vp - Vector2(490, 480), Vector2(220, 130), func() -> void:
		if active_vehicle != null and is_instance_valid(active_vehicle):
			active_vehicle.exit())
	_dismount_btn.visible = false
	_hud_btns["dismount"] = _dismount_btn
	_hud_btns["stable"] = _button("STABLE", Vector2(vp.x - 250, 12), Vector2(220, 90),
		func() -> void:
			if director != null:
				director.toggle_stable_panel())
	# WEAPON cycle: swap between every weapon found so far (force-equip -> auto-draw). Without it a
	# picked-up spear/rifle/tommy gun was stuck behind the auto-equip gate with no way to select it.
	_hud_btns["cycle"] = _button("WEAPON >", Vector2(vp.x - 250, 158), Vector2(220, 90),
		func() -> void:
			if rpg != null and rpg.cycle_weapon():
				AudioManager.play_sfx("pickup"))
	# MINIMAP (universal): a north-up schematic of the world around the player; sized/placed in _relayout_ui.
	# preload (not load) so a parse error in minimap.gd fails the EXPORT at build time instead of shipping a
	# broken script that returns null at runtime (-> "memory access out of bounds" on the web build).
	var mm_script = preload("res://minimap.gd")
	if mm_script != null:
		_minimap = mm_script.new()
		_minimap.set("main", self)
		_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_minimap.clip_contents = true
		hud_layer.add_child(_minimap)
	_relayout_ui()


# The design base is PORTRAIT 720x1280 with aspect EXPAND, which scales the UI by the WIDTH
# ratio — a LANDSCAPE phone (e.g. 860x400) therefore renders the whole UI at ~0.31x design
# scale (7px stats text, 41px-tall buttons). Rescale from the SHORT side instead so text and
# buttons keep their designed physical size at any orientation.
func _fit_ui_scale() -> void:
	var win := get_window()
	var sz: Vector2 = Vector2(win.size)
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	# content_scale_factor MULTIPLIES the automatic expand scale (min of the per-axis ratios),
	# so apply the ratio between the wanted short-side scale and the automatic one.
	var auto_scale := minf(sz.x / 720.0, sz.y / 1280.0)
	if auto_scale <= 0.0:
		return
	win.content_scale_factor = (minf(sz.x, sz.y) / 720.0) / auto_scale


# Reposition the HUD against the LIVE (expanded) viewport — called on every window resize /
# rotation so portrait AND landscape phones get on-screen controls (never a stale base rect).
# Screen edges the HUD must stay out of, in VIEWPORT units.
#
# A phone with a sensor housing and rounded corners does not give you the whole rectangle. In
# landscape the housing eats one long edge and both corners clip, so a HUD pinned to (12, 12) lands
# UNDER the corner — which is exactly what happened natively: the Lv/HP/Inv block was unreadable in
# the top-left, and the bottom row sat under the home indicator.
#
# This never mattered on the web tier and that is why it went unnoticed: Safari applies the safe area
# to the page itself, so the canvas Godot draws into is already inset. A native player gets the raw
# display, insets included, and has to do it itself.
#
# `get_display_safe_area()` reports SCREEN PIXELS while the HUD is laid out in viewport units (the
# window carries a content scale), so the ratio — not the raw pixel count — is what transfers.
# Everywhere without insets, including web and desktop, the safe area IS the screen and this returns
# zero, so there is no platform branch to keep in sync.
func _safe_insets() -> Vector4:
	# MEASURED AGAINST THE WINDOW, NOT THE SCREEN.
	#
	# This used to subtract the safe area from `DisplayServer.screen_get_size()`. On iOS Safari
	# `window.screen.height` does NOT rotate — it keeps reporting the PORTRAIT height (~932) while
	# the actual canvas in landscape is ~412 tall. So `scr.y - sa.size.y` invented a ~520px bottom
	# inset, which scaled to ~400 game units and lifted the whole thumb grid off the bottom of the
	# screen: every action button sat in the top-right corner with the bottom 60% of a landscape
	# phone empty, and JUMP clipped off the top edge. Unplayable, on the web tier, on the exact
	# orientation these games are played in.
	#
	# The window is the surface we actually draw to, so it is the only correct denominator.
	var win := Vector2(get_window().size)
	if win.x <= 0.0 or win.y <= 0.0:
		return Vector4.ZERO
	var sa := DisplayServer.get_display_safe_area()
	var sw := float(sa.size.x)
	var sh := float(sa.size.y)
	# A safe area that is not a subset of the window is a bad reading, not a real inset.
	if sw <= 0.0 or sh <= 0.0 or sw > win.x + 1.0 or sh > win.y + 1.0:
		return Vector4.ZERO
	var left := maxf(0.0, float(sa.position.x))
	var top := maxf(0.0, float(sa.position.y))
	var right := maxf(0.0, win.x - left - sw)
	var bottom := maxf(0.0, win.y - top - sh)
	var vp := get_viewport().get_visible_rect().size
	# A notch, a corner radius and a home indicator are SLIVERS. Anything claiming more than an
	# eighth of an axis is a misread platform value; clamp instead of trusting it. Real values are
	# well under this (an iPhone landscape notch is ~6%, the home indicator ~5%), so nothing legit
	# is lost — but no future platform quirk can shove the controls off-screen again.
	var cx := vp.x * 0.12
	var cy := vp.y * 0.12
	return Vector4(
		minf(vp.x * (left / win.x), cx),
		minf(vp.y * (top / win.y), cy),
		minf(vp.x * (right / win.x), cx),
		minf(vp.y * (bottom / win.y), cy)
	)


func _relayout_ui() -> void:
	_fit_ui_scale()
	if hud_layer == null or _hud_btns.is_empty():
		return
	var vp := get_viewport().get_visible_rect().size
	var bw := clampf(vp.x * 0.28, 150.0, 230.0)         # button width scales with the screen
	var m := 18.0
	# Keep every edge-anchored element clear of the notch, the rounded corners and the home
	# indicator. Zero on hardware without them.
	var si := _safe_insets()
	var ml := m + si.x
	var mt := m + si.y
	var mr := m + si.z
	var mb := m + si.w
	# the two-column block must live ENTIRELY in the right half — the left half is the movement
	# joystick zone, and a POTION/WEAPON/DISMOUNT column that crossed the half-line ate joystick
	# touches (and vice versa) in portrait.
	bw = minf(bw, (vp.x * 0.5 - 3.0 * m) * 0.5)
	# THE THUMB GRID MUST FIT ON THE SCREEN IT IS DRAWN ON.
	# `clampf(.., 84, 130)` guarantees a button HEIGHT; it does not ask whether three rows of that
	# height fit. On a short viewport (a landscape phone browser, where the URL bar eats the top)
	# 3*84 + gaps + margins exceeds vp.y, so the top row — JUMP and DISMOUNT — was positioned at a
	# NEGATIVE y and clipped off the top edge. Jumping is a core verb, and it was unreachable in
	# every game built on this template at that aspect. Seen as a sliver of a button above USE.
	#
	# So the row height is capped by the space there actually is. The 52 floor keeps a button
	# tappable; the y clamp below is the backstop for a viewport too short even for that.
	var rows_h := vp.y - mt - mb - 40.0 - 2.0 * m
	var bh := clampf(vp.y * 0.13, 84.0, 130.0)
	bh = maxf(52.0, minf(bh, rows_h / 3.0))
	for k in _hud_btns:
		var b: Button = _hud_btns[k]
		if b == null or not is_instance_valid(b):
			continue
		b.size = Vector2(bw, bh)
	# Row baselines, clamped so no row can ever start above the top margin. Computed once and shared
	# by both columns, so the two can never drift apart the way six separate expressions could.
	var row1 := vp.y - bh - mb - 40.0                     # ATTACK / POTION
	var row2 := vp.y - 2.0 * bh - m - mb - 40.0           # USE / SHEATHE
	var row3 := vp.y - 3.0 * bh - 2.0 * m - mb - 40.0     # JUMP / DISMOUNT
	row3 = maxf(row3, mt)
	row2 = maxf(row2, row3 + bh + m)
	row1 = maxf(row1, row2 + bh + m)
	var col_r := vp.x - bw - mr
	var col_l := vp.x - 2.0 * bw - m - mr
	(_hud_btns["attack"] as Button).position = Vector2(col_r, row1)
	(_hud_btns["use"] as Button).position = Vector2(col_r, row2)
	(_hud_btns["jump"] as Button).position = Vector2(col_r, row3)
	(_hud_btns["potion"] as Button).position = Vector2(col_l, row1)
	(_hud_btns["dismount"] as Button).position = Vector2(col_l, row3)
	(_hud_btns["weapon"] as Button).position = Vector2(col_l, row2)
	# One line naming the geometry, so a bad layout can be diagnosed from a log instead of measured
	# off a screenshot — which is how the clipped JUMP row was found, three screenshots in.
	var grid_line := "vp %.0fx%.0f  win %.0fx%.0f  scale %.2f\nbw %.0f bh %.0f  rows %.0f / %.0f / %.0f\ninsets L%.0f T%.0f R%.0f B%.0f" % [
		vp.x, vp.y, float(get_window().size.x), float(get_window().size.y),
		get_window().content_scale_factor, bw, bh, row3, row2, row1, si.x, si.y, si.z, si.w]
	print("GOGI_HUD_GRID ", grid_line.replace("\n", "  "))
	if hud_debug:
		if _hud_dbg_lbl == null or not is_instance_valid(_hud_dbg_lbl):
			_hud_dbg_lbl = Label.new()
			_hud_dbg_lbl.add_theme_font_size_override("font_size", 20)
			_hud_dbg_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
			_hud_dbg_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
			_hud_dbg_lbl.add_theme_constant_override("shadow_offset_y", 2)
			hud_layer.add_child(_hud_dbg_lbl)
		_hud_dbg_lbl.text = grid_line
		_hud_dbg_lbl.position = Vector2(ml, vp.y * 0.42)
		_hud_dbg_lbl.z_index = 100
	# TOP-LEFT STATS BLOCK. Positioned here rather than only in _build_hud: that set it once to a
	# hardcoded (12, 12) and never touched it again, so it could not follow a rotation and had no way
	# to know about a safe area. This is the element that was unreadable under the corner.
	if stats != null and is_instance_valid(stats):
		stats.position = Vector2(ml, mt)
	var bar_y := mt + 100.0
	if _hp_bg != null and is_instance_valid(_hp_bg):
		_hp_bg.position = Vector2(ml, bar_y)
	if hp_bar != null and is_instance_valid(hp_bar):
		hp_bar.position = Vector2(ml, bar_y)

	# MINIMAP: top-right corner, SQUARE (equal w/h so it is never squished). Stable/cycle stack BELOW it.
	var mm := clampf(minf(vp.x, vp.y) * 0.26, 130.0, 300.0)
	if _minimap != null and is_instance_valid(_minimap):
		_minimap.position = Vector2(vp.x - mm - mr, mt)
		_minimap.size = Vector2(mm, mm)
	# Only reserve the minimap's space when the minimap is actually on screen — the stack used to be
	# pushed down by a 187px block that wasn't being drawn.
	var mm_shown := _minimap != null and is_instance_valid(_minimap) and _minimap.visible
	var below_mm := mt + ((mm + 12.0) if mm_shown else 0.0)
	var small_h := clampf(bh * 0.6, 54.0, 78.0)
	var stable_btn := _hud_btns["stable"] as Button
	var cyc := _hud_btns["cycle"] as Button
	stable_btn.size = Vector2(bw, small_h)
	cyc.size = Vector2(bw, small_h)

	# EARN YOUR PLACE ON A PHONE SCREEN.
	# STABLE called director.toggle_stable_panel(), which in the shared GameShell is literally `pass`
	# — a button that does nothing, shown in every game, sitting in prime thumb space. A game with a
	# real stable ships its own director and advertises it, the same opt-in pattern world_reloaded()
	# uses. WEAPON > cycles weapons and is meaningless until you own two.
	stable_btn.visible = director != null and director.has_method("has_stable") and director.has_stable()
	cyc.visible = rpg != null and rpg.has_method("weapon_count") and rpg.weapon_count() > 1

	# Stack whatever survived between the minimap and the top of the bottom-anchored grid, and DROP
	# anything that will not fit rather than let it overlap. An unreachable button under another
	# button is worse than an absent one — that is what put a half-cut control off the top edge.
	var top_row_y: float = (_hud_btns["jump"] as Button).position.y
	var slot_y := below_mm
	var avail := top_row_y - 10.0 - below_mm
	for opt in [stable_btn, cyc]:
		var ob: Button = opt
		if not ob.visible:
			continue
		if avail < small_h:
			ob.visible = false
			continue
		ob.position = Vector2(vp.x - bw - mr, slot_y)
		slot_y += small_h + 12.0
		avail -= small_h + 12.0
	# LAST WORD GOES TO THE GAME. Everything above re-decides `.visible` from engine state; a rule
	# that hid a control meant it, and a device rotation must not undo that.
	_apply_hud_hidden()
	# ...and the world's own readouts go last of all, because they place themselves by dodging the
	# rects computed above. Both layouts are wired to size_changed independently, and whichever ran
	# first was reading the other's stale geometry — which is how a `top_right` readout ended up
	# printed through the SHEATHE button.
	if director != null and director.get("rules") != null:
		director.rules._layout_hud()


# ---------------- `hud_show` / `hud_hide` (phase 8) ----------------
#
# One resolver for every addressable surface, so the two actions can never disagree about what a
# name means. Names cover the engine's own controls, the shell's readouts, and anything the world
# declared in its `hud` block (by `bind` or `button` id) — an author should not have to know which
# of those three built the thing they want gone.


func hud_targets(name_: String) -> Array:
	var out: Array = []
	var n := name_.to_lower()
	if n == "" :
		return out
	if _hud_btns.has(n):
		out.append(_hud_btns[n])
	match n:
		"stats":
			if stats != null:
				out.append(stats)
		"health", "hp":
			if _hp_bg != null:
				out.append(_hp_bg)
			if hp_bar != null:
				out.append(hp_bar)
		"minimap":
			if _minimap != null:
				out.append(_minimap)
		"quest":
			if director != null and director.get("_quest_lbl") != null:
				out.append(director._quest_lbl)
		"boss":
			if director != null and director.get("_boss_root") != null:
				out.append(director._boss_root)
		"buttons":
			for k in _hud_btns:
				out.append(_hud_btns[k])
		"all":
			for k in _hud_btns:
				out.append(_hud_btns[k])
			for extra in ["stats", "health", "minimap", "quest", "boss", "vars"]:
				for c in hud_targets(extra):
					if not out.has(c):
						out.append(c)
		"vars":
			out.append_array(_rule_hud_nodes(""))
	if out.is_empty():
		out.append_array(_rule_hud_nodes(n))   # a world-declared readout or button id
	return out


## Nodes the rule layer built from the world's `hud` block. `""` means all of them.
func _rule_hud_nodes(bind_or_id: String) -> Array:
	var out: Array = []
	if director == null or director.get("rules") == null:
		return out
	for h in (director.rules._hud as Array):
		if not (h is Dictionary):
			continue
		var rec: Dictionary = h
		if bind_or_id != "" and String(rec.get("bind", "")) != bind_or_id \
				and String(rec.get("id", "")) != bind_or_id:
			continue
		var nd = rec.get("node")
		if nd != null and is_instance_valid(nd):
			out.append(nd)
	return out


## Returns how many controls it actually moved, so rules.gd can report a name that matched nothing
## instead of logging a success for a typo.
func set_hud_visible(name_: String, on: bool) -> int:
	var hit := hud_targets(name_)
	for c in hit:
		(c as CanvasItem).visible = on
	if on:
		_hud_hidden.erase(name_.to_lower())
	else:
		_hud_hidden[name_.to_lower()] = true
	print("GOGI_HUD %s %s n=%d" % ["show" if on else "hide", name_, hit.size()])
	return hit.size()


## Re-apply the hidden set after any layout pass that re-decides `.visible` on its own.
func _apply_hud_hidden() -> void:
	for n in _hud_hidden:
		for c in hud_targets(String(n)):
			(c as CanvasItem).visible = false


func _button(text: String, pos: Vector2, sz: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 28)
	b.position = pos
	b.size = sz
	b.pressed.connect(cb)
	hud_layer.add_child(b)
	return b


# HUD draw/holster: flip the weapon between DRAWN (in hand) and SHEATHED (hidden). The button label
# tracks state; attacking auto-draws (see _attack), so a sheathed weapon never blocks combat.
func _toggle_weapon() -> void:
	_set_weapon_stowed(not _weapon_stowed)
	if _weapon_btn != null and is_instance_valid(_weapon_btn):
		_weapon_btn.text = "DRAW" if _weapon_stowed else "SHEATHE"
