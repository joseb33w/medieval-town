extends Node
## ENGINE-SIDE multiplayer. The whole point: a networked game must stay DATA.
##
## WHY THIS EXISTS AT ALL
## Multiplayer used to be written by the GAME — spawn a remote avatar, key it by `from`,
## interpolate it, despawn it on a timeout. That is game-authored GDScript, which the data-only
## gate rejects and which the native player could not execute anyway (it runs the engine it ships
## with, not code that arrives with a world). So the engine owns all of it, and a world turns
## multiplayer on with data:
##
##     "multiplayer": {
##       "enabled": true,
##       "max_players": 4,
##       "supabase_url": "https://<ref>.supabase.co",
##       "supabase_anon_key": "<publishable anon key>"
##     }
##
## SYNCS POSITION, FACING, SHOTS AND HITS. Players are solid to each other and can fight. Still NOT
## synced, and stated so the limit is visible rather than discovered: inventory, animation state, and
## host-authoritative enemies or pickups — enemies are simulated per client, so co-op players each
## fight their own copy of a wave.
##
## Credentials live in the WORLD, not in this file. They are per-build data the agent already
## injects, the anon key is publishable and RLS-scoped, and keeping it out of the template means
## no credential ships in the engine, the repo, or the R2 template zip.

## The per-avatar animation state machine — the same one main.gd runs for the local hero.
const GHeroAnim = preload("res://hero_anim.gd")
## Vertical speed (m/s) above which a peer is treated as off the floor. Deliberately the same
## number as hero_anim's own jump test, so "airborne" and "rising enough to leap" agree.
const PEER_AIR_VY := 0.5

## 10Hz is plenty for walking characters and keeps the channel far under Supabase's message rate.
## Peer lifecycle, surfaced so the RULE LAYER can react to it ("wait for 2 players", "announce the
## shared score to a late joiner"). netsync owns peer bookkeeping; it should not also decide what a
## game does about it, so it just says what happened.
signal peer_joined(id: String)
signal peer_left(id: String)
## Fires once the room hands us our own id. main listens so the LOCAL body can be recoloured to the
## same identity-derived colour every other screen will draw it in — until this arrives we do not
## know who we are, and cannot possibly agree with anyone.
signal identified(id: String)
## PvP, surfaced for main to turn into gameplay. netsync stays TRANSPORT: it validates that a claim
## is credible and says so; it never touches health, never decides what dying means, and never knows
## the rule layer exists.
signal hit_taken(from_id: String, dmg: float)
signal killed(target_id: String)
## Another player fired. Carries only what it takes to DRAW the shot — the damage that shot may or
## may not do arrives separately as a validated `hit`, so a tracer can never be mistaken for one.
signal peer_shot(from_id: String, origin: Vector3, dir: Vector3, speed: float, rng: float)

## SEND RATE IS ADAPTIVE, and the fast band exists for shooting.
##
## A flat 10Hz was right when peers were scenery. Once anything AIMS at them, the packet interval
## is a floor on how wrong their rendered position can be, so movement gets 20Hz. Standing still
## gets 4Hz — LOWER than the old flat rate, because a stationary peer re-sending the same transform
## ten times a second is pure noise. A party where someone is idle now costs FEWER messages than
## before, not more, which is what buys the fast band its headroom.
const SEND_HZ_MOVING := 20.0
const SEND_HZ_IDLE := 4.0
## ...AND THE FAST BAND DOES NOT SURVIVE A CROWD. Every client broadcasts to every other, so inbound
## load per client is (N-1) x the send rate and the ROOM total is N x that — quadratic. 20Hz is right
## for a party of 8 (140 msg/s arriving); at 24 it is ~460/s at every phone, each parsed in GDScript,
## which is how "we made the world bigger and added more players" becomes a stutter nobody can trace.
## Interpolation is what makes stepping down affordable: peers render INTERP_DELAY behind, off a
## buffer that BRACKETS the render time, so a lower packet rate costs precision, not smoothness —
## the same trade the idle band above already makes.
const SEND_HZ_MID := 10.0      # 9-16 players
const SEND_HZ_CROWD := 6.0     # 17+
## Below these, "nothing happened" — don't spend a packet saying so. Yaw is separate because
## turning on the spot moves nothing but is exactly what a player about to shoot you does.
const MOVE_EPS := 0.05
const YAW_EPS := 0.05
## Two bands, because a browser peer that switches tabs STOPS ENTIRELY — Godot's main loop is
## requestAnimationFrame, which browsers pause for hidden tabs, so a tabbed-away player emits
## nothing at all. One short timeout would pop them out and back in every time they glance at
## another tab. Stale = stop interpolating (they are standing still, and they are). Despawn only
## once they are really gone. The native player has no such throttle.
const STALE_S := 10.0
const DESPAWN_S := 30.0
## Beyond this, a peer's new position is a teleport (or a rejoin after a drop), not motion — glide
## and they would ski across the map.
const SNAP_DIST := 8.0
## INTEREST RADIUS — how far away a peer still gets a BODY.
##
## Beyond it we keep the record and free the avatar. The record is the cheap half (a dict and a short
## transform buffer); the avatar is a full rigged character, re-skinned every frame it is visible, so
## 23 of them resident is several hundred thousand skinned triangles spent on specks. Keeping the
## record is NOT a detail: hit adjudication replays position history, peer_positions() feeds
## players_in_region and the minimap, and all of that must keep working for a peer you cannot see.
##
## The FLOOR exists so this never fires on an arena — a map smaller than the radius simply never
## culls, which is exactly the behaviour every game had before this existed.
const PEER_VISIBLE_MIN := 90.0
## Spawn at R, cull at R * this. Without the gap a peer hovering at exactly R spawns and despawns
## every frame — and spawning AWAITS a model fetch, so the thrash would be measured in downloads.
const PEER_VISIBLE_SLACK := 1.15

