extends RefCounted
## PER-AVATAR ANIMATION STATE — the hero locomotion/action state machine, one instance
## per animated character.
##
## WHY THIS IS A MODULE AND NOT FOUR GLOBALS IN main.gd
## It used to be `_hero_ap` / `_hero_anim` / `_hero_air_t` / `_hero_attack_t` held on main,
## which meant exactly ONE character in the scene could animate. The local player got the
## full idle/walk/run/jump/attack/swim machine; every REMOTE player in a multiplayer room
## was a frozen rest pose sliding across the ground, because there was nowhere to put a
## second character's state. Instancing this is what lets peers animate.
##
## THE INPUTS ARE INJECTED, THE LOGIC IS NOT. `update()` takes a motion dictionary rather
## than reading a CharacterBody3D, because the local player and a network peer answer
## "how fast am I going" differently (physics body vs interpolated transform) and NOTHING
## ELSE about them differs. Branching on local-vs-peer inside the state machine is how the
## two would drift apart the first time a threshold is tuned — the same trap
## _normalize_avatar_height records in its own comment ("they were two similar blocks, and
## one of them silently lost its scaling step").
##
##   motion := {
##     "speed":    float,   # horizontal speed (m/s)
##     "vy":       float,   # vertical velocity (m/s)
##     "on_floor": bool,    # grounded this frame
##     "swimming": bool,    # floating in deep water
##     "mounted":  bool,    # seated/riding -> GPose owns the pose, we stand down
##   }

var ap: AnimationPlayer = null   # the avatar's AnimationPlayer (retargeted OR embedded clips)
var anim := ""                   # current semantic anim kind (idle/walk/run/attack)
var air_t := 0.0                 # seconds continuously off the floor — coyote buffer so brief bumps/curbs don't flip to the fall (dive) clip
var attack_t := 0.0              # remaining melee-attack-clip hold (s)


## Bind this state to an avatar, retargeting a clip set if the model ships none. Returns
## true when there is something to play. The caller owns any body-specific follow-up (the
## local hero re-applies GPose.swim; a peer has no body to pose).
func attach(node: Node3D) -> bool:
	var found := AnimRig._find_ap(node)
	if found == null or found.get_animation_list().is_empty():
		# retarget a FULLER clip set so the hero idles / walks / runs / attacks instead of freezing
		# on a single idle pose. Aliases whose source clip is missing are simply skipped by AnimRig,
		# and play() degrades run->walk->idle, so a thinner library still animates.
		found = AnimRig.attach(node, {
			"idle": "Idle_A", "walk": "Walking_A", "run": "Running_A",
			"attack": "Melee_1H_Attack_Chop",
			"jump": "Jump_Full_Short", "fall": "Jump_Idle",
		}, ["idle", "walk", "run", "fall"])
	if found == null or found.get_animation_list().is_empty():
		return false
	ap = found
	anim = ""
	attack_t = 0.0
	play("idle")
	return true


## Semantic kind -> a real clip name on this rig. Works for BOTH the retargeted alias set
## (exact name) and a model that embeds its OWN clips (substring match), so library AND
## Meshy creature avatars animate. "" = no such clip.
func resolve(kind: String) -> String:
	if ap == null or not is_instance_valid(ap):
		return ""
	if ap.has_animation(kind):
		return kind
	var keys: Array = {
		"idle": ["idle"], "walk": ["walk"],
		"run": ["run", "sprint", "jog"],
		"jump": ["jump", "leap"],
		"fall": ["fall", "jump_idle", "air"],
		"attack": ["attack", "melee", "chop", "slash", "punch", "strike"],
		"swim": ["swim", "tread", "paddle", "float"],
	}.get(kind, [kind])
	for c in ap.get_animation_list():
		var cl := String(c).to_lower()
		for k in keys:
			if k in cl:
				return String(c)
	return ""


