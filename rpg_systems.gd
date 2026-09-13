class_name RpgState extends Node
## RPG DATA SYSTEMS (state + progression + inventory). The single serialized state blob +
## the item catalog. Pure data — no engine risk. The item catalog is inline here; for a
## large game it can become items.json streamed from R2 alongside world.json.
##
## WAVE 4 — WEAPONS CATALOG: world.json may carry a top-level "weapons" dict
## ({"<id>": {name, kind: melee|ranged|thrown, damage, rate, range, projectile:{speed, arc},
## model}}). main hands it over at boot (and hot-reload) via load_weapons(); entries MERGE
## OVER the inline ITEMS by id, world winning PER-FIELD — a world can re-stat rusty_sword's
## damage without redefining its name. weapon_def(id) returns the NORMALIZED def with the
## pinned defaults (damage 1, rate 1.2, range 20, speed 22, arc true for thrown).

signal changed   ## HUD listens; emitted on any state change

## Inventory movement, for the rule layer's `collect` / `use_item` events. Emitted from add_item /
## consume_item rather than from each caller, so EVERY route reports: a chest, a quest reward, a
## rule's own `grant`, the potion button. A hook per call site is a hook someone forgets to add to
## the next call site, and the resulting event is silent — which is the failure this pass exists
## to remove. main connects these; nothing fires before the director is built.
signal item_added(id: String, qty: int)
signal item_used(id: String)

const ITEMS := {
	"rusty_sword": {"name": "Rusty Sword", "type": "weapon", "damage": 25},
	"steel_sword": {"name": "Steel Sword", "type": "weapon", "damage": 55},
	"iron_key":    {"name": "Iron Key", "type": "key"},
	"vault_key":   {"name": "Vault Key", "type": "key"},
	"potion":      {"name": "Health Potion", "type": "consumable", "heal": 50},
}

# Pinned Wave-4 defaults for a normalized weapon def (world "weapons" schema).
const WPN_DEFAULT_DAMAGE := 1.0
const WPN_DEFAULT_RATE := 1.2     # shots per second — the fire cooldown is 1.0 / rate
const WPN_DEFAULT_RANGE := 20.0
const WPN_DEFAULT_SPEED := 22.0   # projectile speed (u/s)

var weapons := {}   # id -> NORMALIZED weapon def (inline ITEMS weapons + world "weapons" merged)

# --- the state blob ---
var hp := 100.0
var max_hp := 100.0
var level := 1
var xp := 0
var xp_next := 30
var gold := 0
var inventory: Array = ["rusty_sword"]
var equipped_weapon := "rusty_sword"
var flags := {}                 # quest/world flags (e.g. dungeon_cleared) — gate seams


func _ready() -> void:
	if weapons.is_empty():
		load_weapons({})   # seed from the inline ITEMS so weapon_def works before world.json lands


# ---------------- weapons catalog (Wave 4) ----------------

## world.json top-level "weapons" — main hands it over at boot AND on hot-reload. World
## entries MERGE OVER the inline ITEMS by id, world wins PER-FIELD (base fields it omits
## survive). Every stored def is normalized up front so readers never re-default.
func load_weapons(dict: Dictionary) -> void:
	weapons = {}
	for id in ITEMS:
		if String(ITEMS[id].get("type", "")) == "weapon":
			weapons[String(id)] = _normalize_weapon(String(id), ITEMS[id], {})
	for id in dict:
		if not (dict[id] is Dictionary):
			continue
		weapons[String(id)] = _normalize_weapon(String(id), ITEMS.get(id, {}), dict[id])
	changed.emit()


## Register `id` as a weapon if no catalog declares it, so `item_type()` reports "weapon" and the
## equip door opens. Without this a rule's `give_weapon` on an undeclared id put the item in the
## inventory and then refused to equip it — the player carried an invisible sword.
func ensure_weapon(id: String) -> void:
	if id == "" or weapons.has(id):
		return
	weapons[id] = _normalize_weapon(id, ITEMS.get(id, {}), {})
	changed.emit()


## The NORMALIZED def for any weapon id (pinned Wave-4 defaults). Ids in neither catalog
## still normalize (a plain melee sword) so callers never branch on a missing dict.
func weapon_def(id: String) -> Dictionary:
	if weapons.has(id):
		return weapons[id]
	return _normalize_weapon(id, ITEMS.get(id, {}), {})


# Per-field merge: `over` (world) beats `base` (inline ITEMS) beats the pinned default.
# The default model is parametric per kind — GEquip needs no fetch for those.
func _normalize_weapon(id: String, base: Dictionary, over: Dictionary) -> Dictionary:
	var pb: Dictionary = base.get("projectile") if base.get("projectile") is Dictionary else {}
	var po: Dictionary = over.get("projectile") if over.get("projectile") is Dictionary else {}
	var kind := String(over.get("kind", base.get("kind", "melee")))
	var def_model := "parametric:bow" if kind == "ranged" else "parametric:sword"
	return {
		"id": id,
		"name": String(over.get("name", base.get("name", id.capitalize()))),
		"kind": kind,
		"damage": float(over.get("damage", base.get("damage", WPN_DEFAULT_DAMAGE))),
		"rate": float(over.get("rate", base.get("rate", WPN_DEFAULT_RATE))),
		"range": float(over.get("range", base.get("range", WPN_DEFAULT_RANGE))),
		"projectile": {
			"speed": float(po.get("speed", pb.get("speed", WPN_DEFAULT_SPEED))),
			"arc": bool(po.get("arc", pb.get("arc", kind == "thrown"))),
		},
		"model": String(over.get("model", base.get("model", def_model))),
	}


