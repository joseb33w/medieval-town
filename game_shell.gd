extends Node
## GAME SHELL — the DATA-DRIVEN game director.
##
## Every game wants the same furniture: a title screen with mode buttons, a quest label, toasts, a
## boss bar, region ambience and music, camera shake, a victory screen. That furniture used to be
## re-written as a bespoke `res://game_director.gd` for every game — ~430 lines of which roughly 90%
## was identical machinery and ~10% was values (this game's title, this game's quest order, this
## game's boss). GameShell is that 90%, shared; the 10% moves into a `director` block in world.json.
##
## WHY IT MATTERS BEYOND TIDINESS
## A game with no game-authored script is CONTENT rather than software, which is the line Apple's
## guideline 1.2.1 draws for creator content ("add content to those structured experiences", not
## "change the core features and functionality of the native app"). That is the prerequisite for
## ever shipping these games inside a native player app. It also makes the story editable by chat:
## world.json already hot-reloads, so a data-driven director means changing a stage toast or a boss
## name is a live edit instead of a re-export.
##
## PRECEDENCE: main.gd prefers a game-authored `res://game_director.gd` when one exists, so older
## games are untouched. GameShell runs only when there is no script and world.json has `director`.
##
## The engine calls exactly these (all null-guarded in main.gd):
##   setup(main) · world_ready() · world_reloaded() · input_locked() · on_kill(type)
##   _shake_cam(t) · toggle_stable_panel()

var main = null
var mode := ""                       # "" until a mode is chosen; else the chosen mode's id

## RULES — the data-driven behavior layer (rules.gd), created only when the world authors `rules`
## or `vars`. Hosted HERE rather than in main.gd because this node already owns the surfaces rules
## drive (toasts, the quest hook, the victory panel, the per-frame tick) and already dies with a
## world swap, which is exactly the lifetime a rule set wants.
var rules = null
var _tod := ""                       # last seen weather.time_state, for the time_of_day_changed event
var _wx := ""                        # last seen weather._active_wx, for the weather_changed event

var _cfg: Dictionary = {}            # world.json "director"
var _modes: Array = []
var _mode_cfg: Dictionary = {}       # the chosen mode's record
var _world_ready := false
var _won := false
var _lost := false          # defeat shown; a run ends exactly once, either way

var _layer: CanvasLayer = null
var _title_root: Control = null
var _win_root: Control = null
var _quest_lbl: Label = null
var _toast_lbl: Label = null
var _boss_root: Control = null
var _boss_fill: ColorRect = null
var _boss_name: Label = null

# --- phase 8: rule-driven screen FX and modals ---
# The fade/tint pair lives on its OWN layer, below the modal layer (150) and above the HUD (0). A
# cinematic `fade` is meant to cover the HUD; it is not meant to cover the panel a rule puts up in
# the same breath. scene_manager owns a separate fade for area transitions and the two must not
# share a rect — a rule fading out mid-transition would otherwise cancel the transition's fade in.
var _fx_layer: CanvasLayer = null
var _fade_rect: ColorRect = null
var _tint_rect: ColorRect = null
var _sub_lbl: Label = null
var _sub_t := 0.0
var _modal_root: Control = null      # `panel` / `prompt` — blocks play while open (input_locked)

var _chain: Array = []               # [{id, toast, on_done}] for the chosen mode
var _story_idx := -1
var _regions: Array = []
var _cur_region := ""
# ZONES are the 3D counterpart to regions, and they exist because regions cannot do this job.
# A region is a nearest-one-wins cylinder with NO height — documented as unable to tell one floor
# of a building from another — and exactly one is active at a time, because it drives ambience and
# music. A zone is an axis-aligned BOX, any number can contain you at once, and each is tracked
# independently. "On the second floor", "inside the blast radius", "in the water AND in the arena"
# are zone questions; a region cannot express any of them.
var _zones: Array = []
var _in_zones: Dictionary = {}       # zone name -> true while the player is inside it
var _amb_cur := ""
var _music_cur := ""
var _region_t := 0.0
var _shake := 0.0
var _toast_t := 0.0
var _boarded := false


# ---------------- small helpers ----------------

static func _col(v, fallback: Color) -> Color:
	# Colors arrive from JSON as [r,g,b] or [r,g,b,a] in 0..1.
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return fallback


func _d(key: String, fallback):
	var v = _cfg.get(key, null)
	return fallback if v == null else v


