extends Node
## RULES — the data-driven behavior layer. `when` an event happens, `if` a condition holds, `then`
## run actions. Three closed vocabularies (events / conditions / actions) and nothing else.
##
## WHY THIS EXISTS
## The engine ships INSIDE the iOS app; a game is DATA streamed into it. So the moment a game needs
## behavior the schema cannot express, the agent's only outs were to write a game-authored script
## (a hard data-only FAIL) or to declare `web_only` and drop the whole game to the browser tier —
## for ONE missing detail. A race with no stopwatch is the canonical case: the director block has no
## timer, and a reach_area goal deliberately does not auto-show a win screen, so a three-line feature
## cost the user the native tier. This layer is the third option: compose the feature from primitives
## the engine already implements.
##
## THE LINE THIS MUST NEVER CROSS — and it is a legal line, not a taste one.
## Rules CONFIGURE behavior the engine already has. They never DEFINE new behavior. Recombining
## shipped capabilities is a config file; a general-purpose language shipped as JSON is a program,
## and downloading a program at runtime is what App Store guideline 2.5.2 forbids. That is why there
## are no loops, no functions, no recursion and no arithmetic beyond set/add/clamp/random here, and
## why the caps in verify are enforced in code rather than advised in a doc. Every future addition
## gets one question: does the engine already do this, and is the game only choosing WHEN?
##
## A TIMER IS NOT A CONCEPT. It is a var with a signed `tick` rate. The sign is what makes a
## countdown, a cooldown, a hunger bar and a stopwatch the same feature instead of four.
##
## Hosted by game_shell.gd (which already owns toasts, the quest hook and the tick). Never an
## autoload: rules belong to a world, and a world swap must take them with it.

var main = null
var shell = null

var _vars: Dictionary = {}          # name -> current value
var _spec: Dictionary = {}          # name -> the authored var spec (init/tick/min/max/scope/...)
var _ticking: Array = []            # names with a non-zero tick, cached so _process isn't a scan
var _rules: Array = []              # parsed rule records
var _by_event: Dictionary = {}      # event name -> [rule index] — dispatch index, not a linear scan
var _fired: Dictionary = {}         # rule id -> true, for `once`
var _logged: Dictionary = {}        # rule id -> true, so the fire-trace prints once per rule
var _hud: Array = []                # declared HUD readouts/bars/buttons bound to vars
var _disabled: Dictionary = {}      # rule id -> true, toggled by enable_rule/disable_rule

# CASCADE BUDGET. An action that writes a var raises `var_changed`, whose rules may write another
# var. That is legitimate and useful (score -> threshold -> win), and it is also an infinite loop
# one typo away. A hard per-frame budget makes the runaway case DEGRADE LOUDLY instead of hanging
# the game on a phone, which is the only failure here a player would experience as a crash.
const CASCADE_MAX := 64
var _cascade := 0
var _cascade_warned := false

# Every unimplemented action reports ONCE by name. This is deliberate telemetry, not a TODO marker:
# it is how we learn which primitives games actually reach for, from real builds rather than guesses.
var _unimpl_seen: Dictionary = {}


# ---------------- lifecycle ----------------

func setup(m, sh) -> void:
	main = m
	shell = sh
	_load(main.world_data)
	restore_persisted()
	_wire_sync()
	_build_hud()


# PERSISTED VARS. Restored AFTER _load has seeded every var with its `init`, so a saved value
# overwrites the default rather than the other way round — and only for vars the world still
# declares as `persist`, so dropping the flag in a chat edit cleanly forgets the old value instead
# of resurrecting it forever.
func restore_persisted() -> void:
	if Save == null or not Save.loaded:
		return
	for name_ in _spec:
		if not bool((_spec[name_] as Dictionary).get("persist", false)):
			continue
		var k := "var." + String(name_)
		if Save.has(k):
			_vars[name_] = Save.get_value(k)


# HOT-RELOAD. A chat edit rewrites world.json under a RUNNING game. Refresh the definitions but keep
# live values — the exact trap quest.gd documents for quests: re-running setup would reset every
# counter and throw a mid-game player back to the start, which is a worse bug than the stale rules
# it fixes. New vars get their init; removed vars are dropped; surviving vars keep what they hold.
func reload() -> void:
	var keep := _vars.duplicate()
	_load(main.world_data)
	for k in keep:
		if _vars.has(k):
			_vars[k] = keep[k]


func _load(world: Dictionary) -> void:
	_vars.clear(); _spec.clear(); _ticking.clear()
	_rules.clear(); _by_event.clear()

	var vd = world.get("vars", {})
	if vd is Dictionary:
		for name_ in (vd as Dictionary):
			var s = (vd as Dictionary)[name_]
			var sp: Dictionary = s if s is Dictionary else {}
			_spec[name_] = sp
			_vars[name_] = sp.get("init", 0)
			if absf(float(sp.get("tick", 0.0))) > 0.0001:
				_ticking.append(name_)

	var rl = world.get("rules", [])
	if rl is Array:
		for r0 in (rl as Array):
			if typeof(r0) != TYPE_DICTIONARY:
				continue
			var r: Dictionary = r0
			var when = r.get("when", {})
			if not (when is Dictionary):
				continue
			var ev := String((when as Dictionary).get("event", ""))
			if ev == "":
				continue
			var idx := _rules.size()
			_rules.append(r)
			if not _by_event.has(ev):
				_by_event[ev] = []
			(_by_event[ev] as Array).append(idx)
			if bool(r.get("enabled", true)) == false:
				_disabled[String(r.get("id", str(idx)))] = true

	if not _rules.is_empty():
		print("GOGI_RULES loaded vars=%d rules=%d events=%d" % [_vars.size(), _rules.size(), _by_event.size()])


## Does this world ASK for a failure state? True when a rule listens for `player_died` or runs
## `lose`. This is the whole death switch: no `genre` field to guess from, no new authoring key —
## just "did the author write the thing that handles dying". A world that says nothing keeps the
## engine's forgiving respawn untouched.
func references_death() -> bool:
	if _by_event.has("player_died"):
		return true
	for r in _rules:
		for a0 in (r as Dictionary).get("then", []):
			if a0 is Dictionary and (a0 as Dictionary).has("lose"):
				return true
	return false