## HOW FAR BEHIND WE RENDER PEERS, and why a delay is the FIX rather than the problem.
##
## The old loop smoothed toward the newest position: `pos.lerp(target, 12 * delta)`. Exponential
## smoothing toward a target that keeps moving NEVER CATCHES UP — it has steady-state error. At
## 60fps that is ~67ms of lag from the smoothing alone, on top of a packet that is on average half
## a send-interval stale, on top of relay latency. Worse, the error scales with SPEED: a walking
## peer rendered a metre behind is a curiosity, a peer on a horse rendered five metres behind is
## unhittable. Nobody noticed because nothing depended on where a peer actually was.
##
## Rendering at `now - INTERP_DELAY` and interpolating between the two snapshots that BRACKET that
## time removes the steady-state error completely: a peer walking a straight line renders exactly
## ON their path, at a delay that is fixed and known instead of variable and speed-dependent. The
## delay is the buffer that makes the interpolation possible — it is chosen, not leftover.
const INTERP_DELAY := 0.10
const BUF_MAX := 32           # ~1.6s at the fast band; enough to ride out a stall, bounded so a
                              # peer that floods cannot grow our memory without limit
## CLOCK SYNC NEEDS A ROUND TRIP, and finding that out cost a rewrite of this constant.
##
## The obvious estimator is the minimum observed (arrival - their stamp). It is wrong in a way that
## measures clean: it cannot separate the clock offset from the one-way transit time, so every
## snapshot lands stamped at ARRIVAL instead of at SEND, and the render delay silently becomes
## INTERP_DELAY + latency. The harness caught it as a dead-constant 0.485m tracking error at 6 m/s
## — precisely the 80ms of simulated latency — which looked like an interpolation bug and was not.
##
## Worse than the latency, it is BIASED, and hit validation is built on both sides agreeing about
## when things happened. "I hit you at time T" has to land on the same instant in the target's own
## history, and an offset carrying a hidden +latency term does not.
##
## So: a ping/pong over the same broadcast channel. RTT is measured, one-way is taken as half of it,
## and the offset that comes out is a real clock offset. We keep the sample from the LOWEST RTT seen
## — least queuing, least error — and let it relax so a lucky early packet cannot pin it for the
## session. Until the first pong lands, the arrival-based estimate is a serviceable bootstrap.
const PING_EVERY := 2.0
const CLOCK_RELAX_PER_S := 0.002

## PVP IS SHOOTER-AUTHORITATIVE, AND THE TARGET GETS A VETO.
##
## The client who fired decides it connected and says so. There is no server to arbitrate, and the
## authoritative-server path does not exist — so the alternative to trusting the shooter is no PvP.
##
## What keeps that honest is that the TARGET checks the claim against its own position history. A hit
## names the instant it was aimed at and where the shooter believed you were; if you were nowhere
## near there at that moment, or the claim is older than any reasonable link, it is dropped. This is
## what a server does by rewinding, performed by the only party who actually knows the truth about
## itself. It bounds "shot me behind cover" and it refuses the crudest cheating outright — a client
## claiming hits from across the map is rejected by every target it names.
##
## It does NOT make this cheat-proof. A modified client can still lie inside the tolerance. Real
## anti-cheat needs the authoritative server, and this is honest about being the other thing.
const HIT_MAX_AGE := 0.40     # older than this and the link is too poor to adjudicate; drop it
const HIT_TOLERANCE := 2.5    # metres of disagreement allowed: HIT_RADIUS 0.9 + chest offset + interp error
const HIST_S := 1.0           # how much of our own past we keep, for the check above

var player: Node3D = null
## Provided by main: an async Callable returning a Node3D to use as a remote body, so this file
## never needs to know how models are fetched, normalized or seated.
var avatar_factory: Callable = Callable()
## OPTIONAL HOOKS from the game shell, same idea as avatar_factory: netsync owns the wire and
## the bodies, main owns the weapon catalog, the model cache and the player's own state. Kept
## as callables so this file never learns what a weapon def or a builder cache is.
##   "state" -> func() -> Dictionary   the LOCAL avatar state to broadcast {w, stw, sw}
##   "equip" -> func(avatar, id, stowed) -> void   put weapon `id` on a PEER's avatar
var _hook_state: Callable = Callable()
var _hook_equip: Callable = Callable()
##   "vehicle" -> func(index) -> Vehicle   resolve a world vehicle by its world.json order
var _hook_vehicle: Callable = Callable()

var enabled := false
var room := ""

var _net: Node = null
var _accum := 0.0
var _max_players := 8
## Resolved in configure() from the game's own weapon ranges — see the note there.
var _peer_visible := PEER_VISIBLE_MIN
# id -> {node, pos, yaw, last_seen, spawning, buf, off, render}
#   pos/yaw  = newest RECEIVED transform (what the wire last said)
#   buf      = [{t, p, y}] snapshots on OUR clock, oldest first — what we actually render from
#   off      = estimated (our clock - their clock), so their stamp + off lands on our timeline
var _peers := {}
var _last_sent := Vector3.INF
var _last_sent_yaw := INF
## Send-rate telemetry. Multiplayer is invisible to a harness otherwise, and the adaptive band is
## exactly the kind of change that is easy to get backwards — this makes the actual rate observable
## rather than assumed.
var _sent_n := 0
var _rate_t := 0.0
var _me := ""             # our own peer id, so a pong addressed to us is recognisable
var _ping_t := 0.0
## OUR OWN recent positions, [{t, p}] on our clock. The evidence a hit claim is checked against —
## the one thing about this player that no other client can know better than we do.
var _own_hist: Array = []
var _peer_layer := 8
## Returns [hp, max]. Polled rather than hooked so a death or a revival cannot be missed by whichever
## of take_damage's several return paths a given world happens to take.
var hp_probe: Callable = Callable()
var _was_dead := false
var _hits_ok := 0
var _hits_rejected := 0
## Who last landed a validated hit on us. Carried into our death broadcast so THEY get the kill —
## the shooter cannot award it to themselves, or two near-simultaneous hits both count.
var _last_hit_by := ""


func configure(world: Dictionary, p: Node3D, factory: Callable, hooks := {}) -> void:
	player = p
	avatar_factory = factory
	_hook_state = hooks.get("state", Callable())
	_hook_equip = hooks.get("equip", Callable())
	_hook_vehicle = hooks.get("vehicle", Callable())
	var raw: Variant = world.get("multiplayer", null)
	var mp: Dictionary = raw if raw is Dictionary else {}
	enabled = bool(mp.get("enabled", false))
	if not enabled:
		set_process(false)
		return

	_net = get_node_or_null("/root/Net")
	if _net == null:
		push_warning("[NetSync] multiplayer enabled but the Net autoload is missing — playing solo")
		enabled = false
		set_process(false)
		return

	var url := str(mp.get("supabase_url", ""))
	var key := str(mp.get("supabase_anon_key", ""))
	if url == "" or key == "":
		push_warning("[NetSync] multiplayer enabled but world.json carries no supabase_url/anon_key — playing solo")
		enabled = false
		set_process(false)
		return

	_max_players = maxi(2, int(mp.get("max_players", 8)))
	refresh_interest(world.get("weapons", null))
	_net.supabase_url = url
	_net.supabase_anon_key = key
	if not _net.message.is_connected(_on_message):
		_net.message.connect(_on_message)
	if not _net.connected.is_connected(_on_connected):
		_net.connected.connect(_on_connected)
	_net.connect_room(str(mp.get("room", "")))
	set_process(true)
	print("GOGI_MP enabled max_players=", _max_players)


