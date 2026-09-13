class_name GEquip
## WEAPON EQUIP (Wave 4) — attach/detach ONE weapon visual on any character, rigged OR capsule.
##
##   GEquip.equip(character, weapon_def, model=null) -> Node3D  the attached weapon visual root
##   GEquip.unequip(character)                                  removes it (idempotent)
##   GEquip.equipped_def(character) -> Dictionary               the def stored at equip ({} = none)
##   GEquip.tip(character) -> Vector3                           world-space muzzle/blade tip (fire origin)
##   GEquip.slot(character) -> Node3D                           the "GEquipSlot" node (swing anims may target it)
##   GEquip.fire_gate(character) -> bool                        per-weapon cooldown gate: true = fire NOW (stamps)
##   GEquip.stat(def, "damage"|"rate"|"range"|"speed") -> float schema defaults 1 / 1.2 / 20 / 22
##   GEquip.arc_of(def) -> bool                                 projectile "arc" default: kind == "thrown"
##   GEquip.better(candidate, current) -> bool                  pickup auto-equip rule (strictly more damage)
##
## `weapon_def` is one merged entry of world.json "weapons" (which MERGES OVER rpg_systems'
## inline ITEMS — main builds the merged Dictionary; this module only consumes it):
##   {"name", "kind": "melee"|"ranged"|"thrown", "damage", "rate", "range",
##    "projectile": {"speed", "arc"}, "model": "parametric:sword|bow|rifle|staff" | <lib/R2 path>}
## `model` = a pre-fetched, already-duplicated Node3D for library/Meshy weapon paths (the caller
## resolves it via the builder cache); null -> a parametric build ("parametric:<kind>", or a
## per-kind default when "model" is missing/unfetched: ranged -> bow, everything else -> sword).
##
## WEAPON LOCAL FRAME (every parametric builder + the tip contract): the GRIP sits at the weapon
## root's local ORIGIN; the business axis (blade length / bow aim / rifle barrel / staff shaft to
## orb) runs along local +Z with the muzzle/tip at +Z*L (stored as meta "gequip_tip"); local +Y is
## the weapon's up (a bow's limbs span ±Y). Library models keep their authored axes — they are only
## scale-normalized (longest dimension ~1.1 m, ~1.6 m when the model path names a staff).
##
## ATTACHMENT (one slot, always named "GEquipSlot"):
##  - grip locator (highest priority): a Node3D OR bone named "GripMarker"/"grip" anywhere in
##    the character -> attach there VERBATIM (identity rotation, zero offset) — the Rig Lab /
##    Meshy pipeline may bake one; a baked marker always beats the heuristics below.
##  - rigged: a BoneAttachment3D on the skeleton's hand bone — substring resolution GPose-style
##    (handslot > palm > hand > wrist, right side preferred; twist/roll/finger bones skipped).
##    The weapon's grip transform inside the slot is PER RIG FAMILY (_rig_family):
##      * kaykit (any bone named *handslot*; resolves handslot.r): rotated -90° about X, zero
##        offset — probed on kk_rig_medium_general.glb via a bare-godot GLTFDocument dump:
##        handslot.r's rest basis is X=(-1,0,0) (out along the arm), Y=(0,0,1) (MODEL FORWARD),
##        Z=(0,1,0) (up), so bone +Y is exactly the "weapon points where the character faces"
##        axis, and it stays forward as the arm hangs at idle. This path is UNCHANGED/calibrated.
##      * mixamo (mixamorig* prefix OR the bare Mixamo set RightHand/LeftHand/ForeArm — Meshy
##        rigs ship the latter) / generic: these rigs have NO handslot — the resolved hand/wrist
##        bone's ORIGIN is the wrist JOINT, so a bare attach floats the weapon at the forearm.
##        The weapon is (a) pushed MIXAMO_PALM_OFF (~9 cm) into the palm along the toward-the-
##        fingers direction and (b) rotated so weapon +Z lies along that palm-forward direction
##        (_palm_grip_xform). The finger direction comes from a real finger bone when one exists,
##        else from the arm-continuation (parent->hand) rest vector — probed on this build's
##        Meshy hero.glb: hand-local (0.049, 0.998, 0.037) on BOTH hands, i.e. ~bone +Y (NOT the
##        classic Mixamo +X folklore), which FALLBACK_FINGER_AXIS documents. Both offset and
##        basis are divided by the character->skeleton accumulated scale so they are true metres
##        in world space — Meshy GLBs carry a 0.01 Armature node (cm skeleton), where an
##        uncompensated attach renders TARGET_LEN swords at ~1 cm.
##  - capsule (no skeleton / no hand bone resolves): a plain Node3D child of the character at
##    (0.45, 1.0, -0.3) — the old hardcoded-sword spot — identity rotation, so weapon +Z points
##    along the character's facing (+Z stack convention).
## Idempotent, ONE weapon at a time: equip() unequips first. The def is stored on the character
## meta "gequip_def" (main reads firing stats from it); the cooldown stamp lives in
## "gequip_next_ms". Detachment-safe: equip() never reads global_transform (the scale-normalize
## AABB is accumulated manually, mirroring GShapes._aabb); only tip() needs the tree, and it
## degrades to the character origin +1 m when detached.