func _label(text: String, size: int, color: Color, center := true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", 2)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# ---------------- lifecycle ----------------

func setup(m) -> void:
	main = m
	var d = main.world_data.get("director", {})
	_cfg = d if d is Dictionary else {}
	var ms = _d("modes", [])
	_modes = ms if ms is Array else []

	_layer = CanvasLayer.new()
	_layer.layer = 150   # under the audio tap overlay (200), over the HUD (0)
	add_child(_layer)

	# Games without the engine's optional systems can hide those buttons by name.
	var hide = _d("hide_hud", [])
	if hide is Array:
		for b in hide:
			var key := String(b)
			if main._hud_btns.has(key):
				(main._hud_btns[key] as Button).visible = false

	_quest_lbl = _label("", 17, Color(1.0, 0.92, 0.6), false)
	_quest_lbl.visible = false
	main.hud_layer.add_child(_quest_lbl)

	_toast_lbl = _label("", 30, Color(1.0, 0.97, 0.88))
	_toast_lbl.modulate.a = 0.0
	main.hud_layer.add_child(_toast_lbl)

	_build_fx()

	_build_boss_bar()

	# RULES. preload, not load, so a parse error in rules.gd fails the EXPORT rather than the game
	# (the runtime-load trap this template has been bitten by before). Created only when the world
	# actually authors behavior, so a game with no rules pays nothing.
	if main.world_data.has("rules") or main.world_data.has("vars"):
		var _rs = preload("res://rules.gd")
		if _rs != null:
			rules = _rs.new()
			add_child(rules)
			rules.setup(main, self)

	if _modes.is_empty():
		mode = "_default"      # no title screen authored -> play immediately
	else:
		_build_title()
		# `--mode=ID` auto-picks, so a headless run can drive a specific mode. Validated against the
		# authored ids: an unknown id leaves the title up rather than silently starting nothing.
		var bm := String(main.boot_mode) if "boot_mode" in main else ""
		if bm != "":
			for m0 in _modes:
				if m0 is Dictionary and String((m0 as Dictionary).get("id", "")) == bm:
					_choose(bm)
					break
	main.quest.objective_changed.connect(_on_quest_changed)
	main.quest.completed.connect(_on_quest_completed)
	get_window().size_changed.connect(_relayout)
	_relayout()


func world_ready() -> void:
	_world_ready = true
	_read_regions()
	_warm_game_audio()
	_wire_peer_events()
	if mode != "":
		_apply_mode()


# PURE RE-READ — called after every applied world.json poll (a live chat edit). Must never re-run
# _apply_mode(): that restarts the chain, resets the stage index and re-boards the opening vehicle,
# which would throw a mid-game player back to the opening. Refresh cached data only.
func world_reloaded() -> void:
	var d = main.world_data.get("director", {})
	if d is Dictionary:
		_cfg = d
	_read_regions()
	if rules != null:
		rules.reload()   # refresh definitions, KEEP live values (see rules.gd::reload)


## ONE funnel for every rule event. Engine taps call this; it is null-safe so a world with no rules
## costs a single branch. Keeping it here (rather than letting taps reach into `rules` directly)
## means a game-authored director can also receive events by implementing `fire`.
func fire(event: String, payload: Dictionary = {}) -> void:
	if rules != null:
		rules.fire(event, payload)


# SAVES SETTLE AFTER THE SHELL IS BUILT. The shell is created the moment world.json lands, but the
# save layer cannot load until auth has resolved (the cloud backend needs a session), which happens
# later in _boot. So persisted vars are restored a SECOND time here, once the state is actually in
# hand. Caught by testing: a `persist` counter loaded fine, restored nothing because Save was still
# empty, and wrote back 1 on every launch forever — a save file that looked like it worked.
# Boot-time only: no rule has run and the player cannot act yet, so nothing is clobbered.
func save_loaded() -> void:
	if rules != null:
		rules.restore_persisted()


# Wired at world_ready, not setup: netsync is created later in _boot (peers need the hero model to
# clone), so connecting earlier would find nothing there.
func _wire_peer_events() -> void:
	if rules == null or main.netsync == null:
		return
	if not main.netsync.peer_joined.is_connected(_on_peer_joined):
		main.netsync.peer_joined.connect(_on_peer_joined)
	if not main.netsync.peer_left.is_connected(_on_peer_left):
		main.netsync.peer_left.connect(_on_peer_left)


func _on_peer_joined(id: String) -> void:
	fire("peer_join", {"who": id})
	rules.announce_synced()   # bring the late arrival up to date on shared state


func _on_peer_left(id: String) -> void:
	fire("peer_leave", {"who": id})


# Pull the game's OWN music/ambience — the beds that are NOT template defaults and therefore not in
# the .pck. Collected from everywhere the director can name a track, so a region change is a cache
# hit rather than a silent gap. Loose files next to world.json, exactly like models: that is what
# makes a game a self-contained DATA bundle a native player can download.
func _warm_game_audio() -> void:
	var names := {}
	var mus = _d("music", {})
	if mus is Dictionary:
		for k in (mus as Dictionary):
			names[String((mus as Dictionary)[k])] = true
	var autos = _d("ambient_auto", {})
	if autos is Dictionary:
		for k in (autos as Dictionary):
			var pick = (autos as Dictionary)[k]
			if pick is Dictionary:
				for t in (pick as Dictionary):
					names[String((pick as Dictionary)[t])] = true
	for r0 in _regions:
		if typeof(r0) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = r0
		names[String(r.get("music", ""))] = true
		names[String(r.get("ambient", ""))] = true
	# POSITIONAL sounds: a prop, structure or NPC can carry {"sound": "campfire"}, which the streamer
	# attaches as a distance-faded loop. Those names appear ONLY in world.json cells — never in the
	# director block — so collecting director tracks alone leaves every campfire, fountain and NPC
	# murmur silent once audio is served loose. One walk of the already-parsed world catches them all.
	_collect_sounds(main.world_data, names, 0)
	names.erase("")
	# A region's `ambient` may be an ambient_auto KEY ("auto_jungle") rather than a track name. Its
	# real tracks were already collected from the mapping above, so drop the key — warming it would
	# request a file that cannot exist and log a 404 on every boot.
	if autos is Dictionary:
		for k in (autos as Dictionary):
			names.erase(String(k))
	var base := String(main.world_url).replace("world.json", "")
	AudioManager.warm_remote(base, names.keys())


# Walk the parsed world for every "sound" value. Depth-bounded: cells nest a few levels
# (cell -> props -> spec), never deeply, and this runs once at world_ready.
func _collect_sounds(node, out: Dictionary, depth: int) -> void:
	if depth > 8:
		return
	if node is Dictionary:
		var d: Dictionary = node
		if d.has("sound"):
			out[String(d["sound"])] = true
		for k in d:
			var v = d[k]
			if v is Dictionary or v is Array:
				_collect_sounds(v, out, depth + 1)
	elif node is Array:
		for v in (node as Array):
			if v is Dictionary or v is Array:
				_collect_sounds(v, out, depth + 1)


func _read_regions() -> void:
	var regs = main.world_data.get("regions", [])
	_regions = regs if regs is Array else []
	var zs = main.world_data.get("zones", [])
	_zones = zs if zs is Array else []


## True while the player stands inside the named zone — the `in_zone` condition. Unknown names read
## false rather than true, so a typo fails the check instead of passing it.
func in_zone(name_: String) -> bool:
	return bool(_in_zones.get(name_, false))


## Independent enter/exit tracking, one flag per zone. Deliberately NOT the region model: regions
## report only the nearest because they drive a single ambience, while overlapping zones all apply.
func _update_zones() -> void:
	if _zones.is_empty() or main.player == null:
		return
	var p: Vector3 = main.player.global_position
	for z0 in _zones:
		if typeof(z0) != TYPE_DICTIONARY:
			continue
		var z: Dictionary = z0
		var nm := String(z.get("name", ""))
		if nm == "":
			continue
		var c = z.get("center", null)
		if not (c is Array) or (c as Array).size() < 3:
			continue
		var sz = z.get("size", [10, 10, 10])
		var hx := 5.0
		var hy := 5.0
		var hz := 5.0
		if sz is Array and (sz as Array).size() >= 3:
			hx = maxf(0.1, float(sz[0]) * 0.5)
			hy = maxf(0.1, float(sz[1]) * 0.5)
			hz = maxf(0.1, float(sz[2]) * 0.5)
		var inside := absf(p.x - float(c[0])) <= hx \
			and absf(p.y - float(c[1])) <= hy \
			and absf(p.z - float(c[2])) <= hz
		var was := bool(_in_zones.get(nm, false))
		if inside == was:
			continue
		_in_zones[nm] = inside
		fire("enter_zone" if inside else "exit_zone", {"id": nm})


func input_locked() -> bool:
	# A `panel`/`prompt` counts: it is a modal the player must answer, and leaving the world live
	# behind it means they get hit by something they cannot see while reading.
	return (_title_root != null and _title_root.visible) \
		or (_win_root != null and _win_root.visible) \
		or (_modal_root != null and is_instance_valid(_modal_root))


func toggle_stable_panel() -> void:
	pass   # games that want a stable ship their own director


## Does THIS world want a failure state? True when its own rules listen for `player_died` or use
## `lose`. Deliberately inferred from what the author WROTE rather than from a genre guess or a new
## flag: the engine never turns on death the author did not ask for, and an author who asks for it
## does so by writing the rule that handles it.
func wants_death() -> bool:
	if rules == null:
		return false
	return rules.references_death()


## Put the run back to its opening state WITHOUT rebuilding the scene.
##
## The first version reloaded the whole scene. That is the obvious move and it is also the fragile
## one: the reload is triggered from inside a Button's input dispatch, and on web the rebuilt page
## came back with the world drawn and the character unresponsive. Nothing about a retry actually
## requires new nodes — it requires the STATE to be at its start values. So reset the state.
## Dismiss a DEFEAT panel without resetting the run.
##
## `player_died` shows a full-screen modal that blocks input, because until now dying always meant
## the run was over. In a game where players kill EACH OTHER that is simply false — a death is an
## incident, not an ending — and a world whose rules answer `player_died` with `respawn` is stating
## exactly that. Leaving the modal up over a living, moving player is wrong in any world that
## respawns, so `respawn` clears it rather than PvP getting a special case.
##
## Victory is deliberately NOT cleared: winning ends a run, and nothing about respawning un-wins it.
func clear_defeat() -> void:
	if not _lost:
		return
	_lost = false
	if _win_root != null and is_instance_valid(_win_root):
		_win_root.queue_free()
	_win_root = null


func reset_run() -> void:
	if _win_root != null and is_instance_valid(_win_root):
		_win_root.queue_free()
	_win_root = null
	_won = false
	_lost = false
	_cur_region = ""
	_in_zones.clear()   # else re-entering a zone after a retry raises nothing — same trap regions had
	# Screen FX are run state too. A retry that starts behind the fade-to-black the death rule put
	# up, or under the poison wash that killed you, is not a retry — and the rule that would have
	# lifted them has already fired `once`.
	_close_modal()
	fx_fade(0.0, 0.0, Color(0, 0, 0))
	fx_tint(Color(0, 0, 0, 0), 0.0)
	subtitle("", 0.0)
	if rules != null:
		rules.reset_run()
	var m2 = _d("music", {})
	if m2 is Dictionary:
		_start_music(String((m2 as Dictionary).get("default", "")))
	fire("start", {"id": mode})     # re-run the opening rules (respawns a boss, re-arms timers)


## Play a one-shot emote on the local hero and tell the room about it. Called by the `emote`
## rule action. The clip name is any clip on the rig OR a semantic key hero_anim.resolve()
## understands, so a thin rig degrades instead of freezing.
func play_emote(clip: String, hold := 1.2) -> void:
	if main == null:
		return
	if main.has_method("play_emote_local"):
		main.play_emote_local(clip, hold)
	if main.netsync != null and main.netsync.has_method("send_emote"):
		main.netsync.send_emote(clip, hold)


func _shake_cam(t: float) -> void:
	_shake = maxf(_shake, t)


# ---------------- title screen ----------------

func _build_title() -> void:
	var t = _d("title", {})
	var tc: Dictionary = t if t is Dictionary else {}
	_title_root = Control.new()
	_title_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_title_root)

	var bg := ColorRect.new()
	bg.color = _col(tc.get("bg", null), Color(0.03, 0.05, 0.06, 0.94))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)

	var kicker := String(tc.get("kicker", ""))
	if kicker != "":
		box.add_child(_label(kicker, 18, Color(0.75, 0.72, 0.6)))
	box.add_child(_label(String(tc.get("name", "")), 84, _col(tc.get("color", null), Color(0.98, 0.88, 0.55))))
	var tag := String(tc.get("tagline", ""))
	if tag != "":
		box.add_child(_label(tag, 20, Color(0.8, 0.82, 0.78)))

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 26)
	box.add_child(spacer)

	for m0 in _modes:
		if typeof(m0) != TYPE_DICTIONARY:
			continue
		var m: Dictionary = m0
		var id := String(m.get("id", ""))
		box.add_child(_mode_button(String(m.get("label", id.to_upper())), String(m.get("caption", "")),
			func() -> void: _choose(id)))

	var hint := String(tc.get("hint", ""))
	if hint != "":
		box.add_child(_label(hint, 15, Color(0.55, 0.58, 0.55)))