## Re-derive the interest radius from the game's weapon catalog.
##
## THE RADIUS MUST CLEAR THE LONGEST SHOT IN THE GAME, and it is DERIVED rather than picked because
## a hardcoded number silently becomes wrong the first time a game ships a longer-range gun.
## peer_bodies() IS the shootable-target list, so a peer culled inside weapon range is a peer your
## bullets pass straight through — which presents as broken hit registration, not as a culling bug,
## and gets hunted for days in the wrong file. 2.5x leaves a sniper room to lead a moving target.
##
## PUBLIC because this is not a boot-only question. A chat edit can re-stat "weapons" at runtime and
## main._poll_world reloads the catalog — but configure() runs only when a room is JOINED and never
## again. So the radius kept its boot value while report_shot and the projectile both used the new,
## longer range: every peer between the two distances had no body and no entry in _live_enemies(),
## and shots at them passed straight through. A hit-registration bug that appears only after an edit
## is a bug nobody attributes to the edit.
##
## Reads the RAW world "weapons" layer rather than rpg's merged catalog. They cannot disagree here:
## an entry that omits `range` normalizes to WPN_DEFAULT_RANGE (20m), and 20 * 2.5 is far below
## PEER_VISIBLE_MIN, so the floor answers identically either way.
func refresh_interest(wraw: Variant) -> void:
	var longest := 0.0
	if wraw is Dictionary:
		for k: Variant in (wraw as Dictionary).keys():
			var wd: Variant = (wraw as Dictionary)[k]
			if wd is Dictionary:
				longest = maxf(longest, float((wd as Dictionary).get("range", 0.0)))
	elif wraw is Array:
		for wd: Variant in (wraw as Array):
			if wd is Dictionary:
				longest = maxf(longest, float((wd as Dictionary).get("range", 0.0)))
	_peer_visible = maxf(PEER_VISIBLE_MIN, longest * 2.5)
	print("GOGI_MP_INTEREST vis=", "%.0f" % _peer_visible, " longest_weapon=", "%.0f" % longest)


## How many players are in the session INCLUDING the local one. The rule condition `peer_count` is
## written by authors who mean "how many of us are here", so a lone player must read 1, not 0.
func peer_count() -> int:
	return _peers.size() + 1


## Ground-plane positions of the REMOTE players (the local body is the caller's own to add).
##
## RENDERED, not received. Everything that asks this question — `players_in_region` today, hit
## resolution next — has to agree with what is on screen. Answering with the newest packet instead
## would mean a peer visibly outside a region counted as inside it, which is a bug the player can
## SEE and no log would ever explain.
func peer_positions() -> Array:
	var out: Array = []
	for id in _peers:
		var rec: Dictionary = _peers[id]
		var n: Node = rec.get("node")
		if n != null and is_instance_valid(n) and n is Node3D:
			out.append((n as Node3D).global_position)
			continue
		var p = rec.get("pos", null)
		if p is Vector3:
			out.append(p)
	return out


## Minimap feed: where every known peer is, and the colour their body wears.
##
## From the RECORD, not the body. A peer beyond the interest radius has no avatar and MUST still
## appear here — a big map is precisely where knowing someone is out there matters, and without this
## the culling in _process would read as players vanishing. It is the other half of why culling frees
## the avatar and keeps the record.
##
## `far` says we know the position but are not drawing a body, so the map can be honest about the
## difference instead of implying you could see them if you turned around.
func peer_blips() -> Array:
	var out: Array = []
	for id: Variant in _peers:
		var rec: Dictionary = _peers[id]
		var n: Variant = rec.get("node")
		var live := n != null and is_instance_valid(n) and n is Node3D
		var pos: Variant = (n as Node3D).global_position if live else rec.get("pos", null)
		if pos is Vector3:
			out.append({"pos": pos, "color": color_for(String(id)), "far": not live})
	return out


## Drop every remote body. Called on a world switch — peers belong to the world that spawned them.
func reset_for_world_change() -> void:
	for id in _peers.keys():
		var rec: Dictionary = _peers[id]
		var n: Node = rec.get("node")
		if n != null and is_instance_valid(n):
			n.queue_free()
	_peers.clear()
	_last_sent = Vector3.INF
	_last_sent_yaw = INF


## A PLAYER'S COLOUR IS A FUNCTION OF WHO THEY ARE, not of whose screen they are on.
##
## The local body was hardcoded blue and every remote body hardcoded orange, so with two players each
## person saw THEMSELF blue and the OTHER orange. Two players, two screens, no agreement about who
## was who — and the more players joined, the worse it got, because every remote body was the same
## orange as every other. Hashing the id into a hue makes a player look identical everywhere, and
## distinct from everyone else, with no coordination between clients at all.
static func color_for(id: String) -> Color:
	if id == "":
		return Color(0.55, 0.60, 0.68)   # not yet identified: a neutral grey, deliberately outside the palette
	var h := 0
	for i in id.length():
		h = (h * 131 + id.unicode_at(i)) & 0x7fffffff
	# Golden-angle stride so ids that land near each other numerically still get far-apart hues.
	return Color.from_hsv(fmod(float(h) * 0.618033988, 1.0), 0.62, 0.95)


func _on_connected(r: String, you: String) -> void:
	room = r
	_me = you
	identified.emit(you)
	print("GOGI_MP room=", r, " me=", you)
	# Broadcast immediately rather than waiting for the next tick: on a REJOIN the other peers are
	# holding our stale pre-drop position, and one packet snaps us back where we actually are.
	_broadcast_now()