const META_DEF := "gequip_def"
const META_NEXT := "gequip_next_ms"
const META_TIP := "gequip_tip"
const META_GRIP := "gequip_grip"                   # slot meta: rig family the grip was calibrated for
const META_GRIP_XFORM := "gequip_grip_xform"       # slot meta: precomputed weapon local Transform3D (non-kaykit)
const SLOT_NAME := "GEquipSlot"
const CAPSULE_OFFSET := Vector3(0.45, 1.0, -0.3)   # the old hardcoded-sword spot (right hip/hand height)
const BONE_ROT_X_DEG := -90.0                      # weapon +Z -> bone +Y (probed: KayKit handslot.r +Y = forward)
const TARGET_LEN := 1.1                            # hand-size normalize: sword/bow/rifle longest dim (m)
const TARGET_LEN_STAFF := 1.6

# Rig families (_rig_family) + the marker/capsule pseudo-families stamped on the slot's META_GRIP
const RIG_KAYKIT := "kaykit"
const RIG_MIXAMO := "mixamo"
const RIG_GENERIC := "generic"
const RIG_MARKER := "marker"

# Palm calibration tunables (mixamo/generic rigs — hand/wrist bones whose origin is the wrist
# JOINT). All are in the hand bone's LOCAL rest frame; future rig families adjust HERE.
const MIXAMO_PALM_OFF := 0.09                      # m (world) wrist -> palm push toward the fingers
const FALLBACK_FINGER_AXIS := Vector3(0, 1, 0)     # probed hero.glb: arm-continuation ~ (0.05, 0.998, 0.04) both hands
const GRIP_UP_HINT := Vector3(0, 0, -1)            # reproduces the KayKit rot_x(-90) mapping when fingers ~ +Y

# Schema defaults (the pinned Wave-4 weapon contract: every field except name/kind is optional)
const DEFAULTS := {"damage": 1.0, "rate": 1.2, "range": 20.0, "speed": 22.0}


## Attach `weapon_def` to `character` (removing any previous weapon first). `model` = pre-fetched
## duplicated Node3D for library weapons, null -> parametric. Returns the weapon visual root
## (a Node3D named "GEquipWeapon" carrying meta "gequip_tip"), or null on a bad character.
static func equip(character: Node3D, weapon_def: Dictionary, model: Node3D = null) -> Node3D:
	if character == null or not is_instance_valid(character):
		return null
	unequip(character)
	var weapon := _build_visual(weapon_def, model)
	var slot_node := _make_slot(character)
	if slot_node.has_meta(META_GRIP_XFORM):
		weapon.transform = slot_node.get_meta(META_GRIP_XFORM)   # palm / grip-marker calibration (basis +/- scale)
	elif slot_node is BoneAttachment3D and String(slot_node.get_meta(META_GRIP, RIG_KAYKIT)) == RIG_KAYKIT:
		weapon.rotation_degrees.x = BONE_ROT_X_DEG   # lay the +Z business axis along the bone's +Y
	slot_node.add_child(weapon)
	character.set_meta(META_DEF, weapon_def)
	return weapon