func _mode_button(txt: String, caption: String, cb: Callable) -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(360, 84)
	b.add_theme_font_size_override("font_size", 38)
	b.pressed.connect(cb)
	wrap.add_child(b)
	if caption != "":
		wrap.add_child(_label(caption, 14, Color(0.6, 0.63, 0.6)))
	return wrap


func _choose(id: String) -> void:
	mode = id
	AudioManager.play_sfx("ui")
	if _title_root != null:
		_title_root.visible = false
	if _world_ready:
		_apply_mode()


# ---------------- mode application ----------------

func _apply_mode() -> void:
	_mode_cfg = {}
	for m0 in _modes:
		if typeof(m0) == TYPE_DICTIONARY and String((m0 as Dictionary).get("id", "")) == mode:
			_mode_cfg = m0
			break

	# opening weather (a cinematic sky the world's own cycle resumes from later)
	var opening = _mode_cfg.get("opening", null)
	if opening is Dictionary and main.weather != null:
		main.weather.apply(opening)

	# items granted up front (free-roam modes that open every story gate)
	var grants = _mode_cfg.get("grant_items", [])
	if grants is Array:
		for it in grants:
			main.rpg.add_item(String(it))

	# MAP: this mode plays in a different AREA of the world — a pre-match map chooser, where the
	# title screen's mode buttons are the maps. Zone mode only; a chunk world is one continuous
	# space with no areas to pick between, so `map` is meaningless there and is ignored rather than
	# half-applied. `spawn` changes meaning when `map` is set: it names one of THAT AREA's spawns
	# (goto_area's own argument) instead of a top-level [x, z] key, which is why the block below is
	# skipped — running both would teleport the player out of the area they just loaded into.
	var spawn := String(_mode_cfg.get("spawn", ""))
	var map_id := String(_mode_cfg.get("map", ""))
	if map_id != "" and main.scene_manager != null and not main.chunk_mode:
		await main.scene_manager.goto_area(map_id, spawn)
	# MULTIPLAYER JOINS HERE, NOT AT BOOT, when the world offers a map choice: the chosen map is
	# part of the room, so picking a map is picking who you play against. main held the connection
	# open for exactly this moment (see main._setup_multiplayer). Called unconditionally — with an
	# empty map_id for modes that don't pick one — because a world where SOME modes name a map
	# still has to connect for the ones that don't.
	if main.has_method("begin_multiplayer"):
		main.begin_multiplayer(map_id)
	# spawn at a named point in world.json (e.g. "camp_pos": [x, z]) — only when this mode did NOT
	# pick a map; everything after it (chain, toast, board_vehicle) still applies to map modes.
	if map_id == "" and spawn != "":
		var pos = main.world_data.get(spawn, null)
		if pos is Array and (pos as Array).size() >= 2 and main.player != null:
			var px := float(pos[0])
			var pz := float(pos[1])
			var py: float = main.chunk_manager._ground_y(px, pz) if main.chunk_manager != null else 0.0
			main.player.global_position = Vector3(px, py + 0.3, pz)

	# the quest chain, if this mode has one
	var ch = _mode_cfg.get("chain", [])
	_chain = ch if ch is Array else []
	if not _chain.is_empty():
		_quest_lbl.visible = true
		_story_idx = 0
		var first := _stage(0)
		main.quest.start(String(first.get("id", "")))
		_refresh_quest_lbl()
		_toast(String(first.get("toast", "")), 5.0)

	var open_toast := String(_mode_cfg.get("toast", ""))
	if open_toast != "":
		_toast(open_toast, 5.0)

	_board_vehicle()
	var mus = _d("music", {})
	if mus is Dictionary:
		_start_music(String((mus as Dictionary).get("default", "")))

	# START fires LAST, once the mode's grants/spawn/chain/vehicle are all applied — so a rule that
	# reacts to it sees the world the player will actually see, not a half-built one.
	fire("start", {"id": mode})