## Switch to a semantic anim with a short crossfade. Falls back run->walk->idle so a rig
## missing a clip animates instead of snapping to a frozen pose.
func play(kind: String) -> void:
	if ap == null or not is_instance_valid(ap) or kind == anim:
		return
	var clip := resolve(kind)
	if clip == "" and kind == "run":
		clip = resolve("walk")
	if clip == "" and kind != "idle":
		clip = resolve("idle")
	if clip == "":
		return
	# Embedded GLB locomotion clips import with loop_mode = NONE — walk/run then play ONE cycle and FREEZE
	# on the last frame while the body keeps moving, so the hero slid forward stuck in a single pose
	# ("floating, legs not moving, frozen"). The retargeted KayKit set gets looped at attach, but a Meshy
	# avatar's OWN clips don't. Force the cyclic clips to loop here; jump/attack/death stay one-shot.
	if kind == "idle" or kind == "walk" or kind == "run" or kind == "swim":
		var loop_anim := ap.get_animation(clip)
		if loop_anim != null and loop_anim.loop_mode == Animation.LOOP_NONE:
			loop_anim.loop_mode = Animation.LOOP_LINEAR
	anim = kind
	ap.play(clip, 0.15)


## Per-frame state machine (on foot only — a seated/mounted rider is posed by GPose).
## The attack clip plays out its window uninterrupted; otherwise moving -> run (walk fallback).
func update(delta: float, motion: Dictionary) -> void:
	if ap == null or not is_instance_valid(ap):
		return
	if bool(motion.get("mounted", false)):
		return
	# SWIM: while floating in deep water, stroke a swim clip (or, on a rig without one, hold the GPose.swim
	# tread pose) instead of the run cycle re-stamping over it every frame ("walking on water").
	if bool(motion.get("swimming", false)):
		var sc := resolve("swim")
		if sc != "" and anim != "swim":
			play("swim")
		return
	attack_t = maxf(0.0, attack_t - delta)
	if attack_t > 0.0:
		return   # let the swing clip / a one-shot action finish before locomotion resumes
	# COYOTE BUFFER: a hero running over city curbs / uneven ground loses floor contact for a frame or
	# two, which flipped the "fall" clip (a floating dive pose) on/off every few frames — reading as the
	# character FLOATING / diving while it ran. Only switch to jump/fall once genuinely airborne (>0.14s
	# off the floor, or clearly launched upward), so a bump keeps the run/walk clip and stays upright.
	#
	# Airborne pose ONLY when actually off the floor. The old code also fired on `velocity.y > 2.0`
	# while GROUNDED — running over city curbs / floor-snap pops spikes vy, so the hero kept flicking
	# into the jump-leap clip (this model's `jump` lifts the hips to y≈254, a ~1.5 m pop) and the
	# `fall` path falls back to idle (an idle pose mid-air). Both READ AS FLOATING while running.
	# Grounded (even bumpy) now always plays locomotion; off-floor & rising -> the jump leap; off-floor
	# & descending -> fall through to run/walk (the model has NO fall clip, and idle-in-air floats too).
	air_t = 0.0 if bool(motion.get("on_floor", true)) else air_t + delta
	if air_t > 0.12 and float(motion.get("vy", 0.0)) > 0.5:
		play("jump")
		return
	var spd := float(motion.get("speed", 0.0))
	if spd > 3.0:
		play("run")
	elif spd > 0.3:
		play("walk")
	else:
		play("idle")


## Play a one-shot ACTION / emote clip (dance, wave, cheer, sit, taunt, …) then auto-return
## to locomotion after `hold` seconds. `clip` is any clip NAME on the rig OR a semantic key
## resolve() understands. This is the hook that lets the game give the character ALL types of
## animations beyond the built-in idle/walk/run/jump/attack set — call it on any event.
func action(clip: String, hold := 1.2) -> void:
	if ap == null or not is_instance_valid(ap):
		return
	var resolved := resolve(clip)
	if resolved == "" and ap.has_animation(clip):
		resolved = clip
	if resolved == "":
		return
	attack_t = hold   # reuse the "don't override locomotion" gate for the action's duration
	anim = "action"
	ap.play(resolved, 0.15)