## Remove the equipped weapon (slot + visual) and its meta. Idempotent; same-frame safe (the
## dying slot is renamed before queue_free so an immediate re-equip can't find it again).
static func unequip(character: Node3D) -> void:
	if character == null or not is_instance_valid(character):
		return
	while true:
		var old := character.find_child(SLOT_NAME, true, false)
		if old == null:
			break
		old.name = SLOT_NAME + "Gone"
		old.queue_free()
	if character.has_meta(META_DEF):
		character.remove_meta(META_DEF)
	if character.has_meta(META_NEXT):
		character.remove_meta(META_NEXT)


## The weapon def stored at equip time ({} when nothing is equipped). Main reads firing stats here.
static func equipped_def(character: Node3D) -> Dictionary:
	if character == null or not is_instance_valid(character):
		return {}
	var d = character.get_meta(META_DEF, {})
	return d if d is Dictionary else {}


## The live "GEquipSlot" node (BoneAttachment3D or the capsule offset Node3D); null = unequipped.
static func slot(character: Node3D) -> Node3D:
	if character == null or not is_instance_valid(character):
		return null
	var s := character.find_child(SLOT_NAME, true, false)
	return s as Node3D


## World-space muzzle/blade tip — the projectile + muzzle-flash origin. Falls back to the
## character origin +1 m (chest height) when unequipped or detached from the tree.
static func tip(character: Node3D) -> Vector3:
	var s := slot(character)
	if s != null and s.is_inside_tree() and s.get_child_count() > 0:
		var weapon := s.get_child(0) as Node3D
		if weapon != null:
			var local: Vector3 = weapon.get_meta(META_TIP, Vector3(0.0, 0.0, 0.5))
			return weapon.global_transform * local
	if character != null and is_instance_valid(character) and character.is_inside_tree():
		return character.global_position + Vector3(0.0, 1.0, 0.0)
	return Vector3.ZERO


## Per-weapon fire-rate gate: true = a shot may fire NOW (and the next-allowed time is stamped
## from the equipped def's "rate" in shots/sec). Rapid re-taps inside the cooldown return false.
static func fire_gate(character: Node3D) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	var now := Time.get_ticks_msec()
	if now < int(character.get_meta(META_NEXT, 0)):
		return false
	var rate := stat(equipped_def(character), "rate")
	character.set_meta(META_NEXT, now + int(1000.0 / maxf(0.1, rate)))
	return true


## A numeric weapon stat with the pinned schema default (damage 1, rate 1.2, range 20, speed 22).
## "speed" resolves from the nested "projectile" block first, then top level, then the default.
static func stat(def: Dictionary, key: String) -> float:
	if key == "speed":
		var p = def.get("projectile", null)
		if p is Dictionary and (p as Dictionary).has("speed"):
			return float(p["speed"])
	if def.has(key):
		return float(def[key])
	return float(DEFAULTS.get(key, 0.0))


## Projectile "arc" (ballistic drop) with the pinned default: true only for kind "thrown".
static func arc_of(def: Dictionary) -> bool:
	var p = def.get("projectile", null)
	if p is Dictionary and (p as Dictionary).has("arc"):
		return bool(p["arc"])
	return String(def.get("kind", "")) == "thrown"


## The chest-pickup auto-equip rule: swap only when the candidate's damage STRICTLY exceeds the
## currently equipped weapon's.
static func better(candidate: Dictionary, current: Dictionary) -> bool:
	return stat(candidate, "damage") > stat(current, "damage")


# ─────────────────────────────── slot creation ───────────────────────────────

