class_name GCast
## CAST / KIT instancing — the "generate a small SET once, instance MANY varied" runtime (the deploy half of the
## Meshy content factory: the specialist GENERATES ~6-10 hero/character/prop variants up front, this turns them
## into a populated, VARIED world). Per-instance variation makes a handful read as a real crowd / herd / forest
## without N unique generations:
##   - a texture-PRESERVING recolor (modulate albedo, NEVER replace with a flat color — that's the "blocky blob"),
##   - a small ±scale and random yaw,
##   - a random ANIMATION seek-offset so a clip-looping crowd doesn't march in lockstep.
## Use it whenever you instance the same model many times (a Meshy cast across NPCs, a few rocks/trees scattered).


## Apply per-instance variation to a freshly-instanced model. Pass a seeded RandomNumberGenerator for determinism
## (e.g. seed from the instance index + a world seed) so the same crowd looks identical across reloads.
static func vary(model: Node3D, rng: RandomNumberGenerator, scale_amt := 0.1, tint_amt := 0.12) -> void:
	if model == null:
		return
	if scale_amt > 0.0:
		model.scale *= 1.0 + rng.randf_range(-scale_amt, scale_amt)
	model.rotation.y += rng.randf_range(0.0, TAU)
	if tint_amt > 0.0:
		# v capped at 0.85: recolor tints must never reach near-white (albedo ceiling — see surfaces.gd header)
		recolor(model, Color.from_hsv(rng.randf(), rng.randf_range(0.15, 0.45), rng.randf_range(0.65, 0.85)), tint_amt)
	# desync a looping animation so a crowd isn't in lockstep
	var ap := _anim(model)
	if ap != null and ap.current_animation != "":
		ap.seek(rng.randf_range(0.0, maxf(0.01, ap.current_animation_length)), true)


## Texture-PRESERVING recolor: duplicate each surface material and LERP its albedo toward `tint` by `amount`
## (modulates the texture; NEVER replaces it with a flat color — that deletes detail, the "characters are all
## blocks" failure — see art.md RECOLOR). For skin / clothing / faction / foliage variety. Keep `amount` small.
static func recolor(model: Node3D, tint: Color, amount := 0.2) -> void:
	if model == null:
		return
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for si in range(maxi(1, mi.mesh.get_surface_count())):
			var base: Material = mi.get_active_material(si)
			var m: StandardMaterial3D = (base.duplicate() if base != null else StandardMaterial3D.new()) as StandardMaterial3D
			if m == null:
				continue
			m.albedo_color = (m.albedo_color as Color).lerp(tint, clampf(amount, 0.0, 1.0))
			mi.set_surface_override_material(si, m)


## Pick one entry from a SET (a list of model urls) by rng — for "this NPC/prop is one of the cast".
static func pick(set: Array, rng: RandomNumberGenerator) -> String:
	if set.is_empty():
		return ""
	return String(set[rng.randi() % set.size()])


## A deterministic RNG seeded from an integer (instance index, cell hash, …) so variation is stable across reloads.
static func rng_for(seed_i: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_i
	return r


static func _anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _anim(c)
		if r != null:
			return r
	return null