func _process(delta: float) -> void:
	if not enabled:
		return

	# --- send ---
	if player != null and is_instance_valid(player) and _net != null and _net.is_connected_to_room():
		_accum += delta
		# Yaw counts as movement. A player standing still and turning to line up a shot has moved
		# nothing and changed everything, and dropping them to the idle band would be the worst
		# possible moment to go quiet.
		var moving: bool = _last_sent == Vector3.INF \
			or player.global_position.distance_to(_last_sent) > MOVE_EPS \
			or absf(angle_difference(player.rotation.y, _last_sent_yaw)) > YAW_EPS
		var interval := 1.0 / (_send_hz_moving() if moving else SEND_HZ_IDLE)
		if _accum >= interval:
			# Subtract rather than zero, so the send phase survives a frame spike instead of
			# silently drifting the real rate below the nominal one. Capped so a long stall
			# (a backgrounded tab) cannot bank credit and then burst.
			_accum = minf(_accum - interval, interval)
			_broadcast_now()

	# --- our own past, for adjudicating hit claims ---
	# Recorded EVERY FRAME, not per packet. The send rate drops to 4Hz when standing still, and a
	# history sampled that coarsely would place us up to 250ms of movement away from where we were
	# when someone shot — rejecting honest hits at exactly the moment a player starts running.
	if player != null and is_instance_valid(player):
		var tnow := Time.get_ticks_msec() / 1000.0
		_own_hist.append({"t": tnow, "p": player.global_position})
		while _own_hist.size() > 2 and float(_own_hist[0]["t"]) < tnow - HIST_S:
			_own_hist.pop_front()

	# --- life/death, polled ---
	# take_damage has several return paths (opt-in death, checkpoint respawn, heal-to-full); hooking
	# them all would mean one of them eventually gets missed. Watching the value cannot.
	if hp_probe.is_valid() and _net != null and _net.is_connected_to_room():
		var hp := float(hp_probe.call())
		if hp <= 0.0 and not _was_dead:
			_was_dead = true
			_net.send({"t": "dead", "by": _last_hit_by})
		elif hp > 0.0 and _was_dead:
			_was_dead = false
			_last_hit_by = ""
			_net.send({"t": "alive"})

	# --- clock ---
	if _net != null and _net.is_connected_to_room() and not _peers.is_empty():
		_ping_t += delta
		if _ping_t >= PING_EVERY:
			_ping_t = 0.0
			_net.send({"t": "ping", "ts": Time.get_ticks_msec()})

	_rate_t += delta
	if _rate_t >= 5.0:
		# bodies/vis are here because interest culling is otherwise INVISIBLE: a room that culls
		# correctly and one that never culls at all print an identical peer count.
		print("GOGI_MP_NET hz=", "%.1f" % (_sent_n / _rate_t), " peers=", _peers.size(),
			" bodies=", _body_count(), " vis=", "%.0f" % _peer_visible,
			" buf=", _buf_depths(), " rtt=", _rtts())
		_sent_n = 0
		_rate_t = 0.0

	# --- receive / age out ---
	var now := Time.get_ticks_msec() / 1000.0
	for id in _peers.keys():
		var rec: Dictionary = _peers[id]
		var age := now - float(rec.get("last_seen", 0.0))
		if age > DESPAWN_S:
			var dead: Node = rec.get("node")
			if dead != null and is_instance_valid(dead):
				_release_peer_mount(rec)
			dead.queue_free()
			_peers.erase(id)
			print("GOGI_MP_PEER leave ", id, " peers=", _peers.size())
			peer_left.emit(id)
			continue
		var node: Node3D = rec.get("node")
		# INTEREST CULLING — free the avatar of anyone who has gone far away; KEEP the record.
		# Hysteresis (SLACK) applies on the way OUT only; spawning is gated at the plain radius in
		# _on_pos, so the two edges never coincide and a peer at the boundary cannot oscillate.
		if node != null and is_instance_valid(node) \
			and not _within_interest(rec.get("pos", Vector3.ZERO), PEER_VISIBLE_SLACK):
			_release_peer_mount(rec)
			node.queue_free()
			rec["node"] = null
			node = null
			print("GOGI_MP_PEER cull ", id, " bodies=", _body_count())
		if node == null or not is_instance_valid(node):
			continue
		if age > STALE_S:
			continue   # they stopped talking — leave the body where it is rather than drifting it
		_sync_peer_equip(rec, node)
		_sync_peer_mount(rec, node)
		_render_peer(rec, node, now, delta)


## Place a peer at `now - INTERP_DELAY` from the two snapshots that BRACKET that instant.
##
## A starved buffer HOLDS the newest sample and never extrapolates. Guessing forward looks smoother
## for one frame and then rubber-bands the body backwards the moment a real packet disagrees, which
## reads as a worse connection than simply pausing does.
func _render_peer(rec: Dictionary, node: Node3D, now: float, delta: float) -> void:
	var buf: Array = rec.get("buf", [])
	if buf.is_empty():
		return
	var rt := now - INTERP_DELAY

	# Retire samples we have already rendered past. buf[0] ends up as the last snapshot at or before
	# the render time, so the bracket is always buf[0]..buf[1] and the search is O(1) per frame.
	while buf.size() >= 2 and float(buf[1]["t"]) <= rt:
		buf.pop_front()

	var a: Dictionary = buf[0]
	if buf.size() == 1 or rt <= float(a["t"]):
		_place(rec, node, a["p"], float(a["y"]), delta)
		return
	var b: Dictionary = buf[1]
	var span := float(b["t"]) - float(a["t"])
	var f: float = 0.0 if span <= 0.0 else clampf((rt - float(a["t"])) / span, 0.0, 1.0)
	var pa: Vector3 = a["p"]
	var pb: Vector3 = b["p"]
	# A gap this big between consecutive samples is a teleport or a rejoin, not motion. Gliding it
	# would ski the body across the map, so land on the far side at once.
	if pa.distance_to(pb) > SNAP_DIST:
		_place(rec, node, pb, float(b["y"]), delta)
		return
	_place(rec, node, pa.lerp(pb, f), lerp_angle(float(a["y"]), float(b["y"]), f), delta)


func _place(rec: Dictionary, node: Node3D, p: Vector3, yaw: float, delta: float) -> void:
	var prev: Vector3 = rec.get("render", p)
	node.global_position = p
	node.rotation.y = yaw
	rec["render"] = p
	_drive_anim(rec, node, prev, p, delta)