# Grip locator NODE -> verbatim Node3D slot; rigged -> BoneAttachment3D on the grip locator
# BONE or the resolved hand bone (grip transform precomputed per rig family and stamped on the
# slot's meta — equip() applies it); capsule -> fixed offset Node3D. All named "GEquipSlot" so
# unequip()/slot()/tip() have ONE lookup path.
static func _make_slot(character: Node3D) -> Node3D:
	var marker := _grip_marker_node(character)
	if marker != null and marker != character:
		var m := Node3D.new()
		m.name = SLOT_NAME
		marker.add_child(m)                          # verbatim: identity local transform
		m.set_meta(META_GRIP, RIG_MARKER)
		# SCALE COMPENSATION: the marker lives UNDER the rig's Armature (Meshy: ~0.01 scale over cm-unit
		# bones), so a real-metre weapon parented here inherits ~0.01x and renders ~100x too small
		# ("floats"/invisible at the wrist). Undo the accumulated chain scale (same _chain_scale the palm
		# path uses) so the weapon is true size, keeping the marker's authored position/orientation.
		var inv := 1.0 / _chain_scale(character, marker)
		m.scale = Vector3(inv, inv, inv)
		# ORIENTATION: the GripMarker is baked POSITION-only (identity rotation), so a verbatim attach lays
		# the weapon's +Z (blade tip / barrel / aim) along the raw hand-bone axis (~90deg off) and the swing
		# reads BACKWARD. Stamp the same finger-forward grip basis the palm path uses onto the WEAPON (via
		# META_GRIP_XFORM, applied in equip()) — NOT the slot m, which main.gd re-writes each frame for melee.
		var mk_skel := _find_skeleton(character)
		var mk_bi := _hand_bone(mk_skel) if mk_skel != null else -1
		if mk_bi >= 0:
			m.set_meta(META_GRIP_XFORM, Transform3D(_grip_basis(_finger_dir(mk_skel, mk_bi)), Vector3.ZERO))
		return m
	var skel := _find_skeleton(character)
	if skel != null:
		var gi := _grip_marker_bone(skel)
		var bi := gi if gi >= 0 else _hand_bone(skel)
		if bi >= 0:
			var ba := BoneAttachment3D.new()
			ba.name = SLOT_NAME
			skel.add_child(ba)                       # parent FIRST: bone_name resolves via the parent skeleton
			ba.bone_name = skel.get_bone_name(bi)
			var fam := RIG_MARKER if gi >= 0 else _rig_family(skel)
			ba.set_meta(META_GRIP, fam)
			if fam == RIG_MIXAMO or fam == RIG_GENERIC:
				ba.set_meta(META_GRIP_XFORM, _palm_grip_xform(character, skel, bi))
			elif fam == RIG_MARKER:
				# a grip locator BONE — like a node marker, baked position-only, so also needs the
				# finger-forward grip basis (weapon +Z along the fingers, not the raw bone axis) PLUS the
				# ~100x scale compensation. equip() applies META_GRIP_XFORM for BoneAttachment slots.
				var invb := 1.0 / _chain_scale(character, skel)
				ba.set_meta(META_GRIP_XFORM, Transform3D(_grip_basis(_finger_dir(skel, bi)).scaled(Vector3(invb, invb, invb)), Vector3.ZERO))
			return ba
	var off := Node3D.new()
	off.name = SLOT_NAME
	character.add_child(off)
	off.position = CAPSULE_OFFSET
	return off


# Optional baked grip locator: a Node3D named "GripMarker"/"grip" anywhere under the character
# (exact name, case-insensitive — substring matching would false-positive on e.g. "grip_tape").
static func _grip_marker_node(n: Node) -> Node3D:
	var nl := String(n.name).to_lower()
	if n is Node3D and (nl == "gripmarker" or nl == "grip"):
		return n as Node3D
	for c in n.get_children():
		var r := _grip_marker_node(c)
		if r != null:
			return r
	return null


# Same locator as a BONE ("GripMarker"/"grip") — the Rig Lab / Meshy pipeline may bake one.
static func _grip_marker_bone(skel: Skeleton3D) -> int:
	for i in skel.get_bone_count():
		var bn := skel.get_bone_name(i).to_lower()
		if bn == "gripmarker" or bn == "grip":
			return i
	return -1