## Downward hp fractions any rule cares about, for `kind`. enemy.gd caches these at spawn so a hit
## can detect a CROSSING without the enemy knowing anything about rules. Default 0.5 — the playbook's
## two-phase boss reads "half health", and `at` overrides it for three-phase fights.
func hp_marks_for(kind: String) -> Array:
	var out: Array = []
	for idx in (_by_event.get("enemy_hp_crossed", []) as Array):
		var r: Dictionary = _rules[idx]
		var w = r.get("when", {})
		if not (w is Dictionary):
			continue
		var t := String((w as Dictionary).get("target", ""))
		if t != "" and t != kind:
			continue
		var f := float((w as Dictionary).get("at", 0.5))
		if f > 0.0 and f < 1.0 and not (f in out):
			out.append(f)
	return out


## Reset every var to its `init`, forget `once` history, and restore the authored enabled/disabled
## state. Used by a restart. Persisted vars are re-restored afterwards so a saved best-lap survives a
## retry while the run's own counters do not.
func reset_run() -> void:
	for name_ in _spec:
		_vars[name_] = (_spec[name_] as Dictionary).get("init", 0)
	_fired.clear()
	_logged.clear()
	_disabled.clear()
	for i in _rules.size():
		var r: Dictionary = _rules[i]
		if bool(r.get("enabled", true)) == false:
			_disabled[String(r.get("id", str(i)))] = true
	_cascade = 0
	_cascade_warned = false
	restore_persisted()
	if not _hud.is_empty():
		_refresh_hud()


# ---------------- the entry point ----------------

## Fire an event. `payload` carries whatever the event knows: {"id":…, "kind":…, "who":…}.
## Every engine tap funnels through here, so there is exactly one place rules can be triggered.
func fire(event: String, payload: Dictionary = {}) -> void:
	if _rules.is_empty() or not _by_event.has(event):
		return
	_cascade += 1
	if _cascade > CASCADE_MAX:
		if not _cascade_warned:
			_cascade_warned = true
			push_warning("GOGI_RULES cascade budget (%d) exceeded on '%s' — a rule chain is feeding itself. Later rules this frame are DROPPED." % [CASCADE_MAX, event])
			print("GOGI_RULES_CASCADE event=%s budget=%d" % [event, CASCADE_MAX])
		return
	for idx in (_by_event[event] as Array):
		var r: Dictionary = _rules[idx]
		var rid := String(r.get("id", str(idx)))
		if _disabled.has(rid):
			continue
		if bool(r.get("once", false)) and _fired.has(rid):
			continue
		if not _when_matches(r.get("when", {}), payload):
			continue
		if not _eval(r.get("if", null), payload):
			continue
		if bool(r.get("once", false)):
			_fired[rid] = true
		# FIRST FIRE ONLY, per rule id. Verify's runtime pass reads these to prove authored rules
		# actually RUN — "declared but dead" is the failure mode to expect, and it is invisible
		# otherwise. Once-per-id rather than per-fire because a ticking var changes every frame and
		# an unconditional trace would bury the log it is meant to make readable.
		if not _logged.has(rid):
			_logged[rid] = true
			print("GOGI_RULE_FIRED ", rid, " on=", event)
		_run(r.get("then", []), payload)


# The `when` clause may narrow beyond the event name: a target (which region, which enemy kind) and
# a `who` filter. `who` defaults to "player" because that is the common case AND the safe one — a
# rule written without thinking about enemies should not fire for every wandering skeleton.
func _when_matches(when, payload: Dictionary) -> bool:
	if not (when is Dictionary):
		return true
	var w: Dictionary = when
	var target := String(w.get("target", ""))
	if target != "":
		var got := String(payload.get("id", payload.get("kind", "")))
		if got != target:
			return false
	if payload.has("who"):
		var want := String(w.get("who", "player"))
		if want != "any" and want != String(payload["who"]):
			return false
	return true


# ---------------- conditions ----------------

func _eval(c, payload: Dictionary) -> bool:
	if c == null:
		return true
	if not (c is Dictionary):
		return true
	var d: Dictionary = c

	if d.has("all"):
		for sub in d["all"]:
			if not _eval(sub, payload):
				return false
		return true
	if d.has("any"):
		for sub in d["any"]:
			if _eval(sub, payload):
				return true
		return false
	if d.has("not"):
		return not _eval(d["not"], payload)

	if d.has("var"):
		return _cmp(_vget(String(d["var"])), String(d.get("op", "==")), d.get("value", 0))
	if d.has("chance"):
		return randf() < float(d["chance"])
	if d.has("has_item"):
		return main.rpg != null and main.rpg.has_item(String(d["has_item"]))
	if d.has("has_flag"):
		return main.rpg != null and main.rpg.has_flag(String(d["has_flag"]))
	if d.has("time_of_day"):
		return main.weather != null and String(main.weather.time_state) == String(d["time_of_day"])
	if d.has("health"):
		# Same `hp_max` typo the `heal` action carried: the property is `max_hp`, so this divided by
		# the 100.0 fallback in every world. A game with a 300 hp hero read 0.83 at 250 hp and its
		# "below 30%" rule fired at 90 hp instead of 250 — a low-health trigger off by 3x.
		if main.rpg == null:
			return false
		var frac: float = float(main.rpg.hp) / maxf(1.0, float(main.rpg.max_hp))
		return _cmp(frac, String(d["health"]), d.get("value", 0.0))
	if d.has("in_region"):
		return shell != null and String(shell._cur_region) == String(d["in_region"])
	if d.has("in_zone"):
		return shell != null and shell.has_method("in_zone") and shell.in_zone(String(d["in_zone"]))

	# --- conditions that were documented, validated and NEVER EVALUATED (phase 7) ---
	# These all fell through to the fail-open `_unimpl` below, which is the worst of the three
	# failure modes in this pass: not a dead rule but a rule that fires WHEN IT SHOULD NOT.
	# `{"alive": "boss"}` read true after the boss died; `{"distance_to": ...}` was true from across
	# the map. Only `{"not": {...}}` around one of them failed shut, which is its own puzzle.
	if d.has("item_count"):
		if main.rpg == null:
			return false
		return _cmp(main.rpg.item_count(String(d["item_count"])), String(d.get("op", ">=")), d.get("value", 1))
	if d.has("in_area"):
		if main.chunk_mode or main.scene_manager == null:
			return false   # a chunked open world has no areas — the honest answer is "not in it"
		return String(main.scene_manager.current_id) == String(d["in_area"])
	if d.has("weather"):
		return main.weather != null and String(main.weather._active_wx) == String(d["weather"])
	if d.has("alive"):
		return main.entity_alive(String(d["alive"]))
	if d.has("distance_to"):
		var dist: float = main.entity_distance(String(d["distance_to"]))
		if dist < 0.0:
			return false   # nothing by that name exists; "how far to it" has no true answer
		return _cmp(dist, String(d.get("op", "<")), d.get("value", 10.0))
	if d.has("peer_count"):
		var pc := 1
		if main.netsync != null and main.netsync.has_method("peer_count"):
			pc = main.netsync.peer_count()
		return _cmp(pc, String(d["peer_count"]), d.get("value", 2))
	if d.has("players_in_region"):
		if shell == null or not shell.has_method("players_in_region"):
			return false
		return _cmp(shell.players_in_region(String(d["players_in_region"])),
			String(d.get("op", ">=")), d.get("value", 1))

	_unimpl("condition:" + str(d.keys()))
	return true   # FAIL OPEN. An unknown condition must not silently mute a rule and make a game
	              # look broken for a reason nobody can see; verify catches the typo statically.