func _stage(i: int) -> Dictionary:
	if i < 0 or i >= _chain.size() or typeof(_chain[i]) != TYPE_DICTIONARY:
		return {}
	return _chain[i]


# Board a named vehicle at start (a story that opens aboard a ship/plane). Vehicles may spawn a beat
# after world_ready, so _process retries until it lands.
func _board_vehicle() -> void:
	var want := String(_mode_cfg.get("board_vehicle", ""))
	if want == "" or _boarded:
		return
	for v in main.vehicles:
		if is_instance_valid(v) and String(v.get_meta("spec", {}).get("name", "")) == want:
			_boarded = true
			v.enter(main.player)
			return


# ---------------- story chain ----------------

func _on_quest_changed() -> void:
	_refresh_quest_lbl()
	if _chain.is_empty() or _story_idx < 0 or _story_idx >= _chain.size():
		return
	var cur := _stage(_story_idx)
	var cur_id := String(cur.get("id", ""))
	if cur_id == "" or not main.quest.st.has(cur_id):
		return
	if String(main.quest.st[cur_id].status) != "done":
		return
	# `quest_done` is fired from _on_quest_completed now — every quest, not just chain stages.
	AudioManager.play_sfx("pickup", -2.0, 1.15)
	# per-stage side effects, declared in data
	var on_done = cur.get("on_done", {})
	if on_done is Dictionary and bool((on_done as Dictionary).get("restore_weather", false)):
		main._apply_weather(main.world_data)   # hand the sky back to the world's living cycle
	advance_chain()