# Rig family the grip calibration is keyed on. kaykit = any *handslot* bone (the probed -90°
# contract); mixamo = mixamorig* prefix OR the bare Mixamo bone set (Meshy rigs ship
# RightHand/LeftHand/ForeArm with no prefix); everything else = generic (same palm calibration
# as mixamo — the finger-vector derivation is rig-agnostic).
static func _rig_family(skel: Skeleton3D) -> String:
	var mixamo := false
	for i in skel.get_bone_count():
		var bn := skel.get_bone_name(i).to_lower()
		if "handslot" in bn:
			return RIG_KAYKIT
		if bn.begins_with("mixamorig") or bn in ["righthand", "lefthand", "rightforearm", "leftforearm"]:
			mixamo = true
	return RIG_MIXAMO if mixamo else RIG_GENERIC


# Palm calibration for wrist-origined rigs: the weapon's local transform inside the slot.
# (a) origin pushed MIXAMO_PALM_OFF toward the fingers (a hand/wrist bone's origin is the wrist
# JOINT — a zero-offset attach floats the weapon at the forearm); (b) basis maps weapon +Z (the
# business axis) onto the palm-forward finger direction, GRIP_UP_HINT keeping the same up as the
# probed KayKit mapping. Both are divided by the character->skeleton accumulated scale: Meshy
# GLBs carry a 0.01-scale Armature node (cm-unit skeleton, probed on hero.glb), where an
# uncompensated offset is ~1 mm and TARGET_LEN weapons render at ~1 cm.
static func _palm_grip_xform(character: Node3D, skel: Skeleton3D, bi: int) -> Transform3D:
	var fdir := _finger_dir(skel, bi)
	var inv := 1.0 / _chain_scale(character, skel)
	return Transform3D(_grip_basis(fdir) * inv, fdir * (MIXAMO_PALM_OFF * inv))


# Toward-the-fingers direction in the hand bone's LOCAL rest frame:
#  1) a real finger bone's rest origin (middle > index > any non-thumb child) when one exists;
#  2) else the arm-continuation (parent->hand) rest vector expressed hand-locally — probed on
#     hero.glb (Meshy, NO finger bones): (0.049, 0.998, 0.037) on both hands;
#  3) else (orphan hand bone) FALLBACK_FINGER_AXIS (+Y — matches both probes above; the classic
#     "Mixamo hands point +X" folklore did NOT hold on the probed rigs).
static func _finger_dir(skel: Skeleton3D, bi: int) -> Vector3:
	var best := -1
	var best_rank := 0
	for c in skel.get_bone_children(bi):
		var cn := skel.get_bone_name(c).to_lower()
		if "thumb" in cn:
			continue
		var rank := 1
		if "middle" in cn:
			rank = 3
		elif "index" in cn:
			rank = 2
		if rank > best_rank:
			best_rank = rank
			best = c
	if best >= 0:
		var fo := skel.get_bone_rest(best).origin
		if fo.length() > 0.0001:
			return fo.normalized()
	var p := skel.get_bone_parent(bi)
	if p >= 0:
		var gh := skel.get_bone_global_rest(bi)
		var gp := skel.get_bone_global_rest(p)
		var d := gh.basis.inverse() * (gh.origin - gp.origin)
		if d.length() > 0.0001:
			return d.normalized()
	return FALLBACK_FINGER_AXIS


# Orthonormal basis with +Z = `z` (the palm-forward business axis). With fingers ~ bone +Y and
# GRIP_UP_HINT (0,0,-1) this reproduces the probed KayKit rot_x(-90) mapping exactly; the hint
# swaps to +Y for the rare rig whose fingers run along ±Z (degenerate cross otherwise).
static func _grip_basis(z: Vector3) -> Basis:
	var zn := z.normalized()
	var hint := GRIP_UP_HINT if absf(zn.dot(GRIP_UP_HINT)) < 0.9 else Vector3(0, 1, 0)
	var x := hint.cross(zn).normalized()
	return Basis(x, zn.cross(x), zn)