func _cmp(a, op: String, b) -> bool:
	match op:
		"==": return a == b
		"!=": return a != b
		"<":  return float(a) < float(b)
		"<=": return float(a) <= float(b)
		">":  return float(a) > float(b)
		">=": return float(a) >= float(b)
	return false


# ---------------- actions ----------------

func _run(actions, payload: Dictionary) -> void:
	if not (actions is Array):
		return
	for a0 in (actions as Array):
		if typeof(a0) != TYPE_DICTIONARY:
			continue
		_do(a0, payload)


func _do(a: Dictionary, payload: Dictionary) -> void:
	# --- state ---
	if a.has("set"):
		_vset(String(a["set"]), a.get("value", 0)); return
	if a.has("add"):
		_vset(String(a["add"]), _num(_vget(String(a["add"]))) + float(a.get("value", 1))); return
	if a.has("toggle"):
		_vset(String(a["toggle"]), not bool(_vget(String(a["toggle"])))); return
	if a.has("set_random"):
		_vset(String(a["set_random"]), randi_range(int(a.get("min", 0)), int(a.get("max", 1)))); return
	if a.has("clamp"):
		# Bounds default to the var's own declared min/max, so `{"clamp": "hunger"}` means "put it
		# back inside its spec" without restating numbers the author already wrote once.
		var cn := String(a["clamp"])
		var cs: Dictionary = _spec.get(cn, {})
		var lo := float(a.get("min", cs.get("min", -1e12)))
		var hi := float(a.get("max", cs.get("max", 1e12)))
		_vset(cn, clampf(_num(_vget(cn)), lo, hi)); return

	# --- character ---
	if a.has("emote"):
		# One-shot emote/action clip on the hero (dance, wave, cheer, sit, taunt, …). The rig has
		# carried this capability since the action hook existed, but NOTHING called it — the hook
		# had zero callers anywhere in the template, so the animations were unreachable from data.
		# This is that trigger. It also broadcasts, so other players see the emote.
		if shell != null and shell.has_method("play_emote"):
			shell.play_emote(String(a["emote"]), float(a.get("hold", 1.2)))
		return

	# --- ui ---
	if a.has("toast"):
		if shell != null:
			shell._toast(_text(String(a["toast"]), payload), float(a.get("hold", 3.0)))
		return
	if a.has("shake"):
		if shell != null:
			shell._shake_cam(float(a.get("shake", 0.2)))
		return
	if a.has("subtitle"):
		# Bottom-third narration. `{"subtitle": ""}` clears it — the same key, so a rule pair reads
		# as one thing rather than needing a second action name to undo the first.
		var sb = a["subtitle"]
		if shell != null:
			if sb is Dictionary:
				shell.subtitle(_text(String((sb as Dictionary).get("text", "")), payload),
					float((sb as Dictionary).get("hold", 5.0)))
			else:
				shell.subtitle(_text(String(sb), payload), float(a.get("hold", 5.0)))
		return
	if a.has("panel"):
		var pn = a["panel"]
		if shell != null and shell.has_method("show_panel"):
			shell.show_panel(_text_cfg(pn if pn is Dictionary else {"text": String(pn)}, payload))
		return
	if a.has("prompt"):
		var pr = a["prompt"]
		if shell != null and shell.has_method("show_prompt"):
			shell.show_prompt(_text_cfg(pr if pr is Dictionary else {"text": String(pr)}, payload))
		return
	if a.has("fade"):
		# "out" darkens to opaque, "in" clears — the words a director uses, not alpha numbers.
		var fd = a["fade"]
		var to := 1.0
		var ftime := 0.6
		var fcol := Color(0, 0, 0)
		if fd is Dictionary:
			var fdd: Dictionary = fd
			if fdd.has("to"):
				to = float(fdd["to"])
			elif String(fdd.get("dir", "out")) == "in":
				to = 0.0
			ftime = float(fdd.get("time", 0.6))
			fcol = shell._col(fdd.get("color", null), fcol) if shell != null else fcol
		elif fd is String:
			to = 0.0 if String(fd) == "in" else 1.0
		elif fd is bool:
			to = 1.0 if bool(fd) else 0.0
		else:
			to = float(fd)
		if shell != null:
			shell.fx_fade(to, ftime, fcol)
		return
	if a.has("tint"):
		# A wash that STAYS until something clears it. `{"tint": "clear"}` is the off switch.
		var tn = a["tint"]
		var tcol := Color(0, 0, 0, 0)
		var ttime := 0.4
		if tn is Dictionary:
			var tnd: Dictionary = tn
			tcol = shell._col(tnd.get("color", null), tcol) if shell != null else tcol
			ttime = float(tnd.get("time", 0.4))
		elif tn is Array:
			tcol = shell._col(tn, tcol) if shell != null else tcol
		# a bare string ("clear", or anything else) means take it off
		if shell != null:
			shell.fx_tint(tcol, ttime)
		return
	if a.has("hud_hide"):
		if main.set_hud_visible(String(a["hud_hide"]), false) == 0:
			_unimpl("hud_hide:no such HUD element '" + String(a["hud_hide"]) + "'")
		return
	if a.has("hud_show"):
		if main.set_hud_visible(String(a["hud_show"]), true) == 0:
			_unimpl("hud_show:no such HUD element '" + String(a["hud_show"]) + "'")
		return

	# --- audio ---
	if a.has("sound"):
		AudioManager.play_sfx(String(a["sound"]), float(a.get("db", 0.0)), float(a.get("pitch", 1.0))); return
	if a.has("music"):
		var st := AudioManager.stream_for("res://audio/" + String(a["music"]) + ".ogg")
		if st != null:
			AudioManager.play_music(st)
		return
	if a.has("ambient"):
		var sa := AudioManager.stream_for("res://audio/" + String(a["ambient"]) + ".ogg")
		if sa != null:
			AudioManager.play_ambient(sa)
		return

	# --- items / flags ---
	if a.has("grant"):
		if main.rpg != null:
			main.rpg.add_item(String(a["grant"]), int(a.get("qty", 1)))
		return
	if a.has("remove_item"):
		if main.rpg != null:
			main.rpg.consume_item(String(a["remove_item"]))
		return
	if a.has("set_flag"):
		if main.rpg != null:
			main.rpg.set_flag(String(a["set_flag"]))
		return
	if a.has("clear_flag"):
		if main.rpg != null:
			main.rpg.clear_flag(String(a["clear_flag"]))
		return
	if a.has("set_count"):
		# Force the held quantity. Routed through add/consume so `collect` / `use_item` still
		# report — a silent inventory write would strand any rule watching for that item.
		var sc = a["set_count"]
		if main.rpg != null:
			if sc is Dictionary:
				main.rpg.set_item_count(String((sc as Dictionary).get("item", "")),
					int((sc as Dictionary).get("value", 0)))
			else:
				main.rpg.set_item_count(String(sc), int(a.get("value", 0)))
		return
	if a.has("save"):
		# Commit NOW instead of on the debounce. The point is a checkpoint the player can trust:
		# closing the tab one second after a milestone must not lose it.
		if Save != null:
			Save.flush()
			print("GOGI_SAVE flushed")
		return

	# --- player ---
	if a.has("damage"):
		main.take_damage(float(a["damage"])); return
	if a.has("heal"):
		# The ceiling is `max_hp`. This read `hp_max` — a property that does not exist — so
		# Object.get returned null and every heal in every game clamped to the literal 100.0
		# fallback. In a world with a bigger pool that is not a weak heal, it is a heal that
		# SUBTRACTS: at 250/300 hp, minf(100, 250+20) set health to 100.
		if main.rpg != null:
			main.rpg.hp = minf(float(main.rpg.max_hp), float(main.rpg.hp) + float(a["heal"]))
			main.rpg.changed.emit()
		return
	if a.has("grant_xp"):
		if main.rpg != null:
			main.rpg.grant_xp(int(a["grant_xp"]))
		return
	if a.has("grant_gold"):
		if main.rpg != null:
			main.rpg.add_gold(int(a["grant_gold"]))
		return
	if a.has("equip"):
		if main.rpg != null:
			main.rpg.equip(String(a["equip"]), true)
		return

	# --- player state (phase 6) — main owns the body, the streamer and the equip visual ---
	if a.has("teleport_player"):
		var tp = a["teleport_player"]
		var tv = _vec3(tp if not (tp is Dictionary) else (tp as Dictionary).get("to", null))
		if tv == null:
			_unimpl("teleport_player:needs [x,y,z]")
		else:
			var snap := true
			if tp is Dictionary:
				snap = bool((tp as Dictionary).get("snap_ground", true))
			main.teleport_player_to(tv, snap)
		return
	if a.has("set_health"):
		var sh = a["set_health"]
		if sh is Dictionary:
			main.set_player_health(float((sh as Dictionary).get("hp", -1.0)),
				float((sh as Dictionary).get("max", 0.0)))
		else:
			main.set_player_health(float(sh), 0.0)
		return
	if a.has("give_weapon"):
		var gw = a["give_weapon"]
		if gw is Dictionary:
			main.give_weapon(String((gw as Dictionary).get("id", "")),
				bool((gw as Dictionary).get("equip", true)))
		else:
			main.give_weapon(String(gw), true)
		return
	if a.has("set_speed"):
		var sv = a["set_speed"]
		if sv is Dictionary:
			# {"mult": 1.5} is relative to the BASE walk speed, not to the current one — so
			# re-firing the same buff rule cannot compound into an unplayable sprint.
			main.set_player_speed(main.BASE_MOVE_SPEED * float((sv as Dictionary).get("mult", 1.0)))
		else:
			main.set_player_speed(float(sv))
		return
	if a.has("freeze"):
		# `{"freeze": false}` is the one value that means "don't" — anything else (true, a label,
		# a duration) reads as "freeze the player", so a typo'd payload still freezes.
		main.set_frozen(bool(a["freeze"]) if a["freeze"] is bool else true)
		return
	if a.has("unfreeze"):
		main.set_frozen(false)
		return
	if a.has("respawn"):
		main.respawn_player(true)
		return
	if a.has("set_spawn"):
		var sp2 = a["set_spawn"]
		var spv = _vec3(sp2 if not (sp2 is Dictionary) else (sp2 as Dictionary).get("to", null))
		if spv == null:
			# The commonest intent by far: "checkpoint HERE". Bare `{"set_spawn": true}` (or any
			# non-coordinate) means where the player is standing right now.
			if main.player != null:
				main.set_spawn_point(main.player.global_position)
		else:
			main.set_spawn_point(spv)
		return

	# --- world ---
	if a.has("set_weather"):
		if main.weather != null and a["set_weather"] is Dictionary:
			main.weather.apply(a["set_weather"])
		return
	if a.has("restore_weather"):
		main._apply_weather(main.world_data); return
	if a.has("set_time"):
		# "day" / "night" / "sunrise" / "sunset". Keeps the CURRENT weather — an author asking for
		# night is not also asking to clear the storm.
		if main.weather != null and main.weather.has_method("set_time"):
			main.weather.set_time(String(a["set_time"]))
			print("GOGI_TIME ", String(a["set_time"]))
		return
	if a.has("stop_audio"):
		var sa2 = a["stop_audio"]
		AudioManager.stop_audio(String(sa2) if sa2 is String else "all")
		return

	# --- doors & seams (phase 9) — interaction.gd owns the leaves, the colliders and the locks ---
	if a.has("open_door"):
		if main.interaction == null or main.interaction.set_door_open(String(a["open_door"]), true) == 0:
			_unimpl("open_door:no door named '" + String(a["open_door"]) + "'")
		return
	if a.has("close_door"):
		if main.interaction == null or main.interaction.set_door_open(String(a["close_door"]), false) == 0:
			_unimpl("close_door:no door named '" + String(a["close_door"]) + "'")
		return
	if a.has("unlock_seam"):
		# Also unlocks a locked DOOR of that name: an author saying "unlock the gate" does not care
		# which of the two the engine happened to build, and picking the wrong one is a silent no-op.
		if main.interaction == null or main.interaction.unlock(String(a["unlock_seam"])) == 0:
			_unimpl("unlock_seam:no locked seam or door named '" + String(a["unlock_seam"]) + "'")
		return

	# --- quest ---
	if a.has("start_quest"):
		if main.quest != null:
			main.quest.start(String(a["start_quest"]))
		return
	if a.has("complete_quest"):
		if main.quest == null or not main.quest.force_complete(String(a["complete_quest"])):
			_unimpl("complete_quest:no unfinished quest named '" + String(a["complete_quest"]) + "'")
		return
	if a.has("advance_chain"):
		if shell == null or not shell.has_method("advance_chain") or not shell.advance_chain():
			_unimpl("advance_chain:this world has no story chain to advance")
		return

	# --- rules (the state-machine primitive) ---
	if a.has("enable_rule"):
		_disabled.erase(String(a["enable_rule"])); return
	if a.has("disable_rule"):
		_disabled[String(a["disable_rule"])] = true; return

	# --- spawning (main owns the model cache + the live-entity registry) ---
	if a.has("spawn"):
		var sp = a["spawn"]
		if sp is Dictionary:
			main.spawn_enemies(String((sp as Dictionary).get("kind", "")), 1,
				float((sp as Dictionary).get("radius", 6.0)),
				String((sp as Dictionary).get("id", "")))
		return
	if a.has("spawn_wave"):
		var sw = a["spawn_wave"]
		if sw is Dictionary:
			main.spawn_enemies(String((sw as Dictionary).get("kind", "")),
				int((sw as Dictionary).get("count", 3)),
				float((sw as Dictionary).get("radius", 12.0)),
				String((sw as Dictionary).get("id", "")))
		return
	if a.has("despawn"):
		var dp = a["despawn"]
		if dp is Dictionary:
			main.despawn_entities(String((dp as Dictionary).get("kind", "")),
				String((dp as Dictionary).get("id", "")))
		else:
			main.despawn_entities(String(dp), "")      # {"despawn": "imp"} shorthand
		return
	if a.has("teleport_entity"):
		var te = a["teleport_entity"]
		if te is Dictionary:
			var to = (te as Dictionary).get("to", [0, 0, 0])
			if to is Array and (to as Array).size() >= 3:
				main.teleport_entity_to(String((te as Dictionary).get("id", "")),
					String((te as Dictionary).get("kind", "")),
					Vector3(float(to[0]), float(to[1]), float(to[2])))
		return

	# --- build (building.gd owns the palette + the placed pieces) ---
	# `main.building` is null until a world enables the mechanic, so every one of these is a no-op in
	# a game with no `building` block rather than an error.
	if a.has("unlock_palette"):
		if main.building != null:
			main.building.unlock_piece(String(a["unlock_palette"]))
		return
	if a.has("lock_palette"):
		if main.building != null:
			main.building.lock_piece(String(a["lock_palette"]))
		return
	if a.has("set_build_enabled"):
		if main.building != null:
			main.building.set_build_enabled(bool(a["set_build_enabled"]))
		return
	if a.has("clear_builds"):
		if main.building != null:
			main.building.clear_all()
		return

	# --- enemies ---
	if a.has("aggro"):
		main.aggro_enemies(String(a["aggro"]))
		return
	if a.has("set_target"):
		var st = a["set_target"]
		if st is Dictionary:
			main.aggro_enemies(String((st as Dictionary).get("kind", "")))
		else:
			main.aggro_enemies(String(st))
		return

	# --- game ---
	if a.has("restart"):
		main.restart_run()
		return
	if a.has("lose"):
		if shell != null and shell.has_method("_show_defeat"):
			shell._show_defeat()
		return
	if a.has("win"):
		if shell != null and shell.has_method("_show_victory") and not shell._won:
			shell._won = true
			shell._show_victory()
		return

	_unimpl("action:" + str(a.keys()))