## Feed the peer's animation state machine from the transform we just rendered. The local
## player answers "how fast am I going" from its CharacterBody3D; a peer has no body and no
## controller, so the SAME machine is fed the interpolated delta instead. Every _place path
## funnels through here, so there is one motion source per peer and no second code path.
##
## `on_floor` is DERIVED, not known — the wire carries position and yaw only. Treating "barely
## moving vertically" as grounded lands the same clips the local hero picks: flat ground reads
## grounded; a jump reads airborne AND rising, so the state machine's own vy > 0.5 test fires
## the leap; a fall reads airborne but not rising, so it degrades to run/walk exactly as the
## local hero does with no fall clip. Matching the machine's own threshold keeps the two honest.
func _drive_anim(rec: Dictionary, node: Node3D, prev: Vector3, cur: Vector3, delta: float) -> void:
	if delta <= 0.0 or node == null or node.anim == null:
		return
	var d := cur - prev
	var vy := d.y / delta
	node.anim.update(delta, {
		"speed": Vector2(d.x, d.z).length() / delta,
		"vy": vy,
		"on_floor": absf(vy) < PEER_AIR_VY,
		"swimming": bool(rec.get("sw", false)),
		# Still not synced: mount/vehicle state. A mounted peer plays locomotion instead of the
		# seated GPose, because showing them properly means spawning the mount model too, not
		# just flipping a flag. Declared rather than silently wrong.
		"mounted": int(rec.get("mv", -1)) >= 0,
	})
	# A mounted peer is posed by the vehicle (GPose.ride/sit), exactly like a local rider, so the
	# state machine above stands down and the ride is parked under them here.
	var mv := int(rec.get("mv", -1))
	if mv >= 0 and _hook_vehicle.is_valid():
		var v = _hook_vehicle.call(mv)
		if v != null and is_instance_valid(v) and v.has_method("place_under_remote_rider"):
			v.place_under_remote_rider(cur, node.rotation.y)


## Buffer depth per peer, for the GOGI_MP_NET line. A depth that sits at 0-1 means we are starved
## and holding rather than interpolating — the one failure of this design that is invisible on
## screen, because a held body and a correctly-interpolated one look identical while walking.
func _buf_depths() -> String:
	var parts: Array = []
	for id in _peers:
		var b: Array = (_peers[id] as Dictionary).get("buf", [])
		parts.append(str(b.size()))
	return "[" + ",".join(parts) + "]"


## One line of sync health for the on-screen ?mpdebug=1 overlay.
##
## `HOLD` is the flag that matters. A buffer with fewer than two snapshots cannot bracket the render
## time, so the body freezes on its newest sample — which looks EXACTLY like correct interpolation
## while someone walks in a straight line, and is the one failure of this design a player could stare
## at without seeing. `rtt=--` means clock sync has not landed and the peer is being drawn with the
## latency-biased bootstrap offset.
func debug_line() -> String:
	if not enabled:
		return "mp off"
	if _peers.is_empty():
		return "mp on  room=%s  peers=0 (waiting)" % room
	var rows: Array = []
	for id in _peers:
		var rec: Dictionary = _peers[id]
		var b: Array = rec.get("buf", [])
		rows.append("%s rtt=%s buf=%d%s" % [
			id.substr(0, 4),
			"--" if not bool(rec.get("synced", false)) else str(int(float(rec.get("rtt", 0.0)) * 1000.0)),
			b.size(),
			"" if b.size() >= 2 else " HOLD"])
	return "mp peers=%d  lag=%dms  hits ok=%d rej=%d%s\n%s" % [
		_peers.size(), int(INTERP_DELAY * 1000.0), _hits_ok, _hits_rejected,
		"  DEAD" if _was_dead else "", " | ".join(rows)]


## Best-seen RTT per peer in ms, or `-` while a peer is still on the bootstrap estimate. This is the
## line that says whether clock sync actually happened: a peer stuck on `-` is being rendered with a
## latency-biased offset, which is exactly the failure the test caught and no screen would show.
func _rtts() -> String:
	var parts: Array = []
	for id in _peers:
		var rec: Dictionary = _peers[id]
		parts.append("-" if not bool(rec.get("synced", false))
			else str(int(float(rec.get("rtt", 0.0)) * 1000.0)))
	return "[" + ",".join(parts) + "]"


func _broadcast_now() -> void:
	if player == null or not is_instance_valid(player) or _net == null:
		return
	var p := player.global_position
	_last_sent = p
	_last_sent_yaw = player.rotation.y
	_sent_n += 1
	# `ts` is OUR monotonic clock. The receiver maps it onto theirs; we never read anyone else's raw
	# stamp as if it meant something locally. Sent as an int (ms) because JSON floats are the one
	# place a timeline can quietly lose precision.
	var pkt := {"t": "p", "x": p.x, "y": p.y, "z": p.z, "r": player.rotation.y,
		"ts": Time.get_ticks_msec()}
	# AVATAR STATE RIDES THE POSITION HEARTBEAT rather than taking its own message kind. It is a
	# few bytes, and re-sending it 10x/s makes it SELF-HEALING: a late joiner, a dropped packet
	# and a peer walking back into interest range all correct within 100ms with no handshake and
	# no join race. This adds bytes, not messages, so the rate budget in the header is untouched.
	# DEFAULTS ARE OMITTED, so the common packet — unarmed, dry — is byte-identical to before,
	# and a peer running an OLDER engine simply never sees keys it would not have read anyway.
	if _hook_state.is_valid():
		var st: Dictionary = _hook_state.call()
		var wid := String(st.get("w", ""))
		if wid != "":
			pkt["w"] = wid
		if bool(st.get("stw", false)):
			pkt["stw"] = 1
		if bool(st.get("sw", false)):
			pkt["sw"] = 1
		# Which ride they are on, as its index in world.json's "vehicles". Every client builds that
		# list from the same file in the same order, so the index means the same thing everywhere
		# and the vehicle itself never has to be spawned or described on the wire — it is already
		# standing in our scene.
		var mv := int(st.get("mv", -1))
		if mv >= 0:
			pkt["mv"] = mv
	_net.send(pkt)