# Accumulated LOCAL scale from the skeleton up to (excluding) the character root — everything a
# slot child inherits on top of the character. Detachment-safe (node transforms only, never
# global_transform); average of the 3 axes (Meshy's Armature 0.01 is uniform).
static func _chain_scale(character: Node3D, skel: Node) -> float:
	var s := 1.0
	var n: Node = skel
	while n != null and n != character:
		if n is Node3D:
			var sc := (n as Node3D).scale
			s *= (absf(sc.x) + absf(sc.y) + absf(sc.z)) / 3.0
		n = n.get_parent()
	return maxf(s, 0.0001)


# Hand-bone resolution, GPose-style substring matching. Preference: handslot > palm/claw >
# hand/fist > wrist, +right-side bonus (smaller than the type gap, so handslot.l still beats hand.r).
# claw/fist widen the net for ALIEN/creature rigs (a Predator-type alien grips with a claw, not a
# named "hand"), so a weapon lands on the hand instead of the hip-float fallback. Twist/roll helpers
# and finger bones (Mixamo RightHandIndex1...) are skipped. (A baked GripMarker still wins over all
# of this — see _grip_marker_bone/_grip_marker_node — so the asset pipeline can pin the grip exactly.)
static func _hand_bone(skel: Skeleton3D) -> int:
	var best := -1
	var best_score := 0
	for i in skel.get_bone_count():
		var bn := skel.get_bone_name(i).to_lower()
		if "twist" in bn or "roll" in bn or "handle" in bn:
			continue
		var skip := false
		for finger in ["index", "thumb", "middle", "ring", "pinky", "finger"]:
			if finger in bn:
				skip = true
				break
		if skip:
			continue
		var score := 0
		if "handslot" in bn:
			score = 40
		elif "palm" in bn or "claw" in bn:
			score = 30
		elif "hand" in bn or "fist" in bn:
			score = 20
		elif "wrist" in bn:
			score = 10
		if score == 0:
			continue
		if bn.ends_with(".r") or bn.ends_with("_r") or "right" in bn:
			score += 5
		if score > best_score:
			best_score = score
			best = i
	return best


static func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


# ─────────────────────────────── weapon visuals ───────────────────────────────

# The weapon visual root. Library model -> wrap + scale-normalize + best-effort tip (the +Z
# extreme of its AABB). No/parametric model -> the vetted parametric builders below.
static func _build_visual(def: Dictionary, model: Node3D) -> Node3D:
	var root := Node3D.new()
	root.name = "GEquipWeapon"
	if model != null and is_instance_valid(model):
		root.add_child(model)
		var ab := _aabb(root)
		var longest := maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
		if longest > 0.01:
			model.scale = model.scale * (_target_len(def) / longest)
			ab = _aabb(root)
		var c := ab.get_center()
		root.set_meta(META_TIP, Vector3(c.x, c.y, ab.end.z))
		return root
	var pkind := String(def.get("model", ""))
	if pkind.begins_with("parametric:"):
		pkind = pkind.substr(11).to_lower()
	else:
		# missing model OR an unfetched library path -> a sane parametric default per kind
		pkind = "bow" if String(def.get("kind", "")) == "ranged" else "sword"
	match pkind:
		"bow":
			_bow(root)
		"rifle":
			_rifle(root)
		"staff":
			_staff(root)
		_:
			_sword(root)
	return root


static func _target_len(def: Dictionary) -> float:
	return TARGET_LEN_STAFF if "staff" in String(def.get("model", "")).to_lower() else TARGET_LEN


# Sword (the existing box-blade proportions, re-based to the Wave-4 frame): wood grip in the
# fist, metal pommel/crossguard/blade along +Z. Tip at z=0.96 (total ~1.1 m).
static func _sword(root: Node3D) -> void:
	var wood := GSurf.surface("wood")
	var metal := GSurf.surface("metal")
	root.add_child(_box(Vector3(0.075, 0.075, 0.26), Vector3.ZERO, wood))              # grip
	root.add_child(_box(Vector3(0.09, 0.09, 0.05), Vector3(0.0, 0.0, -0.155), metal))  # pommel
	root.add_child(_box(Vector3(0.30, 0.05, 0.05), Vector3(0.0, 0.0, 0.155), metal))   # crossguard
	root.add_child(_box(Vector3(0.10, 0.028, 0.78), Vector3(0.0, 0.0, 0.57), metal))   # blade
	root.set_meta(META_TIP, Vector3(0.0, 0.0, 0.96))