## `[x, y, z]` -> Vector3, anything else -> null. Returning null rather than Vector3.ZERO matters:
## zero is a legal destination, so a silent coercion would teleport the player to the world origin
## instead of reporting that the author wrote something the engine could not read.
func _vec3(v) -> Variant:
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return null


# ---------------- vars ----------------

func _vget(name_: String):
	return _vars.get(name_, 0)


func _vset(name_: String, v) -> void:
	if not _spec.has(name_):
		_unimpl("var:" + name_)   # writing an undeclared var — verify flags this statically
		return
	var sp: Dictionary = _spec[name_]
	if v is float or v is int:
		var f := float(v)
		if sp.has("min"):
			f = maxf(f, float(sp["min"]))
		if sp.has("max"):
			f = minf(f, float(sp["max"]))
		v = f
	var before = _vars.get(name_, null)
	if before == v:
		return                     # no change -> no event. Cheap, and it keeps cascades finite.
	_vars[name_] = v
	if Save != null and bool(sp.get("persist", false)):
		Save.put("var." + name_, v)   # staged, not written — Save debounces (see save.gd)
	if not _synced.is_empty():
		_broadcast_var(name_, v)
	if not _hud.is_empty():
		_refresh_hud()
	fire("var_changed", {"id": name_})
	_check_threshold(name_, before, v)