func _on_message(d: Dictionary) -> void:
	var kind := str(d.get("t", ""))
	var id := str(d.get("from", ""))
	if id == "" or id == _me:
		return
	match kind:
		"p": _on_pos(d, id)
		"ping": _on_ping(d, id)
		"pong": _on_pong(d, id)
		"hit": _on_hit(d, id)
		"shot":
			# Swing the shooter's arm on OUR screen. The shot was already on the wire; only the
			# animation was missing, so this costs no bandwidth.
			_peer_attack(id)
			peer_shot.emit(id,
				Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0))),
				Vector3(float(d.get("dx", 0.0)), float(d.get("dy", 0.0)), float(d.get("dz", 1.0))),
				float(d.get("spd", 22.0)), float(d.get("rng", 20.0)))
		"emo":
			# One-shot emote from a peer. Its own message kind on purpose: piggybacking a one-shot
			# on the 10Hz heartbeat would re-trigger the clip ten times a second for as long as it
			# stayed in the packet. Fire-and-forget — a dropped emote is a missed wave, not desync.
			_peer_emote(id, String(d.get("clip", "")), float(d.get("hold", 1.2)))
		"dead": _on_peer_dead(d, id)
		"alive": _on_peer_alive(d, id)


## SOMEBODY CLAIMS THEY SHOT US. We are the only client that knows where we really were.
func _on_hit(d: Dictionary, id: String) -> void:
	if str(d.get("to", "")) != _me:
		return
	var when := float(d.get("ts", 0)) / 1000.0          # already converted to OUR clock by the shooter
	var claimed := Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))
	if not _validate_hit(when, claimed):
		_hits_rejected += 1
		print("GOGI_MP_HIT rejected from=", id, " age=%.2f" % ((Time.get_ticks_msec() / 1000.0) - when))
		return
	_hits_ok += 1
	_last_hit_by = id
	hit_taken.emit(id, float(d.get("dmg", 0.0)))


## Was this player plausibly at `claimed` at time `when`?
func _validate_hit(when: float, claimed: Vector3) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	# A claim from the future is a broken or lying clock; one that is too old cannot be adjudicated
	# against a history we no longer keep. Both are refusals, not errors.
	if when > now + 0.15 or now - when > HIT_MAX_AGE:
		return false
	var was = _own_pos_at(when)   # untyped: null means "outside the history we kept"
	if was == null:
		return false
	return (was as Vector3).distance_to(claimed) <= HIT_TOLERANCE


## Where we were at `t`, interpolated from our own history. null when `t` falls outside it.
func _own_pos_at(t: float):
	if _own_hist.is_empty():
		return null
	if t <= float(_own_hist[0]["t"]):
		return _own_hist[0]["p"]
	for i in range(_own_hist.size() - 1, -1, -1):
		var a: Dictionary = _own_hist[i]
		if float(a["t"]) <= t:
			if i + 1 >= _own_hist.size():
				return a["p"]
			var b: Dictionary = _own_hist[i + 1]
			var span := float(b["t"]) - float(a["t"])
			var f: float = 0.0 if span <= 0.0 else clampf((t - float(a["t"])) / span, 0.0, 1.0)
			return (a["p"] as Vector3).lerp(b["p"], f)
	return null


func _on_peer_dead(d: Dictionary, id: String) -> void:
	var rec: Dictionary = _peers.get(id, {})
	var n = rec.get("node")
	if n != null and is_instance_valid(n) and n.has_method("set_dead"):
		n.call("set_dead", true)
	# We get the kill only if they name US. Awarding it on our own belief would double-count every
	# time two players landed a shot in the same instant.
	if str(d.get("by", "")) == _me:
		killed.emit(id)


func _on_peer_alive(_d: Dictionary, id: String) -> void:
	var rec: Dictionary = _peers.get(id, {})
	var n = rec.get("node")
	if n != null and is_instance_valid(n) and n.has_method("set_dead"):
		n.call("set_dead", false)


## Claim a hit on `target`. Called by peer_body when a projectile finds it.
func report_hit(target: String, dmg: float, at: Vector3) -> void:
	if not enabled or _net == null or not _net.is_connected_to_room():
		return
	var rec: Dictionary = _peers.get(target, {})
	# The instant we AIMED at is the instant we RENDERED them at — one INTERP_DELAY ago, not now.
	# Sending `now` would ask them to check a moment they had not yet reached, and every honest hit
	# would be refused as a claim from the future.
	var when := (Time.get_ticks_msec() / 1000.0) - INTERP_DELAY
	# Convert to THEIR clock so they can index their own history without knowing anything about ours.
	var theirs := when - float(rec.get("off", 0.0))
	_net.send({"t": "hit", "to": target, "dmg": dmg, "ts": int(theirs * 1000.0),
		"x": at.x, "y": at.y, "z": at.z})


## Tell the room we fired, so everyone else can DRAW it. Carries no target and no damage: what a
## tracer is for is being SEEN, and letting it imply a hit would put two competing sources of truth
## about the same shot on the wire.
func report_shot(origin: Vector3, dir: Vector3, def: Dictionary) -> void:
	if not enabled or _net == null or not _net.is_connected_to_room() or _peers.is_empty():
		return
	var proj: Dictionary = def.get("projectile", {}) if def.get("projectile", null) is Dictionary else {}
	_net.send({"t": "shot", "x": origin.x, "y": origin.y, "z": origin.z,
		"dx": dir.x, "dy": dir.y, "dz": dir.z,
		"spd": float(proj.get("speed", 22.0)), "rng": float(def.get("range", 20.0))})


## Peer bodies, for the projectile target list. Live nodes only — a corpse is filtered by projectile
## itself via `dead`, but a freed node would crash it.
## Is a point close enough to deserve a body? A slack > 1.0 widens it, which is how the cull edge
## sits outside the spawn edge. Answers TRUE when there is no local player yet: a spare body beats a
## room that silently despawns everyone because we asked before the hero attached.
func _within_interest(p: Variant, slack := 1.0) -> bool:
	if player == null or not is_instance_valid(player):
		return true
	if not (p is Vector3):
		return true
	return player.global_position.distance_to(p as Vector3) <= _peer_visible * slack


## Resident avatars, as opposed to known peers. The gap between the two IS the culling.
func _body_count() -> int:
	var n := 0
	for id: Variant in _peers:
		var x: Variant = (_peers[id] as Dictionary).get("node")
		if x != null and is_instance_valid(x):
			n += 1
	return n


## Send rate for a MOVING player, stepped down as the room fills. See the SEND_HZ_* note up top.
func _send_hz_moving() -> float:
	var n := _peers.size() + 1
	if n <= 8:
		return SEND_HZ_MOVING
	if n <= 16:
		return SEND_HZ_MID
	return SEND_HZ_CROWD