# Bow: riser + two limbs swept BACK (-Z, toward the archer) + a string box spanning the limb
# tips — 3 thin boxes in a C + the chord. Aim = +Z past the riser; limbs span ±Y (~1.2 m).
static func _bow(root: Node3D) -> void:
	var timber := GSurf.surface("timber")
	var string_mat := GSurf.surface({"color": [0.92, 0.92, 0.85], "rough": 0.6, "metal": 0.0, "bump": 0.0, "tile": 1.0})
	root.add_child(_box(Vector3(0.05, 0.44, 0.075), Vector3.ZERO, timber))             # riser (grip)
	var upper := _box(Vector3(0.04, 0.44, 0.04), Vector3(0.0, 0.40, -0.075), timber)
	upper.rotation_degrees.x = -20.0                                                   # tip sweeps back
	root.add_child(upper)
	var lower := _box(Vector3(0.04, 0.44, 0.04), Vector3(0.0, -0.40, -0.075), timber)
	lower.rotation_degrees.x = 20.0
	root.add_child(lower)
	root.add_child(_box(Vector3(0.015, 1.12, 0.015), Vector3(0.0, 0.0, -0.15), string_mat))
	root.set_meta(META_TIP, Vector3(0.0, 0.0, 0.15))                                   # arrow rest, past the riser


# Rifle: wood stock + steel receiver (2 boxes) + a metal barrel cylinder along +Z. Muzzle at
# z=0.74 (total ~1.1 m).
static func _rifle(root: Node3D) -> void:
	root.add_child(_box(Vector3(0.06, 0.15, 0.30), Vector3(0.0, -0.02, -0.22), GSurf.surface("wood")))
	root.add_child(_box(Vector3(0.07, 0.11, 0.42), Vector3(0.0, 0.02, 0.12), GSurf.surface("steel")))
	var barrel := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.024
	cyl.bottom_radius = 0.024
	cyl.height = 0.42
	cyl.radial_segments = 10
	barrel.mesh = cyl
	barrel.rotation_degrees.x = 90.0                 # cylinder axis (Y) -> +Z
	barrel.position = Vector3(0.0, 0.045, 0.53)
	barrel.material_override = GSurf.surface("metal")
	root.add_child(barrel)
	root.set_meta(META_TIP, Vector3(0.0, 0.045, 0.74))


# Staff: a long thin timber cylinder along +Z + an emissive orb at the head. Orb at z=1.16
# (total ~1.6 m — held about a third up the shaft).
static func _staff(root: Node3D) -> void:
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.035
	cyl.height = 1.5
	cyl.radial_segments = 8
	shaft.mesh = cyl
	shaft.rotation_degrees.x = 90.0
	shaft.position = Vector3(0.0, 0.0, 0.35)         # shaft spans z -0.4 .. 1.1, grip at the origin
	shaft.material_override = GSurf.surface("timber")
	root.add_child(shaft)
	var orb := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.09
	sph.height = 0.18
	sph.radial_segments = 12
	sph.rings = 6
	orb.mesh = sph
	orb.position = Vector3(0.0, 0.0, 1.16)
	orb.material_override = GSurf.emissive(Color(0.55, 0.8, 1.0), 2.5)
	root.add_child(orb)
	root.set_meta(META_TIP, Vector3(0.0, 0.0, 1.16))


# A centred box mesh at `at` (weapon parts are placed by centre in the grip frame — unlike
# GShapes' base-at-y0 building contract).
static func _box(size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = at
	mi.material_override = mat
	return mi


# DETACHMENT-SAFE local-space AABB (mirrors GShapes._aabb): transforms are accumulated manually
# because the weapon is measured BEFORE it is attached, where global_transform is IDENTITY + an
# error line.
static func _aabb(node: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [[node, node.transform]]
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