# A threshold event is what turns "a number moved" into "something happened" — a countdown reaching
# zero, a score passing the target, hunger emptying. Fires only on the CROSSING, so a rule attached
# to it runs once per crossing rather than every frame the value sits past the bound.
func _check_threshold(name_: String, before, after) -> void:
	var sp: Dictionary = _spec.get(name_, {})
	if not sp.has("at"):
		return
	var at := float(sp["at"])
	var b := _num(before)
	var a := _num(after)
	if (b < at and a >= at) or (b > at and a <= at):
		fire("var_threshold", {"id": name_})


func _num(v) -> float:
	if v is bool:
		return 1.0 if v else 0.0
	if v is float or v is int:
		return float(v)
	return 0.0


# `{score}` in any authored string becomes the value. Plain substitution ONLY — no expressions,
# no formatting language. The moment this grows an operator it stops being data.
## `_text` applied to a config dict's human-readable fields, so `{score}` and `{event.id}` work in a
## panel or prompt exactly as they do in a toast. Interpolating only these three keeps ids, colours
## and choice ids literal — substituting a var into an `id` would make the event unmatchable.
func _text_cfg(cfg: Dictionary, payload: Dictionary) -> Dictionary:
	var out := cfg.duplicate(true)
	for k in ["title", "text", "button"]:
		if out.has(k):
			out[k] = _text(String(out[k]), payload)
	if out.get("choices", null) is Array:
		for c in (out["choices"] as Array):
			if c is Dictionary and (c as Dictionary).has("label"):
				(c as Dictionary)["label"] = _text(String((c as Dictionary)["label"]), payload)
	return out


