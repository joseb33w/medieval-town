class_name AnimRig extends RefCounted
## Shared KayKit Rig_Medium retarget. The Knight AND the streamed skeletons all use the
## same `Rig_Medium` skeleton (23 bones), but NONE of them carry embedded clips — the
## clips live in the packed `kk_rig_medium_*` libraries. This copies those clip resources
## onto a fresh AnimationPlayer attached to any Rig_Medium model, so one clip set drives
## the hero and every enemy. Verified headless: copied tracks (path `Rig_Medium/Skeleton3D:bone`)
## resolve against the model and animate the skeleton.

const LIBS := [
	"res://models/kk_rig_medium_general.glb",
	"res://models/kk_rig_medium_movementbasic.glb",
	"res://models/kk_rig_medium_combatmelee.glb",
]

static var _clips := {}          # source clip name -> Animation (cached, duplicated)

static func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null

static func _load_clips() -> void:
	if not _clips.is_empty():
		return
	for path in LIBS:
		# Quiet-skip absent libraries (the template now SHIPS them in
		# models/, but a build that strips them must degrade to one
		# missing-clip warning downstream, not a loader error per instance).
		if not ResourceLoader.exists(path):
			continue
		var ps = load(path)
		if ps == null:
			continue
		var inst := (ps as PackedScene).instantiate()
		var ap := _find_ap(inst)
		if ap != null:
			for nm in ap.get_animation_list():
				if not _clips.has(nm):
					_clips[nm] = ap.get_animation(nm).duplicate()
		inst.queue_free()

## Find the model's REAL skeleton (the one with the most bones). The model's rig may be named
## anything — a Meshy character (a colossus / tribal warrior / mammoth) is NOT a KayKit `Rig_Medium` — so
## we must never assume the literal `Rig_Medium/Skeleton3D` node path the library clips were baked with.
static func _richest_skeleton(n: Node) -> Skeleton3D:
	var best: Skeleton3D = null
	for sk in n.find_children("*", "Skeleton3D", true, false):
		if best == null or (sk as Skeleton3D).get_bone_count() > best.get_bone_count():
			best = sk as Skeleton3D
	return best

## Attach an AnimationPlayer to `model` exposing aliases mapped to source clip names.
## `mapping`: {alias: source_clip_name}. `loops`: aliases that should loop.
## RETARGET-BY-BONE: the library clips carry literal `Rig_Medium/Skeleton3D:<bone>` track paths. We
## re-path every track onto THIS model's actual skeleton and PRUNE any track whose bone the skeleton
## lacks. A genuine Rig_Medium model reproduces identical paths (a no-op — the hero and KayKit enemies
## are unchanged). A FOREIGN rig (a Meshy character with different bone names) loses every track, so
## attach returns null instead of feeding the AnimationMixer unresolvable tracks — which was leaving
## the mesh stuck in a bind-pose "glitch" while the body slid, AND spamming ~10000 `couldn't resolve
## track` console warnings (a real per-frame cost under nothreads WASM). Every caller already treats
## null as "no anim" -> the model shows its CLEAN imported pose instead of a broken half-pose.
static func attach(model: Node3D, mapping: Dictionary, loops: Array) -> AnimationPlayer:
	_load_clips()
	var skel := _richest_skeleton(model)
	if skel == null:
		return null
	var skel_path := String(model.get_path_to(skel))
	var lib := AnimationLibrary.new()
	var added := 0
	for alias in mapping:
		var src := String(mapping[alias])
		if not _clips.has(src):
			continue
		var a: Animation = (_clips[src] as Animation).duplicate()
		for ti in range(a.get_track_count() - 1, -1, -1):
			var bone := String(a.track_get_path(ti).get_concatenated_subnames())
			if bone == "" or skel.find_bone(bone) == -1:
				a.remove_track(ti)   # a bone this skeleton doesn't have -> unresolvable track, drop it
			else:
				a.track_set_path(ti, NodePath(skel_path + ":" + bone))
		if a.get_track_count() == 0:
			continue
		a.loop_mode = Animation.LOOP_LINEAR if alias in loops else Animation.LOOP_NONE   # KEEP: idle/walk MUST loop (else the play-once-freeze "float" bug)
		lib.add_animation(StringName(alias), a)
		added += 1
	if added == 0:
		return null   # foreign rig: not one track resolved — let the caller show the clean imported pose
	var ap := AnimationPlayer.new()
	ap.name = "RigPlayer"
	model.add_child(ap)
	ap.root_node = ap.get_path_to(model)          # tracks are relative to the model root
	ap.add_animation_library("", lib)
	return ap