func peer_bodies() -> Array:
	var out: Array = []
	for id in _peers:
		var n = (_peers[id] as Dictionary).get("node")
		if n != null and is_instance_valid(n) and n.has_method("take_hit"):
			out.append(n)
	return out


## Somebody wants to know the round trip. Echo their stamp back beside ours; all the arithmetic
## happens on their side, where both numbers are on one clock.
func _on_ping(d: Dictionary, id: String) -> void:
	if _net == null:
		return
	_net.send({"t": "pong", "to": id, "a": d.get("ts", 0), "b": Time.get_ticks_msec()})


## rtt = how long our ping took to come back. Their clock read `b` at our time `a + rtt/2`, so the
## offset (ours - theirs) is (a + rtt/2) - b. Keep the sample from the lowest RTT seen: a pong that
## sat in a queue tells us about the queue, not about the clock.
func _on_pong(d: Dictionary, id: String) -> void:
	if str(d.get("to", "")) != _me:
		return
	var rec: Dictionary = _peers.get(id, {})
	if rec.is_empty():
		return
	var a := float(d.get("a", 0)) / 1000.0
	var b := float(d.get("b", 0)) / 1000.0
	var now := Time.get_ticks_msec() / 1000.0
	var rtt := now - a
	if rtt <= 0.0 or rtt > 2.0:
		return                                   # nonsense or hopelessly stale — no information
	var best: float = rec.get("rtt", INF)
	# Relax the best-seen RTT upward over time so a single lucky early sample cannot own the estimate
	# for the whole session, and a route that genuinely got slower can re-establish itself.
	if best != INF:
		best += CLOCK_RELAX_PER_S * maxf(0.0, now - float(rec.get("rtt_at", now)))
	if rtt <= best:
		rec["rtt"] = rtt
		rec["rtt_at"] = now
		rec["off"] = (a + rtt * 0.5) - b
		rec["synced"] = true


func _on_pos(d: Dictionary, id: String) -> void:

	var now := Time.get_ticks_msec() / 1000.0
	var rec: Dictionary = _peers.get(id, {})
	if rec.is_empty():
		if _peers.size() >= _max_players - 1:
			return   # room full — ignore the extra rather than spawning past the stated cap
		rec = {"node": null, "pos": Vector3.ZERO, "yaw": 0.0, "last_seen": now,
			"spawning": false, "buf": [], "off": INF, "render": Vector3.ZERO,
			"synced": false, "rtt": INF, "rtt_at": now,
			"w": "", "stw": false, "sw": false, "mv": -1,
			"w_applied": null, "stw_applied": null, "mv_applied": null}
		_peers[id] = rec
		# PING THIS ONE NOW, not on the next cadence tick. Until a pong lands we render them with
		# the latency-biased bootstrap offset, and at PING_EVERY=2s that is two full seconds of a
		# newly-joined player rendered a whole transit behind — measured at 0.48m for an 80ms link.
		# Nobody would ever see it as a bug; they would see a peer who "joined weird".
		_ping_t = PING_EVERY

	# AVATAR STATE lands on the RECORD, not the body: interest culling frees the avatar and keeps
	# the record, so a peer who walks out of range and back must come back still holding their
	# weapon. An older engine sends none of these keys and reads as unarmed and dry — the same
	# degradation the missing-stamp path below takes, and for the same reason.
	rec["w"] = String(d.get("w", ""))
	rec["stw"] = int(d.get("stw", 0)) == 1
	rec["sw"] = int(d.get("sw", 0)) == 1
	rec["mv"] = int(d.get("mv", -1))

	# WHOSE CLOCK. Two peers' `Time.get_ticks_msec()` are unrelated numbers, so their stamp has to be
	# mapped onto ours before it can index a timeline.
	#
	# Once a pong has landed, `off` is a real clock offset and we leave it alone. Before that, fall
	# back to (arrival - stamp): biased by one-way latency, but a stable bootstrap that gets a peer
	# rendering immediately instead of freezing them for the first ping interval.
	#
	# A peer on an OLDER engine sends no stamp at all. Treating arrival as the stamp degrades that
	# ONE peer to roughly the old behaviour instead of desynchronising the room — which is not a
	# hypothetical: during a rollout the phone and the browser are running different engines.
	var t_local := now
	if d.has("ts"):
		var theirs := float(d["ts"]) / 1000.0
		if not bool(rec.get("synced", false)):
			var sample := now - theirs
			var off: float = rec.get("off", INF)
			if off == INF:
				off = sample
			else:
				off = minf(off + CLOCK_RELAX_PER_S * maxf(0.0, now - float(rec["last_seen"])), sample)
			rec["off"] = off
		# Never let a snapshot land in the future: an over-estimated offset would put the render
		# target past the newest sample and permanently starve the interpolator.
		t_local = minf(theirs + float(rec["off"]), now)

	var p := Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))
	var y := float(d.get("r", 0.0))
	rec["pos"] = p
	rec["yaw"] = y
	rec["last_seen"] = now

	# The buffer must stay MONOTONIC or the bracket search is meaningless. A packet that arrives out
	# of order, or a burst of stale transforms from a tab that just woke up, has nothing to add to a
	# timeline we have already rendered past — drop it rather than sorting it in.
	var buf: Array = rec["buf"]
	if buf.is_empty() or t_local > float(buf[buf.size() - 1]["t"]):
		buf.append({"t": t_local, "p": p, "y": y})
		while buf.size() > BUF_MAX:
			buf.pop_front()

	# Distance-gated, and this is the line that MAKES culling work: it runs on every inbound packet,
	# so without the gate the avatar we freed one frame ago is rebuilt on the next one, forever.
	if rec.get("node") == null and not bool(rec.get("spawning", false)) and _within_interest(p):
		rec["spawning"] = true
		_spawn_peer(id)


## Play the melee/fire swing on a peer's avatar. Mirrors the local call site (main.gd's
## melee branch): set the hold gate, then kick the clip. Silent when the peer is culled,
## unknown, or riding the rigless fallback capsule.
## Bring a peer's held weapon in line with what their client last told us. Cheap to call every
## frame: two string/bool compares and an early out. The applied-markers are set BEFORE the hook
## runs because the hook awaits a model fetch — without that this would re-enter every frame for
## the whole download and queue a dozen equips of the same weapon.
func _sync_peer_equip(rec: Dictionary, node: Node3D) -> void:
	if not _hook_equip.is_valid() or node.avatar == null or not is_instance_valid(node.avatar):
		return
	var want := String(rec.get("w", ""))
	var stow := bool(rec.get("stw", false))
	if rec.get("w_applied", null) == want and rec.get("stw_applied", null) == stow:
		return
	rec["w_applied"] = want
	rec["stw_applied"] = stow
	_hook_equip.call(node.avatar, want, stow)