func _text(s: String, payload: Dictionary) -> String:
	var out := s
	for k in _vars:
		var tok := "{" + String(k) + "}"
		if out.contains(tok):
			out = out.replace(tok, _fmt(_vars[k]))
	for k2 in payload:
		var tok2 := "{event." + String(k2) + "}"
		if out.contains(tok2):
			out = out.replace(tok2, str(payload[k2]))
	return out


func _fmt(v) -> String:
	if v is float:
		return str(int(v)) if absf(v - float(int(v))) < 0.001 else ("%.1f" % v)
	return str(v)


# ---------------- tick ----------------

func _process(delta: float) -> void:
	_cascade = 0                        # the budget is PER FRAME, so normal chains never starve
	if _ticking.is_empty() or main == null:
		return
	if shell != null and shell.input_locked():
		return                          # a title screen or victory panel is up — the world is paused
	for name_ in _ticking:
		var rate := float((_spec[name_] as Dictionary).get("tick", 0.0))
		_vset(name_, _num(_vget(name_)) + rate * delta)


# ---------------- HUD ----------------
#
# A readout bound to a var. This is the other half of why a race timer stopped being a feature
# request: `tick` makes the number exist, and this makes the player see it. Between them, "timer",
# "score", "ammo", "hunger bar" and "lap counter" are all the same two lines of data.

const _POS := {
	"top_left": Vector2(0.02, 0.03), "top_right": Vector2(0.72, 0.03),
	"top_center": Vector2(0.38, 0.03),
	"bottom_left": Vector2(0.02, 0.86), "bottom_right": Vector2(0.72, 0.86),
}

func _build_hud() -> void:
	var hd = main.world_data.get("hud", [])
	if not (hd is Array) or main.hud_layer == null:
		return
	for e0 in (hd as Array):
		if typeof(e0) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = e0
		var anchor: Vector2 = _POS.get(String(e.get("pos", "top_left")), _POS["top_left"])

		if e.has("button"):
			# A game-declared control. Fires `hud_button` with its id, so a game can add "DROP",
			# "SCAN", "CALL DOG" without a line of code — and without the engine knowing what any
			# of them mean.
			var bid := String(e["button"])
			var b := Button.new()
			b.text = String(e.get("label", bid.to_upper()))
			b.custom_minimum_size = Vector2(200, 96)
			b.add_theme_font_size_override("font_size", 26)
			b.pressed.connect(func() -> void: fire("hud_button", {"id": bid}))
			main.hud_layer.add_child(b)
			# `id` recorded so `hud_show`/`hud_hide` can address a world-declared button by the same
			# name the author gave it. Without it those actions could only reach engine controls.
			_hud.append({"node": b, "anchor": anchor, "kind": "button", "id": bid})
			continue

		if not e.has("bind"):
			continue
		var kind := String(e.get("format", "int"))
		if kind == "bar":
			var root := Control.new()
			var bg := ColorRect.new()
			bg.color = Color(0, 0, 0, 0.5)
			bg.size = Vector2(220, 18)
			root.add_child(bg)
			var fill := ColorRect.new()
			fill.color = shell._col(e.get("color", null), Color(0.85, 0.35, 0.3))
			fill.size = Vector2(220, 18)
			root.add_child(fill)
			main.hud_layer.add_child(root)
			_hud.append({"node": root, "fill": fill, "anchor": anchor, "kind": "bar",
				"bind": String(e["bind"]), "w": 220.0})
		else:
			var l := Label.new()
			l.add_theme_font_size_override("font_size", 26)
			l.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85))
			l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
			l.add_theme_constant_override("shadow_offset_y", 2)
			main.hud_layer.add_child(l)
			_hud.append({"node": l, "anchor": anchor, "kind": kind,
				"bind": String(e["bind"]), "label": String(e.get("label", ""))})
	if not _hud.is_empty():
		_layout_hud()
		_refresh_hud()
		get_window().size_changed.connect(_layout_hud)