## `advance_chain` — step the story to the next stage WITHOUT its quest having been completed.
## For the beat the objective cannot describe: the player took a shortcut, the scene moved on, the
## boss died before the fetch quest was handed in. Shared with the normal completion path so a
## skipped stage and a finished one leave the chain in exactly the same shape.
func advance_chain() -> bool:
	if _chain.is_empty() or _story_idx < 0 or _story_idx >= _chain.size():
		return false
	_story_idx += 1
	if _story_idx < _chain.size():
		var nxt := _stage(_story_idx)
		main.quest.start(String(nxt.get("id", "")))
		_toast(String(nxt.get("toast", "")), 5.0)
		_refresh_quest_lbl()
	print("GOGI_CHAIN advanced to %d/%d" % [_story_idx, _chain.size()])
	return true


func _on_quest_completed(id: String) -> void:
	fire("quest_done", {"id": id})


func _refresh_quest_lbl() -> void:
	if _quest_lbl == null or _chain.is_empty():
		return
	var txt: String = main.quest.current_objective()
	_quest_lbl.text = txt.replace(" / ", "\n") if txt != "" else ""


# ---------------- boss + victory ----------------

func on_kill(type: String) -> void:
	fire("kill", {"kind": type, "who": "player"})
	var boss = _d("boss", {})
	if not (boss is Dictionary):
		return
	if type == String((boss as Dictionary).get("kind", "")) and not _won:
		_won = true
		_show_victory()


func _show_victory() -> void:
	_show_end_panel("victory", "VICTORY", Color(1.0, 0.85, 0.45), "KEEP EXPLORING")


## DEFEAT. The counterpart that did not exist: `win` put up a full panel while `lose` had nowhere to
## go, so implementing the action meant building the screen too. Rather than a second copy, the
## victory panel became data-driven — same construction, different block, title and accent.
func _show_defeat() -> void:
	if _lost or _won:
		return
	_lost = true
	_show_end_panel("defeat", "DEFEATED", Color(0.95, 0.45, 0.42), "TRY AGAIN")


func _show_end_panel(key: String, def_title: String, accent: Color, def_button: String) -> void:
	var vic = _d(key, {})
	var vc: Dictionary = vic if vic is Dictionary else {}
	var mus = _d("music", {})
	if mus is Dictionary:
		var vt := String((mus as Dictionary).get(key, ""))
		if vt != "":
			_start_music(vt)

	_win_root = Control.new()
	_win_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_win_root)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.04, 0.85)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_root.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	box.add_child(_label(String(vc.get("title", def_title)), 64, accent))
	# per-mode closing line, falling back to a shared one
	var texts = vc.get("text", {})
	var line := ""
	if texts is Dictionary:
		var td: Dictionary = texts
		line = String(td.get(mode, td.get("default", "")))
	elif texts is String:
		line = String(texts)
	if line != "":
		box.add_child(_label(line, 20, Color(0.85, 0.87, 0.82)))

	var b := Button.new()
	b.text = String(vc.get("button", def_button))
	b.custom_minimum_size = Vector2(320, 72)
	b.add_theme_font_size_override("font_size", 30)
	var restarts := (key == "defeat")
	b.pressed.connect(func() -> void:
		if restarts:
			main.restart_run()      # in-place reset — see main.restart_run
			return
		_win_root.visible = false
		var m2 = _d("music", {})
		if m2 is Dictionary:
			_start_music(String((m2 as Dictionary).get("default", ""))))
	box.add_child(b)


# ---------------- phase 8: modals (`panel`, `prompt`) ----------------
#
# Both reuse the end-panel construction, but they are NOT end panels: they dismiss and the run
# carries on. Only one can be open at a time — a second `panel` replaces the first rather than
# stacking, because a stack of modals on a phone is a trap the player cannot back out of.


