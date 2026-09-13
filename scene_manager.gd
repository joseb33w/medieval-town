class_name SceneManager extends Node
## SCENE MANAGER — owns the streamed-areas world (zone streaming).
## goto_area(id, spawn): fade out -> free current area (memory returns to ~baseline) ->
## AreaBuilder builds the next from world.json -> place the (persistent) player at the
## spawn -> fade in. Exactly ONE area resident at a time. reload() hot-swaps edited world
## data and rebuilds the CURRENT area live (used when a chat edit updates world.json).

signal area_entered(id)         # fires on each area arrival — drives reach_area quest objectives

var areas := {}                 # id -> area record
var builder: AreaBuilder
var interaction
var player: Node3D
var world_main: Node

var current_root: Node3D = null
var enemies: Array = []
var transitioning := false
var current_id := ""

var _fade: ColorRect
var _title: Label


func setup(p: Node3D, b: AreaBuilder, inter, main: Node, hud: CanvasLayer) -> void:
	player = p
	builder = b
	interaction = inter
	world_main = main
	_build_fade(hud)


func load_world(world: Dictionary) -> void:
	for a in world.get("areas", []):
		areas[a.id] = a


func start(world: Dictionary) -> void:
	load_world(world)
	goto_area(world.get("start_area", ""), world.get("start_spawn", ""))


# hot-reload: swap in edited world data + rebuild the CURRENT area live (no re-export).
# The rebuilt area is the SAME one the player is standing in, so KEEP the player where they
# are (captured before the rebuild, clamped to the possibly-resized room after) instead of
# teleporting to the spawn — a world.json chat edit must not yank the player across the room.
func reload(world: Dictionary) -> void:
	load_world(world)
	if current_id != "" and areas.has(current_id):
		var spawns: Dictionary = areas[current_id].get("spawns", {})
		var keep = player.global_position if (player != null and is_instance_valid(player)) else null
		goto_area(current_id, spawns.keys()[0] if spawns.size() > 0 else "", keep)


# keep_pos (optional Vector3): same-area hot-reload only — restore this position instead of
# the spawn, behind the fade. New-area transitions never pass it (spawn behavior unchanged).
func goto_area(id: String, spawn: String, keep_pos = null) -> void:
	if transitioning or not areas.has(id):
		return
	transitioning = true
	await _fade_to(1.0)

	# free the area we're leaving (its streamed instances + enemies + nav)
	if current_root and is_instance_valid(current_root):
		current_root.queue_free()
	current_root = null
	enemies = []
	interaction.clear()

	var rec: Dictionary = areas[id]
	if _title:
		_title.text = str(rec.get("name", id))
	var res = await builder.build_area(rec, world_main, player, world_main, interaction, null)
	current_root = res.root
	enemies = res.enemies
	current_id = id
	area_entered.emit(id)   # drives reach_area quest objectives + on_complete flags

	# place the persistent player: at the named spawn — or, on a same-area hot-reload, back at
	# the captured pre-rebuild position, clamped to the rebuilt room's walls (walls sit at ±size;
	# same ±(size-1) margin the named-prop placement uses) in case the edit shrank the area.
	if keep_pos is Vector3:
		var size := float(rec.get("size", 13))
		var kp: Vector3 = keep_pos
		player.global_position = Vector3(
			clamp(kp.x, -size + 1.0, size - 1.0), kp.y, clamp(kp.z, -size + 1.0, size - 1.0))
	else:
		var spawns: Dictionary = rec.get("spawns", {})
		var sp = spawns.get(spawn, spawns.values()[0] if spawns.size() > 0 else [0, 0, 0])
		player.global_position = Vector3(sp[0], sp[1], sp[2])
	player.velocity = Vector3.ZERO

	await get_tree().process_frame   # let the new frame settle before revealing
	await _fade_to(0.0)
	transitioning = false


# ---------------- fade overlay ----------------

func _build_fade(hud: CanvasLayer) -> void:
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 1)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_fade)
	_title = Label.new()
	_title.set_anchors_preset(Control.PRESET_CENTER)
	_title.add_theme_font_size_override("font_size", 44)
	_title.add_theme_color_override("font_color", Color(1, 1, 1))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fade.add_child(_title)


func _fade_to(a: float) -> void:
	var t := create_tween()
	t.tween_property(_fade, "color:a", a, 0.45)
	await t.finished
	_title.visible = a > 0.5