## The rectangles the ENGINE'S own HUD already occupies — every visible button, the stats block,
## the health bar, the minimap.
##
## The rule HUD and the engine HUD are laid out by two functions that knew nothing about each other,
## so a world-declared `top_right` readout printed straight through the SHEATHE button (seen on a
## short landscape viewport, where the bottom-anchored thumb grid climbs into the top band). The old
## fix was a single hardcoded reserve for `main.stats`, which only ever covered the one collision
## someone happened to notice. Reading the real rects covers all of them, at any viewport shape,
## with no shared constants to drift apart.
func _engine_hud_rects() -> Array:
	var out: Array = []
	for k in main._hud_btns:
		var b = main._hud_btns[k]
		if b != null and is_instance_valid(b) and (b as Control).visible:
			out.append(Rect2((b as Control).position, (b as Control).size))
	for extra in [main.stats, main._hp_bg, main._minimap]:
		if extra != null and is_instance_valid(extra) and (extra as CanvasItem).visible:
			var c := extra as Control
			var sz: Vector2 = c.size
			if sz.x < 1.0 or sz.y < 1.0:
				sz = c.get_combined_minimum_size()
			out.append(Rect2(c.position, sz))
	return out


# Does a touch land on one of THIS layer’s buttons? Mirrors building.ui_hit() so main._touch_on_hud
# has exactly one question to ask of each layer that draws controls into the HUD.
#
# WHY IT MATTERS: main.gd _input runs BEFORE the GUI hit-tests, so a layer whose buttons main does not
# know about gets its presses claimed as camera-orbit drags — the button never fires AND the view
# swings. Measured at ~150 degrees of yaw on a 120px slide off WEAPON >, a button THIS file draws.
# Any new control added here is covered automatically; a new LAYER must add its own ui_hit.
func ui_hit(p: Vector2) -> bool:
	for h in _hud:
		if String(h.get("kind", "")) != "button":
			continue
		var n = h.get("node")
		if n == null or not is_instance_valid(n):
			continue
		var c := n as Control
		if c != null and c.visible and Rect2(c.global_position, c.size).has_point(p):
			return true
	return false


func _layout_hud() -> void:
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	var taken := _engine_hud_rects()
	var placed: Array = []          # rule-HUD rects already committed — they must not stack either
	for h in _hud:
		var a: Vector2 = h["anchor"]
		var node := h["node"] as Control
		var sz: Vector2
		if String(h.get("kind", "")) == "bar":
			sz = Vector2(220, 18)
		else:
			if node is Label:
				(node as Label).reset_size()      # size the text BEFORE testing it for overlap
			sz = node.size
			if sz.x < 1.0 or sz.y < 1.0:
				sz = node.get_combined_minimum_size()
		sz = Vector2(maxf(sz.x, 40.0), maxf(sz.y, 22.0))
		var pos := Vector2(vp.x * a.x, vp.y * a.y)
		# Right-anchored items are measured from their RIGHT edge, so a long label grows leftward
		# into open space instead of off the screen.
		if a.x > 0.6:
			pos.x = minf(pos.x, vp.x - sz.x - 18.0)
		var want := pos
		pos = _place_clear(a, pos, sz, taken + placed, vp)
		node.position = pos
		placed.append(Rect2(pos, sz))
		if pos != want:
			print("GOGI_HUD_FIT %s moved %.0f,%.0f -> %.0f,%.0f" % [
				String(h.get("bind", h.get("id", "?"))), want.x, want.y, pos.x, pos.y])
	# Anything still overlapping after the nudge is a layout the engine could NOT resolve — say so
	# rather than let the player find two controls stacked on top of each other.
	var bad := 0
	for i in range(placed.size()):
		for t in taken:
			if (placed[i] as Rect2).intersects(t as Rect2):
				bad += 1
				break
	if bad > 0:
		print("GOGI_HUD_FIT UNRESOLVED overlaps=%d (viewport %.0fx%.0f too crowded)" % [bad, vp.x, vp.y])


## Find a spot for `want` that clears everything already on screen.
##
## Candidate order is the whole design: a side-anchored item escapes SIDEWAYS first, because a
## readout nudged left stays in the band the author asked for, while one shoved downward lands in
## the middle of the play area. The first version only pushed vertically and did exactly that —
## moved a `top_right` counter to mid-screen and still left one overlap unresolved.
##
## Bounded by construction: candidates come from the obstacles themselves, so the search is a few
## dozen rect tests on a resize, not a loop that can spin.
func _place_clear(anchor: Vector2, want: Vector2, sz: Vector2, taken: Array, vp: Vector2) -> Vector2:
	var cands: Array = [want]
	for t in taken:
		var r: Rect2 = t
		if anchor.x > 0.6:
			cands.append(Vector2(r.position.x - sz.x - 10.0, want.y))
		elif anchor.x < 0.4:
			cands.append(Vector2(r.position.x + r.size.x + 10.0, want.y))
	for t2 in taken:
		var r2: Rect2 = t2
		cands.append(Vector2(want.x, r2.position.y + r2.size.y + 8.0))
		cands.append(Vector2(want.x, r2.position.y - sz.y - 8.0))
	for c0 in cands:
		var c: Vector2 = c0
		if c.x < 8.0 or c.y < 8.0 or c.x + sz.x > vp.x - 8.0 or c.y + sz.y > vp.y - 8.0:
			continue
		var free := true
		for t3 in taken:
			if Rect2(c, sz).intersects(t3 as Rect2):
				free = false
				break
		if free:
			return c
	# NOTHING IS FREE. Return the LEAST-overlapping candidate rather than the anchor: on a crowded
	# phone viewport the anchor is often the worst possible spot (dead centre of a button), and
	# "clips a corner" is recoverable where "printed through the label" is not.
	var best: Vector2 = want
	var best_area := 1e12
	for c1 in cands:
		var cc: Vector2 = c1
		if cc.x < 8.0 or cc.y < 8.0 or cc.x + sz.x > vp.x - 8.0 or cc.y + sz.y > vp.y - 8.0:
			continue
		var area := 0.0
		for t4 in taken:
			var ov := Rect2(cc, sz).intersection(t4 as Rect2)
			area += ov.size.x * ov.size.y
		if area < best_area:
			best_area = area
			best = cc
	return best