func _close_modal() -> void:
	if _modal_root != null and is_instance_valid(_modal_root):
		_modal_root.queue_free()
	_modal_root = null


## Shared chrome: dim, centred column, title, body. Returns the column so the caller adds controls.
func _modal_box(cfg: Dictionary, accent: Color) -> VBoxContainer:
	_close_modal()
	_modal_root = Control.new()
	_modal_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_modal_root)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.04, 0.78)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_root.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var title := String(cfg.get("title", ""))
	if title != "":
		box.add_child(_label(title, 44, accent))
	var body := String(cfg.get("text", ""))
	if body != "":
		var l := _label(body, 22, Color(0.87, 0.89, 0.85))
		l.custom_minimum_size = Vector2(minf(760.0, main.get_viewport().get_visible_rect().size.x * 0.8), 0)
		box.add_child(l)
	return box


func _modal_button(box: VBoxContainer, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 68)
	b.add_theme_font_size_override("font_size", 28)
	b.pressed.connect(cb)
	box.add_child(b)


## `panel` — a dismissible info screen (a letter, a map legend, a lore drop).
func show_panel(cfg: Dictionary) -> void:
	var box := _modal_box(cfg, _col(cfg.get("color", null), Color(0.95, 0.9, 0.7)))
	_modal_button(box, String(cfg.get("button", "CLOSE")), func() -> void: _close_modal())
	print("GOGI_MODAL panel buttons=1")


## `prompt` — a question. Each choice's `id` comes back as the `dialogue_choice` event, which is the
## only reason this action is worth having: a prompt whose answer nothing can observe is decoration.
##
## A prompt with no readable choices still gets a dismiss button. The alternative is a modal with no
## way out — an unrecoverable soft-lock produced by a typo in a data file.
func show_prompt(cfg: Dictionary) -> void:
	var box := _modal_box(cfg, _col(cfg.get("color", null), Color(0.72, 0.86, 1.0)))
	var pid := String(cfg.get("id", ""))
	var made := 0
	var ch = cfg.get("choices", [])
	if ch is Array:
		for c0 in (ch as Array):
			var cid := ""
			var clabel := ""
			if c0 is Dictionary:
				cid = String((c0 as Dictionary).get("id", ""))
				clabel = String((c0 as Dictionary).get("label", cid.capitalize()))
			else:
				cid = String(c0)
				clabel = cid.capitalize()
			if cid == "":
				continue
			made += 1
			_modal_button(box, clabel, func() -> void:
				_close_modal()
				fire("dialogue_choice", {"id": cid, "prompt": pid}))
	if made == 0:
		_modal_button(box, String(cfg.get("button", "CLOSE")), func() -> void: _close_modal())
	print("GOGI_MODAL prompt id=%s choices=%d" % [pid, made])


func _build_boss_bar() -> void:
	var boss = _d("boss", {})
	var bc: Dictionary = boss if boss is Dictionary else {}
	_boss_root = Control.new()
	_boss_root.visible = false
	_boss_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.hud_layer.add_child(_boss_root)
	_boss_name = _label(String(bc.get("name", "")), 24, Color(1.0, 0.45, 0.3))
	_boss_root.add_child(_boss_name)
	var bbg := ColorRect.new()
	bbg.name = "bbg"
	bbg.color = Color(0, 0, 0, 0.55)
	_boss_root.add_child(bbg)
	_boss_fill = ColorRect.new()
	_boss_fill.color = _col(bc.get("color", null), Color(0.9, 0.2, 0.12))
	_boss_root.add_child(_boss_fill)


func _update_boss_bar() -> void:
	var boss = _d("boss", {})
	if not (boss is Dictionary) or _boss_root == null:
		return
	var kind := String((boss as Dictionary).get("kind", ""))
	if kind == "":
		return
	var streamer = main.chunk_manager if main.chunk_mode else main.scene_manager
	if streamer == null:
		return
	var live = null
	for e in streamer.enemies:
		if is_instance_valid(e) and String(e.get("kind")) == kind and not bool(e.get("dead")):
			live = e
			break
	if live == null:
		_boss_root.visible = false
		return
	# explicit type: `main` is untyped, so anything reached through it is a Variant and `:=`
	# cannot infer (the hard parse error this template's playbooks warn about).
	var d: float = main.player.global_position.distance_to(live.global_position)
	_boss_root.visible = d < float((boss as Dictionary).get("show_within", 70.0))
	if _boss_root.visible and _boss_fill != null:
		var hp := float(live.get("hp"))
		var mx := maxf(1.0, float(live.get("max_hp")))
		var w: float = float(_boss_root.get_meta("bar_w", 400.0))
		_boss_fill.size = Vector2(w * clampf(hp / mx, 0.0, 1.0), 16)


# ---------------- layout / toast / tick ----------------

func _relayout() -> void:
	if main == null:
		return
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	if _quest_lbl != null:
		_quest_lbl.position = Vector2(12, 140)
		_quest_lbl.size = Vector2(minf(430.0, vp.x * 0.55), 200)
	if _toast_lbl != null:
		_toast_lbl.position = Vector2(vp.x * 0.1, vp.y * 0.16)
		_toast_lbl.size = Vector2(vp.x * 0.8, 120)
	if _sub_lbl != null:
		# Bottom third, clear of the thumb grid on the right and the joystick on the left.
		_sub_lbl.size = Vector2(vp.x * 0.56, 110)
		_sub_lbl.position = Vector2(vp.x * 0.22, vp.y * 0.72)
	if _boss_root != null:
		var w := minf(520.0, vp.x * 0.7)
		_boss_root.position = Vector2((vp.x - w) * 0.5, 44)
		if _boss_name != null:
			_boss_name.position = Vector2(0, -32)
			_boss_name.size = Vector2(w, 30)
		var bbg := _boss_root.get_node_or_null("bbg") as ColorRect
		if bbg != null:
			bbg.size = Vector2(w, 16)
		if _boss_fill != null:
			_boss_fill.size = Vector2(w, 16)
		_boss_root.set_meta("bar_w", w)