# ---------------- flags ----------------

func set_flag(f: String) -> void:
	if not flags.get(f, false):
		flags[f] = true
		changed.emit()


func has_flag(f: String) -> bool:
	return flags.get(f, false)


# ---------------- progression ----------------

func grant_xp(n: int) -> void:
	xp += n
	while xp >= xp_next:
		xp -= xp_next
		_level_up()
	changed.emit()


func _level_up() -> void:
	level += 1
	max_hp += 20.0
	hp = max_hp                       # full heal on level up
	xp_next = int(xp_next * 1.4)


func take_damage(d: float) -> bool:
	hp = max(0.0, hp - d)
	changed.emit()
	return hp <= 0.0                  # true = dead


# ---------------- inventory ----------------

func add_item(id: String, qty := 1) -> void:
	for _i in range(qty):
		inventory.append(id)
	changed.emit()
	item_added.emit(id, qty)


func has_item(id: String) -> bool:
	return id in inventory


func consume_item(id: String) -> bool:
	if id in inventory:
		inventory.erase(id)
		changed.emit()
		item_used.emit(id)
		return true
	return false


## How many of `id` the player holds. The inventory is a flat Array with one entry per unit, so a
## count is a scan — callers (the `item_count` condition, `set_count`) must not reimplement it.
func item_count(id: String) -> int:
	var n := 0
	for e in inventory:
		if String(e) == id:
			n += 1
	return n


## Force the held quantity of `id` to exactly `n`. Adds or removes the difference through the normal
## doors, so `collect` / `use_item` still report — a silent inventory edit would leave a rule that
## watches for the item waiting forever.
func set_item_count(id: String, n: int) -> void:
	if id == "":
		return
	n = maxi(0, n)
	var have := item_count(id)
	if have < n:
		add_item(id, n - have)
	else:
		for _i in range(have - n):
			consume_item(id)


func clear_flag(f: String) -> void:
	if flags.get(f, false):
		flags.erase(f)
		changed.emit()


## Wave-4 auto-equip rule: a picked-up weapon only auto-equips when its damage EXCEEDS the
## current weapon's (interaction._open_chest calls this for every weapon a chest grants —
## unchanged there; the gate lives here, the ONE equip door). force=true (boot start_weapon
## / deliberate swaps) bypasses the gate.
func equip(id: String, force := false) -> bool:
	if id in inventory and item_type(id) == "weapon":
		if not force and equipped_weapon != "" and id != equipped_weapon:
			# gate on DPS (damage x rate), not raw per-hit damage — raw damage never let a fast
			# weapon (tommy gun: 15 dmg x 5/s = 75 DPS) replace a slow heavy one (machete: 26 x 1.6).
			var cd := weapon_def(equipped_weapon)
			var nd := weapon_def(id)
			var cur := float(cd.get("damage", WPN_DEFAULT_DAMAGE)) * float(cd.get("rate", WPN_DEFAULT_RATE))
			if float(nd.get("damage", WPN_DEFAULT_DAMAGE)) * float(nd.get("rate", WPN_DEFAULT_RATE)) <= cur:
				return false
		equipped_weapon = id
		changed.emit()
		return true
	return false


## Deliberate swap (the HUD WEAPON button): equip the NEXT owned weapon, force — the player's
## explicit choice always wins over the DPS gate.
## How many DISTINCT weapons are owned. The HUD uses this to hide the cycle button until cycling
## would actually do something.
func weapon_count() -> int:
	var owned: Array = []
	for id in inventory:
		var sid := String(id)
		if item_type(sid) == "weapon" and not owned.has(sid):
			owned.append(sid)
	return owned.size()


func cycle_weapon() -> bool:
	var owned: Array = []
	for id in inventory:
		var sid := String(id)
		if item_type(sid) == "weapon" and not owned.has(sid):
			owned.append(sid)
	if owned.is_empty():
		return false
	var i := owned.find(equipped_weapon)
	return equip(owned[(i + 1) % owned.size()], true)


func use_potion() -> bool:
	if has_item("potion"):
		consume_item("potion")
		hp = min(max_hp, hp + float(ITEMS["potion"]["heal"]))
		changed.emit()
		return true
	return false


func add_gold(n: int) -> void:
	gold += n
	changed.emit()


# ---------------- queries ----------------

func weapon_damage() -> float:
	return float(weapon_def(equipped_weapon).get("damage", WPN_DEFAULT_DAMAGE))


func item_name(id: String) -> String:
	if weapons.has(id):
		return String(weapons[id].get("name", id))   # merged catalog (world re-stats win)
	return ITEMS.get(id, {}).get("name", id)


func item_type(id: String) -> String:
	if ITEMS.has(id):
		return ITEMS[id].get("type", "")
	if weapons.has(id):
		return "weapon"   # world-only weapon id — chests can grant + auto-equip it
	return ""


func inventory_summary() -> String:
	var counts := {}
	for id in inventory:
		counts[id] = counts.get(id, 0) + 1
	var parts: Array = []
	for id in counts:
		var label := item_name(id)
		if id == equipped_weapon:
			label = "[" + label + "]"     # equipped marker
		if counts[id] > 1:
			label += " x%d" % counts[id]
		parts.append(label)
	return ", ".join(parts)