# Driven from _vset (value changed) rather than every frame — a HUD that only redraws when its
# number moves costs nothing on a phone, and a ticking var already routes through _vset.
func _refresh_hud() -> void:
	# Set when a readout's width changed enough to invalidate its placement. Re-laying out on every
	# tick would be wasteful; a ticking clock only changes width when it gains or loses a digit.
	var relayout := false
	for h in _hud:
		if not h.has("bind"):
			continue
		var v = _vget(String(h["bind"]))
		if String(h["kind"]) == "bar":
			var sp: Dictionary = _spec.get(String(h["bind"]), {})
			var mx := float(sp.get("max", 100.0))
			var frac: float = clampf(_num(v) / maxf(0.001, mx), 0.0, 1.0)
			(h["fill"] as ColorRect).size = Vector2(float(h["w"]) * frac, 18)
		else:
			var lb := h["node"] as Label
			lb.text = String(h["label"]) + (" " if String(h["label"]) != "" else "") + _fmt_as(v, String(h["kind"]))
			# MEASURE AFTER WRITING. A Label added straight to a CanvasLayer is never laid out by a
			# container, so its `size` stays (0,0) and the collision pass tested a 40x22 stub against
			# the engine's buttons — found no overlap, left it where it was, and the real (much wider)
			# text rendered straight through the SHEATHE button. Every other rule-HUD control is a
			# Button with an explicit custom_minimum_size, which is exactly why only the readouts
			# misplaced. reset_size() pins the control to the text it is actually showing.
			lb.reset_size()
			if absf(lb.size.x - float(h.get("w_last", 0.0))) > 2.0:
				h["w_last"] = lb.size.x
				relayout = true
	if relayout:
		_layout_hud()


func _fmt_as(v, kind: String) -> String:
	match kind:
		"time":
			var t := int(_num(v))
			return "%d:%02d" % [t / 60, t % 60]
		"pct":
			return "%d%%" % int(_num(v))
		"int":
			return str(int(_num(v)))
	return _fmt(v)


# ---------------- multiplayer: synced vars ----------------
#
# One flag on a var and it is shared. This is the smallest change in the whole layer and the one
# that turns co-presence into an actual shared game: before it, players could see each other walk
# around; after it, they share a score, a door state, or who is "it".
#
# LAST WRITER WINS, and that is a real limit worth stating rather than discovering. Two players
# changing the same var in the same instant converge on whichever packet lands second. Fine for a
# score, a flag or a phase; NOT a substitute for an authoritative server in a competitive game.
#
# The `_applying_remote` guard is what stops an echo storm: without it, applying a received value
# would broadcast it straight back out, and two clients would volley one change forever.

var _synced: Dictionary = {}        # name -> true, cached so _vset does one lookup
var _applying_remote := false
var _net_wired := false
var _recv_logged: Dictionary = {}   # var name -> true, so the receive trace prints once per var


func _wire_sync() -> void:
	for name_ in _spec:
		if bool((_spec[name_] as Dictionary).get("sync", false)):
			_synced[name_] = true
	if _synced.is_empty() or _net_wired:
		return
	var net = get_node_or_null("/root/Net")
	if net == null:
		return
	if not net.message.is_connected(_on_net_message):
		net.message.connect(_on_net_message)
	_net_wired = true
	print("GOGI_RULES sync vars=%d" % _synced.size())


func _broadcast_var(name_: String, v) -> void:
	if _applying_remote or not _synced.has(name_):
		return
	var net = get_node_or_null("/root/Net")
	if net != null and net.has_method("send"):
		net.send({"t": "v", "n": name_, "val": v})


func _on_net_message(d: Dictionary) -> void:
	if String(d.get("t", "")) != "v":
		return                       # netsync owns "p"; unknown types are ignored by everyone
	var name_ := String(d.get("n", ""))
	if not _synced.has(name_):
		return                       # a var this world does not declare as synced — drop it
	# Once per var: proves the RECEIVE path, which is otherwise indistinguishable from the same
	# client having set the value itself. Once-per-var rather than per-packet because a synced
	# ticking var would otherwise print every frame.
	if not _recv_logged.has(name_):
		_recv_logged[name_] = true
		print("GOGI_RULES_SYNC_RECV ", name_, "=", d.get("val", 0))
	_applying_remote = true
	_vset(name_, d.get("val", 0))
	_applying_remote = false


## Re-announce every synced WORLD var. Called when a peer joins: a late arrival otherwise sits on
## its own defaults and sees a shared score of zero while everyone else is at forty. Everyone
## answers rather than a designated host, because this transport has no host — last-writer-wins
## makes the duplicate answers converge instead of conflict.
func announce_synced() -> void:
	for name_ in _synced:
		if String((_spec[name_] as Dictionary).get("scope", "world")) == "world":
			_broadcast_var(name_, _vget(name_))


# ---------------- diagnostics ----------------

func _unimpl(what: String) -> void:
	if _unimpl_seen.has(what):
		return
	_unimpl_seen[what] = true
	print("GOGI_RULES_UNIMPL ", what)
	push_warning("GOGI_RULES unimplemented: " + what)