# ---------------- phase 8: screen FX (`fade`, `tint`, `subtitle`) ----------------
#
# Built once, always present, fully transparent until a rule asks for something. Three rects/labels
# cost nothing idle and mean the actions never have to construct UI on the frame they fire — which
# is what made the first `toast` implementation stutter on a phone.

func _build_fx() -> void:
	_fx_layer = CanvasLayer.new()
	_fx_layer.layer = 140
	add_child(_fx_layer)

	_tint_rect = ColorRect.new()
	_tint_rect.color = Color(0, 0, 0, 0)
	_tint_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tint_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_layer.add_child(_tint_rect)

	# Fade sits ABOVE tint: a scene fading to black should hide the poison wash, not blend with it.
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_layer.add_child(_fade_rect)

	# Subtitle lives on the HUD layer, not the FX layer — narration under a fade-to-black is a
	# standard cinematic beat and the caption has to survive the fade to be worth having.
	_sub_lbl = _label("", 26, Color(0.96, 0.95, 0.9))
	_sub_lbl.modulate.a = 0.0
	main.hud_layer.add_child(_sub_lbl)


## `fade`. Deliberately does NOT lock input — `freeze` is the action for that, and a game that wants
## a cutscene writes both. Folding the lock in here would make every atmospheric dip steal control.
func fx_fade(to: float, time: float, c: Color) -> void:
	if _fade_rect == null:
		return
	var col := Color(c.r, c.g, c.b, _fade_rect.color.a)
	_fade_rect.color = col
	if time <= 0.0:
		_fade_rect.color = Color(c.r, c.g, c.b, clampf(to, 0.0, 1.0))
		return
	var t := create_tween()
	t.tween_property(_fade_rect, "color:a", clampf(to, 0.0, 1.0), time)
	print("GOGI_FX fade to=%.2f time=%.2f" % [clampf(to, 0.0, 1.0), time])


## `tint`. A persistent wash (poison, rage, night-vision) — unlike fade it keeps its colour, and
## alpha 0 is how a rule takes it off again.
func fx_tint(c: Color, time: float) -> void:
	if _tint_rect == null:
		return
	if time <= 0.0:
		_tint_rect.color = c
		return
	var t := create_tween()
	t.tween_property(_tint_rect, "color", c, time)
	print("GOGI_FX tint rgba=%.2f,%.2f,%.2f,%.2f time=%.2f" % [c.r, c.g, c.b, c.a, time])


## `subtitle`. Bottom-third narration, distinct from a toast: a toast is a notification at eye level
## that fades in seconds; a subtitle is a line of script that holds long enough to read. An empty
## string clears it immediately.
func subtitle(text: String, hold: float) -> void:
	if _sub_lbl == null:
		return
	if text == "":
		_sub_lbl.modulate.a = 0.0
		_sub_t = 0.0
		return
	_sub_lbl.text = text
	_sub_lbl.modulate.a = 1.0
	_sub_t = maxf(0.5, hold)
	print("GOGI_FX subtitle hold=%.1f len=%d" % [_sub_t, text.length()])


func _toast(msg: String, hold := 3.0) -> void:
	if _toast_lbl == null or msg == "":
		return
	_toast_lbl.text = msg
	_toast_lbl.modulate.a = 1.0
	_toast_t = hold


func _process(delta: float) -> void:
	if main == null:
		return
	# toast fade
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast_t = 0.0
	elif _toast_lbl != null and _toast_lbl.modulate.a > 0.0:
		_toast_lbl.modulate.a = maxf(0.0, _toast_lbl.modulate.a - delta * 1.6)
	# subtitle fade — same shape as the toast, slower tail so a line of script does not blink out
	if _sub_t > 0.0:
		_sub_t = maxf(0.0, _sub_t - delta)
	elif _sub_lbl != null and _sub_lbl.modulate.a > 0.0:
		_sub_lbl.modulate.a = maxf(0.0, _sub_lbl.modulate.a - delta * 1.1)
	# camera shake (decaying random offset)
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 2.2)
		var a := _shake * 0.35
		main.cam.h_offset = randf_range(-a, a)
		main.cam.v_offset = randf_range(-a, a)
	elif main.cam != null and (main.cam.h_offset != 0.0 or main.cam.v_offset != 0.0):
		main.cam.h_offset = 0.0
		main.cam.v_offset = 0.0

	if not _world_ready or mode == "":
		return
	_region_t += delta
	if _region_t >= 0.6:
		_region_t = 0.0
		_update_region()
		_update_zones()
		_update_boss_bar()
		# TIME OF DAY. Polled on the existing 0.6 s tick rather than given its own timer — the
		# state changes a handful of times per in-game day, so an edge-detect here is free and a
		# dedicated signal would be machinery for nothing.
		if main.weather != null:
			var t := String(main.weather.time_state)
			if t != _tod:
				var was := _tod
				_tod = t
				if was != "":                     # skip the boot transition ("" -> "day")
					fire("time_of_day_changed", {"id": t})
			# WEATHER, on the same tick and for the same reason. A cycle changes it a handful of
			# times a session, so an edge-detect here is free where a signal would be machinery.
			# `_active_wx` is the weather whose particles/audio are actually live — the same field
			# the `weather` condition reads, so an event and a check can never disagree.
			var wx := String(main.weather._active_wx)
			if wx != _wx:
				var was_wx := _wx
				_wx = wx
				if was_wx != "":                  # skip the boot transition ("" -> "clear")
					fire("weather_changed", {"id": wx, "from": was_wx})
	if not _boarded:
		_board_vehicle()   # vehicles can spawn a beat after world_ready