## Broadcast a one-shot emote to the room. Silent when multiplayer is off, so the rule action
## works identically in a single-player game.
func send_emote(clip: String, hold := 1.2) -> void:
	if not enabled or _net == null or clip == "":
		return
	_net.send({"t": "emo", "clip": clip, "hold": hold})


## Play a peer's emote on their avatar.
func _peer_emote(id: String, clip: String, hold: float) -> void:
	if clip == "":
		return
	var rec: Dictionary = _peers.get(id, {})
	var node = rec.get("node")
	if node == null or not is_instance_valid(node) or node.anim == null:
		return
	node.anim.action(clip, hold)


## Seat or unseat a peer on the ride they say they are on. The vehicle already exists in our
## scene — every client spawns the same world.json list — so this only has to hand it a rider.
## Hand a peer's ride back before their body goes away. is_instance_valid on the vehicle side
## already makes a freed rider harmless, but leaving the reference dangling means the ride keeps
## its remote-owned pose and never re-poses a later rider — cheap to do properly.
func _release_peer_mount(rec: Dictionary) -> void:
	var applied = rec.get("mv_applied", null)
	rec["mv_applied"] = null
	if applied == null or int(applied) < 0 or not _hook_vehicle.is_valid():
		return
	var v = _hook_vehicle.call(int(applied))
	if v != null and is_instance_valid(v):
		v.clear_remote_rider()


func _sync_peer_mount(rec: Dictionary, node: Node3D) -> void:
	if not _hook_vehicle.is_valid():
		return
	var want := int(rec.get("mv", -1))
	var applied = rec.get("mv_applied", null)
	if applied != null and int(applied) == want:
		return
	if applied != null and int(applied) >= 0:
		var old = _hook_vehicle.call(int(applied))
		if old != null and is_instance_valid(old):
			old.clear_remote_rider()
	rec["mv_applied"] = want
	if want < 0 or node.avatar == null or not is_instance_valid(node.avatar):
		return
	var v = _hook_vehicle.call(want)
	if v != null and is_instance_valid(v):
		# The AVATAR is the rider, not the body: GPose poses a skeleton, and the body is a bare
		# capsule. Placement still keys off the body, which is what the wire carries.
		v.set_remote_rider(node.avatar)


func _peer_attack(id: String) -> void:
	var rec: Dictionary = _peers.get(id, {})
	var node = rec.get("node")
	if node == null or not is_instance_valid(node) or node.anim == null:
		return
	node.anim.attack_t = 0.45
	node.anim.play("attack")


func _spawn_peer(id: String) -> void:
	# The avatar is what you SEE; the body is what you COLLIDE WITH and SHOOT. Keeping them separate
	# means a streamed hero_model never has to carry a script or a collision shape, and the same body
	# works whether the peer is a fetched character or the fallback capsule.
	var avatar: Node3D = null
	if avatar_factory.is_valid():
		avatar = await avatar_factory.call()
	if avatar == null:
		avatar = _fallback_body(id)
	var node: Node3D = preload("res://peer_body.gd").new()
	node.setup(id, self, _peer_layer)
	node.name = "GogiPeer_" + id
	node.add_child(avatar)
	add_child(node)
	# ANIMATE THE PEER. Same state machine the local hero runs (hero_anim.gd) — it was four
	# globals on main.gd until it became per-avatar, which is why peers used to slide around
	# frozen in their rest pose. attach() returns false on a rigless avatar (the fallback
	# capsule), and then we simply never drive it.
	node.avatar = avatar
	var pa = GHeroAnim.new()
	node.anim = pa if pa.attach(avatar) else null
	var rec: Dictionary = _peers.get(id, {})
	if rec.is_empty():
		node.queue_free()   # peer aged out while its model was still downloading
		return
	rec["node"] = node
	# A culled peer keeps its RECORD (weapon id and all) but loses its BODY, so the avatar that
	# just respawned is wearing nothing. Clearing the applied-marker makes the next frame re-equip
	# it. This is the whole reason weapon state lives on the record and anim state does not.
	rec["w_applied"] = null
	rec["stw_applied"] = null
	rec["mv_applied"] = null
	# ANNOUNCE ONCE PER PEER, NOT ONCE PER BODY. Interest culling re-runs this function every time
	# someone walks back into range, and `peer_join` is a RULE-LAYER EVENT (game_shell fires it and
	# calls announce_synced). Re-emitting would replay a game's join rules on every crossing — and
	# because a cull deliberately does NOT emit `peer_left`, a rule counting players by +1/-1 would
	# climb forever. Tied to the RECORD's lifetime instead of the avatar's, which is what "free the
	# avatar, keep the record" is supposed to mean: the record is erased only at DESPAWN_S, and that
	# path DOES emit peer_left, so a genuine rejoin gets a fresh record and announces again. Balanced.
	#
	# Distance-only, so it is invisible on a small map and invisible at two players.
	var first := not bool(rec.get("announced", false))
	if first:
		rec["announced"] = true
		peer_joined.emit(id)
	rec["spawning"] = false
	# Land on the newest received transform, not the interpolated one — the body appears where they
	# ARE. _render_peer takes over on the next frame and eases it back to the render time.
	node.global_position = rec.get("pos", Vector3.ZERO)
	rec["render"] = node.global_position
	# Telemetry in the same shape as the rest of the engine's (GOGI_SEAT_CONTACT, GOGI_VRAM_MB):
	# multiplayer is otherwise invisible to a harness — a game with zero peers and a game whose
	# peers never spawn look identical from outside.
	# "respawn" is a body returning through the interest radius, NOT a new player — the distinction
	# exists because the two were indistinguishable in the log and only one of them is an event.
	print("GOGI_MP_PEER ", "join" if first else "respawn", " ", id,
		" peers=", _peers.size(), " bodies=", _body_count())


## Only reached when the world names no hero model and the factory has nothing to clone. A capsule is
## a placeholder of last resort, tinted from the peer's OWN id so it reads the same on every screen.
func _fallback_body(id: String) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.6
	mi.mesh = cm
	mi.position.y = 0.85
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color_for(id)
	mi.material_override = mat
	root.add_child(mi)
	return root