# ---------------- regions: name toast + ambience + music ----------------

## The authored record for a region by name, or {} — one lookup, so the containment test and the
## enter/exit tracker can never disagree about a region's centre or radius.
func region_rec(name_: String) -> Dictionary:
	for r0 in _regions:
		if typeof(r0) == TYPE_DICTIONARY and String((r0 as Dictionary).get("name", "")) == name_:
			return r0
	return {}


## How many PLAYERS stand in a named region — the local one plus every synced peer.
##
## This is the one place the documented "`who: enemy` never matches" gap does NOT apply: the
## condition asks about players, and peers are players. Returns 0 for an unknown region rather than
## counting everyone, so a typo'd name fails the check instead of passing it.
func players_in_region(name_: String) -> int:
	var r := region_rec(name_)
	if r.is_empty():
		return 0
	var c = r.get("center", [0, 0])
	if not (c is Array) or (c as Array).size() < 2:
		return 0
	var ctr := Vector2(float(c[0]), float(c[1]))
	var rad := float(r.get("radius", 40.0))
	var n := 0
	if main.player != null:
		var pp: Vector3 = main.player.global_position
		if Vector2(pp.x - ctr.x, pp.z - ctr.y).length() < rad:
			n += 1
	if main.netsync != null and main.netsync.has_method("peer_positions"):
		for p in main.netsync.peer_positions():
			if Vector2((p as Vector3).x - ctr.x, (p as Vector3).z - ctr.y).length() < rad:
				n += 1
	return n


func _update_region() -> void:
	if _regions.is_empty() or main.player == null:
		return
	var p: Vector3 = main.player.global_position
	var best := ""
	var best_d := 1e12
	var best_rec: Dictionary = {}
	for r0 in _regions:
		if typeof(r0) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = r0
		var c = r.get("center", [0, 0])
		if not (c is Array) or (c as Array).size() < 2:
			continue
		var d := Vector2(p.x - float(c[0]), p.z - float(c[1])).length()
		if d < float(r.get("radius", 40.0)) and d < best_d:
			best_d = d
			best = String(r.get("name", ""))
			best_rec = r
	if best == _cur_region:
		return                              # still in the same region (or still in none) — nothing happened

	# LEAVING IS AN EVENT, AND CLEARING THE TRACKER IS WHAT MAKES RE-ENTRY WORK.
	# This used to `return` early whenever `best` was empty, so walking out of a region into open
	# ground left `_cur_region` holding the name of the region just left. Two things broke, both
	# silently: coming BACK to that same region raised nothing (the equality check above swallowed
	# it, so a single-region lap circuit fired exactly once ever), and `{"in_region": X}` — which
	# reads this same field — meant "X was the last region entered" and stayed true forever, even
	# from the far side of the map. Measured before the fix: a probe that crossed one region, left
	# it, and crossed it again saw exactly one enter_region.
	if _cur_region != "":
		fire("exit_region", {"id": _cur_region, "who": "player"})
	_cur_region = best
	if best == "":
		return                              # left every region — no enter, and no ambient/music swap

	# `who: player` because _update_region tracks the PLAYER's position. Enemy-side region events
	# (what a tower-defense base needs) are a separate tap, not this one.
	fire("enter_region", {"id": best, "who": "player"})
	_toast(best, 2.2)

	# AMBIENT. A region may name a bed directly, or use an "auto" key the director maps by time of
	# day — authored as {"auto_jungle": {"day": "forest_birds", "night": "night_crickets"}}.
	var amb := String(best_rec.get("ambient", ""))
	var autos = _d("ambient_auto", {})
	if autos is Dictionary and (autos as Dictionary).has(amb):
		var pick = (autos as Dictionary)[amb]
		if pick is Dictionary:
			var night := String(main.weather.time_state) == "night"
			amb = String((pick as Dictionary).get("night" if night else "day", ""))
	if amb != "" and amb != _amb_cur:
		var st := AudioManager.stream_for("res://audio/" + amb + ".ogg")
		if st != null:
			_amb_cur = amb
			AudioManager.play_ambient(st)

	# MUSIC. A region with no track falls back to the default once the boss track has been left.
	var mus := String(best_rec.get("music", ""))
	var mcfg = _d("music", {})
	var default_track := String((mcfg as Dictionary).get("default", "")) if mcfg is Dictionary else ""
	if mus != "" and not _won:
		_start_music(mus)
	elif mus == "" and not _won and _music_cur != default_track:
		_start_music(default_track)


func _start_music(name_: String) -> void:
	if name_ == "" or _music_cur == name_:
		return
	var st := AudioManager.stream_for("res://audio/" + name_ + ".ogg")
	if st != null:
		_music_cur = name_
		AudioManager.play_music(st)
