class_name AreaBuilder extends Node
## AREA BUILDER — turns one world.json area RECORD into a live scene: streams its .glb from
## R2 (parallel, behind the fade), instantiates ground/props/enemies, bakes nav, and
## registers interactables. Cache is shared across areas so re-entry is cheap. Returns the
## area root to free later. The .pck binds scripts+shaders; ASSETS stream from R2 at runtime.

const SKELETON := "/godot-assets/enemies/skeleton_warrior.glb"
const NPC_MODEL := "/godot-assets/characters/kk_Knight.glb"
const EnemyScript := preload("res://enemy.gd")

# named-prop palette: world.json `props: [{kind,pos}]` places these specific assets.
# Validate these paths against the LIVE /godot-assets/manifest.json before shipping.
const PALETTE := {
	"tree": "/godot-assets/props/kenney_nature/Tree_Bare_1.glb",
	"rock": "/godot-assets/props/kenney_nature/Rock_1.glb",
	"barrel": "/godot-assets/props/fs_village/prop_barrel_1.glb",
	"crate": "/godot-assets/props/fs_platformer/prop_crate.glb",
	"box": "/godot-assets/props/fs_platformer/prop_crate.glb",
	"torch": "/godot-assets/props/kk_dungeon/torch.glb",
	"stump": "/godot-assets/props/kenney_nature/Stump_1.glb",
	"log": "/godot-assets/props/kenney_nature/Log_1.glb",
	"pillar": "/godot-assets/props/fs_temple/pillar_large_arch.glb",
	"bush": "/godot-assets/props/fs_nature/bush_1.glb",
	"banner": "/godot-assets/props/kk_dungeon/banner_blue.glb",
	"plant": "/godot-assets/props/kk_hex/waterplant_A.glb",
}

# GROUND material presets — a cell's `ground` may be a NAMED surface ("sand", "asphalt", …) instead
# of a bare [r,g,b]. Every preset (and every legacy RGB) is rendered with a tiled procedural NORMAL
# map so the floor reads as a real surface with relief, NOT a dead flat colored plane (the #1
# "no desert / no real ground" cause). color/rough/tiling/bump are tuned per surface.
const GROUND_PRESETS := {
	"sand":     {"color": [0.78, 0.68, 0.46], "rough": 0.96, "tiling": 9.0,  "bump": 0.5},
	"desert":   {"color": [0.75, 0.63, 0.42], "rough": 0.97, "tiling": 8.0,  "bump": 0.55},
	"dune":     {"color": [0.80, 0.69, 0.47], "rough": 0.97, "tiling": 6.0,  "bump": 0.7},
	"asphalt":  {"color": [0.12, 0.12, 0.14], "rough": 0.82, "tiling": 16.0, "bump": 0.28},
	"road":     {"color": [0.11, 0.11, 0.13], "rough": 0.8,  "tiling": 16.0, "bump": 0.28},
	"concrete": {"color": [0.46, 0.46, 0.49], "rough": 0.9,  "tiling": 11.0, "bump": 0.2},
	"sidewalk": {"color": [0.54, 0.54, 0.57], "rough": 0.9,  "tiling": 11.0, "bump": 0.2},
	"grass":    {"color": [0.30, 0.48, 0.23], "rough": 1.0,  "tiling": 13.0, "bump": 0.45},
	"dirt":     {"color": [0.40, 0.31, 0.22], "rough": 0.98, "tiling": 11.0, "bump": 0.5},
	"mud":      {"color": [0.30, 0.24, 0.17], "rough": 0.7,  "tiling": 10.0, "bump": 0.45},
	"snow":     {"color": [0.90, 0.92, 0.96], "rough": 0.65, "tiling": 9.0,  "bump": 0.35},
	"stone":    {"color": [0.45, 0.45, 0.48], "rough": 0.85, "tiling": 8.0,  "bump": 0.45},
	"cobble":   {"color": [0.40, 0.39, 0.40], "rough": 0.78, "tiling": 7.0,  "bump": 0.65},
	"rock":     {"color": [0.42, 0.40, 0.40], "rough": 0.9,  "tiling": 7.0,  "bump": 0.6},
	"water":    {"color": [0.16, 0.32, 0.42], "rough": 0.12, "tiling": 12.0, "bump": 0.25},
}

# Lazy region payload: density-ONLY fields the optional per-area `region` loose JSON may
# overlay onto a LOCAL effective copy of the record. Graph/winnability fields (id, spawns,
# seams, chest, npc, enemies, enemy_type, size) are NEVER read from the region file — qgcheck
# only sees world.json, so overlaying them would blind the gate.
const REGION_OVERLAY_FIELDS := ["props", "scatter", "ground", "ambient", "name"]

# Bounded LRU cap for the GLB template cache: a long chunk roam streams ever-new assets, so an
# unbounded url->Node cache grows until OOM. Wave 4: raised 40 -> 80 because a rich world's resident
# ring can reference more than 40 distinct GLBs; at 40 the working set thrashed (evict -> re-download
# -> re-PARSE on re-entry, the single biggest hitch). 80 holds a rich ring + recent history; eviction
# still bounds memory (each entry's meshes/materials are refcounted Resources shared by placements).
const GLB_CACHE_CAP := 32   # 80 -> 48 -> 32. The biggest CONTROLLABLE mobile-memory cost: every cached template
                            # holds its meshes AND textures resident. 80 tipped an asset-heavy world (37MB wasm +
                            # ~46MB models) into an OOM tab-crash-reload; 48 still froze an iPhone after a few
                            # minutes in a heavy region while the SAME build on a Mac never did — a device-ceiling
                            # signature, not a logic bug. Lower is a deliberate trade: more re-downloads (a brief
                            # stutter) in exchange for not hitting the wall (a dead tab). A cap-60 test on-device
                            # measured NO framerate gain over 48, so the cache was already past the point of
                            # buying anything — which makes trimming it close to free. NOTE: verify.mjs mirrors
                            # this value — keep them in sync.

# Wave 4: per-frame time budget (microseconds) for amortized GLB parsing in _process. A big batch's
# generate_scene calls spread across frames under this budget instead of hitching one frame; always
# ≥1 parse/frame so the queue drains steadily (~6ms leaves headroom in a 16ms frame).
const PARSE_BUDGET_US := 6000

# SOLID-BY-DEFAULT threshold — SHARED CONTRACT (world-building.md): a placed prop/model is
# SOLID (gets a derived StaticBody3D box collider) when its WORLD AABB's largest dimension
# is >= this many metres; anything smaller is step-over decoration and gets NO collider.
# An explicit `collider: "none"` on a record always opts out; chunk cells may instead opt
# into `collider: "mesh"` (trimesh, walk-INTO interiors) in chunk_manager._place_one.
const SOLID_MIN_DIM := 0.45

var origin: String                  # https://preview.myapping.com (for /godot-assets/)
var world_url: String               # https://preview.myapping.com/world.json (for sibling loose files)
var cache := {}                     # url -> source Node (bounded LRU, see _cache_put; persists across areas)
var _cache_order: Array[String] = []  # LRU bookkeeping for `cache`: least-recent FIRST, most-recent LAST
var region_cache := {}              # "<basename>:<region_rev>" -> parsed Dictionary (persists; re-entry skips re-fetch)
var props_pool: Array = []          # prop urls from the manifest
var env: Environment
var _retry := {}                    # url -> retry attempts used (#9: transient-fetch retry, like the hero's — a
                                    # cold-load "spawn before the fetch landed" race with NO retry was the red-box cause)
var _inflight := {}                 # url -> true while a download+parse is in progress (dedupes concurrent _ensure calls)
var _failed := {}                   # url -> true when retries exhausted (releases every _ensure waiting on it)
const FETCH_RETRIES := 5
var _parse_queue: Array = []        # [{url, body}] downloaded GLBs awaiting parse (threaded off-web, amortized on web)

# ---- OFF-MAIN-THREAD GLB PARSING (native only) -------------------------------------------------
# The web build is `nothreads` WASM: one thread, so a heavy GLTFDocument parse MUST happen on the
# frame thread and the only lever is spreading it (PARSE_BUDGET_US). That spreads the cost, it does
# not remove it — the drain loop always runs at least one parse per frame so the queue can't stall,
# and one big model's generate_scene overruns any budget. Measured on device: p95 frame 124ms while
# streaming a dense area, against a 21ms average.
#
# Natively there are real threads, so the parse moves OFF the frame thread entirely and the hitch
# goes to ZERO rather than being amortized. Only the cheap main-thread-only tail (cache insert,
# bookkeeping) stays in _process.
#
# WEB BEHAVIOUR IS BYTE-FOR-BYTE UNCHANGED — `_threaded_parse` is false there and the original
# budgeted loop runs. This is deliberately additive: the shipped web tier takes no risk from it.
const PARSE_THREADS := 2            # concurrent parse tasks; >2 thrashes memory on a phone for no gain
var _threaded_parse := not OS.has_feature("web")
var _parse_tasks := {}              # WorkerThreadPool task id -> url, for _exit_tree drain
var _parse_done: Array = []         # [{url, scene}] finished parses awaiting main-thread pickup
var _parse_mutex := Mutex.new()     # guards _parse_done ONLY (worker writes, main thread drains)
var _ground_mat_cache := {}         # spec-key -> StandardMaterial3D (textured floors shared across cells)


# returns {root: Node3D, enemies: Array} — async (downloads behind the fade)
func build_area(rec: Dictionary, scene_parent: Node, player: Node3D, world_main: Node,
		interaction, _rpg) -> Dictionary:
	# 0. lazy region payload: if this area names a loose `region` JSON file, fetch it and
	# shallow-overlay ONLY density fields onto a LOCAL effective copy. Graph fields stay on the
	# BASE record. Any failure (404 / net / parse) falls back to the base record inline.
	rec = await _apply_region(rec)

	var size := float(rec.get("size", 13))
	var enemy_n := int(rec.get("enemies", 0))
	var scatter_n := 0   # RANDOM SCATTER DISABLED — it was the source of the floating/glitchy clutter.
	# Zone areas use the intentionally-placed `props` (named palette, re-enabled below) + colors +
	# chest/npc/seam. `scatter` is CHUNK-mode only; it is deliberately NOT read here, and it has
	# been removed from the README, the playbooks, the agent prompt and the template's own
	# world.json so nothing advertises a key this path ignores.

	# 1. resolve the URLs this area needs, then download the missing ones in PARALLEL
	var chosen_props: Array = []
	for _i in range(scatter_n):
		if props_pool.is_empty():
			break
		chosen_props.append(props_pool[randi() % props_pool.size()])
	var urls: Array = []
	if enemy_n > 0:
		urls.append(origin + SKELETON)
	if rec.has("npc"):
		urls.append(origin + NPC_MODEL)
	for u in chosen_props:
		if not (u in urls):
			urls.append(u)
	# named props placed by world.json / AI edits: [{kind, pos}]
	# Re-enabled: these were stubbed out when props floated across inconsistent source art, but
	# the placement loop below now ground-snaps every one (`position.y -= maxf(0.0, aabb.y)` —
	# drops floaters, never lifts), which is the cause that disable was working around. Leaving
	# it stubbed meant an authored `props` array passed qgcheck, deployed, hot-reloaded and then
	# rendered nothing, with no error anywhere. `scatter` stays off deliberately — see line 128.
	var named: Array = rec.get("props", [])   # [{kind, pos}] — palette props at authored spots
	for np in named:
		var purl := _palette_url(np)
		if purl != "" and not (purl in urls):
			urls.append(purl)
	await _ensure(urls)

	# 2. build the area scene
	var root := Node3D.new()
	scene_parent.add_child(root)
	# Skip when the Weather3D system owns the sky/ambient (else it resets each area).
	if env and not env.has_meta("weather_owned"):
		var a = rec.get("ambient", [0.6, 0.6, 0.66])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)
	var nav := _build_room(root, size, rec.get("ground", [0.3, 0.33, 0.38]))

	var placed: Array[Vector2] = []
	for u in chosen_props:
		if not cache.has(u):
			continue
		_cache_touch(u)
		var p3 := (cache[u] as Node).duplicate() as Node3D
		if p3 == null:
			continue
		root.add_child(p3)
		p3.rotation.y = randf() * TAU
		# size-classify the asset (the pool mixes decor with whole structures): SKIP a building
		# rather than crush it to a weird miniature; shrink merely-large decor so it fits the room.
		var nat := _world_aabb(p3)
		var maxdim: float = max(nat.size.x, max(nat.size.y, nat.size.z))
		if maxdim > 6.0:
			p3.queue_free()   # a building/structure — not scatter decoration
			continue
		if minf(nat.size.x, nat.size.z) < 0.2:
			p3.queue_free()   # a flat billboard/decal plane — reads as a floating white sliver
			continue
		if maxdim > 2.5:
			var sc: float = 2.5 / maxdim
			p3.scale = Vector3(sc, sc, sc)
		# spacing: keep clear of the spawn centre + already-placed props (no overlap / z-fighting)
		var xz := _scatter_spot(size, placed)
		p3.position = Vector3(xz.x, 0.0, xz.y)
		placed.append(xz)
		# GROUND IT: .glb origins sit at base / centre / offset — drop the model so its LOWEST
		# point rests on the floor (y=0), instead of pinning the raw origin there (the float/sink bug).
		var gb := _world_aabb(p3)
		# ONLY DROP a floater to the ground; never LIFT. Models are authored for y=0 placement —
		# many rocks/roots are meant to sit partially EMBEDDED (mesh extends below origin), so lifting
		# them makes them float. Correct only meshes that sit ENTIRELY above the ground.
		p3.position.y -= maxf(0.0, gb.position.y)
		_add_prop_collision(p3, root)   # solid iff AABB max-dim >= SOLID_MIN_DIM (derived box)

	# named props (a specific tree/rock/etc. the AI or user placed at a position)
	for np in named:
		var purl := _palette_url(np)
		if purl == "" or not cache.has(purl):
			continue
		_cache_touch(purl)
		var n: Node = (cache[purl] as Node).duplicate()
		root.add_child(n)
		if n is Node3D:
			var n3 := n as Node3D
			var xz2 := _prop_xz(np)
			n3.position = Vector3(clamp(xz2.x, -size + 1.0, size - 1.0), 0.0, clamp(xz2.y, -size + 1.0, size - 1.0))
			n3.rotation.y = randf() * TAU
			var ab2 := _world_aabb(n3)
			var md: float = max(ab2.size.x, max(ab2.size.y, ab2.size.z))
			if md > 2.8:
				var s2: float = 2.8 / md
				n3.scale = Vector3(s2, s2, s2)
			# ground it: drop so the model's base rests on the floor (origins vary across .glb assets)
			var gn := _world_aabb(n3)
			n3.position.y -= maxf(0.0, gn.position.y)   # only drop floaters; never lift (see scatter note)
			# solid-by-default (SOLID_MIN_DIM contract); an explicit collider:"none" opts out
			if String(np.get("collider", "box")) != "none":
				_add_prop_collision(n3, root)

	var enemies: Array = []
	if enemy_n > 0 and cache.has(origin + SKELETON):
		_cache_touch(origin + SKELETON)
		for i in range(enemy_n):
			var e := CharacterBody3D.new()
			e.set_script(EnemyScript)
			root.add_child(e)
			var ang := TAU * float(i) / float(enemy_n)
			e.global_position = Vector3(cos(ang) * (size * 0.45), 0.0, sin(ang) * (size * 0.45))
			e.setup(player, (cache[origin + SKELETON] as Node).duplicate(), world_main, i, enemy_n)
			enemies.append(e)

	nav.bake_navigation_mesh(false)   # runtime bake behind the fade

	# 3. interactables — registered with the interaction system, visuals under this root
	interaction.set_area_parent(root)
	if rec.has("chest"):
		var c: Dictionary = rec.chest
		interaction.add_chest(_v3(c.pos), c.get("contents", []), int(c.get("gold", 0)))
	if rec.has("npc"):
		var npc: Dictionary = rec.npc
		if cache.has(origin + NPC_MODEL):
			_cache_touch(origin + NPC_MODEL)
		var model: Node = (cache[origin + NPC_MODEL] as Node).duplicate() if cache.has(origin + NPC_MODEL) else null
		interaction.add_npc(_v3(npc.pos), String(npc.get("id", "")), npc.name, npc.persona, npc.lines, model)
	for s in rec.get("seams", []):
		# a seam gate may be written `requires` OR `lock` — match the qgcheck validator (lockOf = requires||lock)
		var lk := String(s.get("requires", s.get("lock", "")))
		# `id` is what `unlock_seam` addresses; without threading it through, the parameter existed
		# and every rule that named a real seam still reported "no such seam".
		interaction.add_seam(_v3(s.pos), s.to, s.spawn, lk, s.get("label", "Door"), String(s.get("id", "")))

	return {root = root, enemies = enemies}


# ---------------- lazy region payload ----------------

# If `rec.region` names a loose JSON file (basename like "region_hall.json"), fetch it from the
# SAME base dir main.gd derives world_url from, and shallow-overlay ONLY density fields onto a
# LOCAL effective copy. Returns the effective record. Graph/winnability fields are untouched.
# The area's OPTIONAL integer `region_rev` (default 0) is threaded into the fetch so a density-only
# chat edit that bumps region_rev re-fetches fresh (vs. returning the stale cached parse).
# Any failure (no field / 404 / net fail / parse fail / non-Dictionary) returns the base record
# inline — a valid sparser room, never a hard-fail or crash.
func _apply_region(rec: Dictionary) -> Dictionary:
	if not rec.has("region"):
		return rec
	var basename := String(rec.get("region", "")).strip_edges()
	if basename == "":
		return rec
	var region_rev := int(rec.get("region_rev", 0))

	var region: Dictionary = await _fetch_region(basename, region_rev)
	if region.is_empty():
		return rec   # fetch/parse failed — fall back to the base record inline

	# build a LOCAL effective copy so the base `rec` (and world_data upstream) is never mutated
	var eff: Dictionary = rec.duplicate(true)
	for field in REGION_OVERLAY_FIELDS:
		if region.has(field):
			eff[field] = region[field]
	return eff


# Fetch + parse the loose region JSON, cached by basename + ":" + region_rev. Returns {} on ANY
# failure. The rev is part of the cache key (NOT basename alone) so a bumped region_rev re-fetches
# fresh while an unchanged rev stays cached; the same rev is also appended as a `?rev=` cache-buster
# so a just-uploaded region file can't be served stale from the R2 edge cache.
func _fetch_region(basename: String, region_rev: int) -> Dictionary:
	var key := basename + ":" + str(region_rev)
	if region_cache.has(key):
		var hit: Dictionary = region_cache[key]
		return hit

	var url := _region_base_dir() + basename + "?rev=" + str(region_rev)
	var req := HTTPRequest.new()
	req.timeout = 8.0   # a hung region fetch must not stall the area build behind the fade
	add_child(req)
	var err := req.request(url)
	if err != OK:
		req.queue_free()
		return {}
	var res = await req.request_completed   # [result, code, headers, body]
	req.queue_free()

	# res[0]=result, res[1]=code, res[3]=body
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return {}
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw.strip_edges() == "":
		return {}
	var parsed = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return {}   # parse fail / non-object — caller falls back to base
	var region: Dictionary = parsed
	region_cache[key] = region   # cache so re-entry at the SAME rev doesn't re-fetch
	return region


# Base dir for loose sibling files, derived the SAME way main.gd derives world_url / origin:
# world_url is ".../world.json"; strip the trailing "world.json" to get the dir. Falls back to
# origin + "/" if world_url wasn't wired (keeps the path crash-proof).
func _region_base_dir() -> String:
	if world_url != "" and world_url.ends_with("world.json"):
		return world_url.substr(0, world_url.length() - "world.json".length())
	if origin != "":
		return origin + "/"
	return ""


# ---------------- parallel download ----------------

func _ensure(urls: Array) -> void:
	# RE-ENTRANT: concurrent callers (vehicle spawn racing a cell build on a slow boot) used to
	# stomp a shared pending counter, releasing the earlier await before ITS fetches parsed —
	# vehicles then spawned off a cache miss as gray placeholder boxes (no hot-swap exists for
	# them). Each call now waits on ITS OWN url list; in-flight urls are deduped via _inflight.
	for u in urls:
		if cache.has(u):
			_cache_touch(u)   # LRU: an already-cached asset this build needs is RECENT (don't evict it mid-build)
			continue
		if _failed.has(u) or _inflight.has(u):
			continue
		_inflight[u] = true
		var req := HTTPRequest.new()
		add_child(req)
		req.request_completed.connect(_on_dl.bind(u, req))
		req.request(u)
	var guard := 0
	while guard < 2700:   # ~45s cap (raised for #9 retries + backoff on slow/cold loads)
		var waiting := false
		for u in urls:
			if not cache.has(u) and not _failed.has(u):
				waiting = true
				break
		if not waiting:
			return
		await get_tree().process_frame
		guard += 1


# Wave 4: the download callback NO LONGER parses inline. GLTFDocument.append_from_buffer +
# generate_scene are heavy and single-threaded (nothreads WASM); when many downloads land the same
# frame (an 18-asset R2 batch over HTTP/2) parsing them all inline stacked N generate_scene calls on
# one frame -> the hitch. Instead we queue the raw bytes and parse them AMORTIZED in _process (≤ a
# per-frame time budget). A url stays IN FLIGHT until parsed (or retries exhaust) — _ensure waits
# on cache/_failed per its own url list, never a shared counter.
func _on_dl(result: int, code: int, _h: PackedStringArray, body: PackedByteArray, url: String, req: HTTPRequest) -> void:
	req.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and body.size() > 0:
		_parse_queue.append({"url": url, "body": body})
	elif int(_retry.get(url, 0)) < FETCH_RETRIES:
		_retry[url] = int(_retry.get(url, 0)) + 1
		_refetch(url)   # #9: transient failure -> re-download after a short backoff (the _ensure slot stays HELD)
	else:
		_failed[url] = true   # retries exhausted: release waiters -> the neutral gray "loading" placeholder shows
		_inflight.erase(url)
		print("GOGI_PLACEHOLDER scenery ", url)   # verify.mjs asset-fail gate: a placeholder is now visible


# #9: re-issue a failed/corrupt download after a short backoff. The url stays IN FLIGHT (not marked
# failed), so every _ensure gate waits for the retry instead of spawning a placeholder. This is the
# vehicle/enemy/NPC-model equivalent of the hero's retry — the red boxes were a transient fetch race.
func _refetch(url: String) -> void:
	await get_tree().create_timer(0.25 * float(maxi(1, int(_retry.get(url, 1))))).timeout
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(_on_dl.bind(url, req))
	req.request(url)


# Drain the GLB parse queue under a per-frame time budget so a big batch spreads across frames
# instead of hitching one. Always parses at least one (so the queue can't stall), then stops once
# the budget is spent; the rest continue next frame. Runs every frame incl. during _ensure's await.
func _process(_delta: float) -> void:
	if _threaded_parse:
		_process_threaded()
		return
	if _parse_queue.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	while not _parse_queue.is_empty():
		var item: Dictionary = _parse_queue.pop_front()
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_buffer(item["body"], "", st) == OK:
			var scene := doc.generate_scene(st)
			GSurf.cap_textures_for_web(scene)   # mobile VRAM: shrink Meshy textures ONCE per template (web only)
			_cache_put(item["url"], scene)
			_inflight.erase(item["url"])
			_retry.erase(item["url"])   # a later re-download (LRU eviction) gets fresh retries
		elif int(_retry.get(item["url"], 0)) < FETCH_RETRIES:
			_retry[item["url"]] = int(_retry.get(item["url"], 0)) + 1
			_refetch(item["url"])   # #9: corrupt/partial body -> re-download (the _ensure slot stays HELD)
		else:
			_failed[item["url"]] = true
			_inflight.erase(item["url"])
			print("GOGI_PLACEHOLDER scenery ", item["url"])
		if Time.get_ticks_usec() - t0 > PARSE_BUDGET_US:
			break


# NATIVE drain: hand queued GLBs to worker threads, then pick up whatever finished.
#
# No time budget is needed or wanted here — the expensive half no longer runs on this thread, so
# there is nothing to amortize. What remains (a dictionary insert and some bookkeeping) is free.
func _process_threaded() -> void:
	# 1. submit — capped, because 18 concurrent parses would spike peak memory holding 18 decoded
	#    scenes at once, and memory is the resource that actually fails on this phone.
	while not _parse_queue.is_empty() and _parse_tasks.size() < PARSE_THREADS:
		var item: Dictionary = _parse_queue.pop_front()
		var id := WorkerThreadPool.add_task(_parse_worker.bind(item), false, "gogi_glb_parse")
		_parse_tasks[id] = item["url"]

	# 2. collect — swap the buffer under the lock and release it immediately, so a worker finishing
	#    mid-drain never blocks on the main thread (and we never hold the lock across engine calls).
	if _parse_done.is_empty():
		return
	_parse_mutex.lock()
	var done: Array = _parse_done
	_parse_done = []
	_parse_mutex.unlock()

	for r in done:
		var url: String = r["url"]
		var scene = r["scene"]
		for id in _parse_tasks.keys():
			if _parse_tasks[id] == url:
				WorkerThreadPool.wait_for_task_completion(id)   # returns instantly; reaps the slot
				_parse_tasks.erase(id)
				break
		if scene != null:
			GSurf.cap_textures_for_web(scene)   # no-op off-web; kept for a single shared code path
			_cache_put(url, scene)
			_inflight.erase(url)
			_retry.erase(url)
		elif int(_retry.get(url, 0)) < FETCH_RETRIES:
			_retry[url] = int(_retry.get(url, 0)) + 1
			_refetch(url)
		else:
			_failed[url] = true
			_inflight.erase(url)
			print("GOGI_PLACEHOLDER scenery ", url)


# Runs on a WORKER THREAD. Touches nothing shared except _parse_done (mutex-guarded) — no scene
# tree, no _cache/_inflight/_retry, no printing. GLTFDocument builds Resources and Nodes, which is
# thread-safe in Godot 4 (the RenderingServer is command-buffered); adding them to the tree is NOT,
# so that stays in _process_threaded above.
func _parse_worker(item: Dictionary) -> void:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var scene: Node = null
	if doc.append_from_buffer(item["body"], "", st) == OK:
		scene = doc.generate_scene(st)
	_parse_mutex.lock()
	_parse_done.append({"url": item["url"], "scene": scene})
	_parse_mutex.unlock()


# A worker holds a Callable bound to THIS node. Freeing the builder with tasks in flight would let a
# thread write into a dead object, so block until every outstanding parse has finished first.
func _exit_tree() -> void:
	for id in _parse_tasks.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	_parse_tasks.clear()


# ---------------- bounded LRU for the GLB template cache ----------------

# Mark a cached url as most-recently-used. Called on every cache hit + insert so a long
# chunk roam evicts the assets it LEFT BEHIND, never the ones the current area still uses.
func _cache_touch(url: String) -> void:
	var idx := _cache_order.find(url)
	if idx != -1:
		_cache_order.remove_at(idx)
	_cache_order.append(url)


# Insert a downloaded template node, evicting (and FREEING) the least-recently-used entries
# beyond GLB_CACHE_CAP. Evicted templates are re-downloaded by _ensure if needed again later.
func _cache_put(url: String, node: Node) -> void:
	if cache.has(url) and cache[url] != node:
		_free_template(cache[url])   # racing duplicate download for the same url — drop the old copy
	cache[url] = node
	_cache_touch(url)
	while _cache_order.size() > GLB_CACHE_CAP:
		var lru: String = _cache_order.pop_front()
		var evicted: Node = cache.get(lru)
		cache.erase(lru)
		_free_template(evicted)


# Cache entries are generate_scene() output held OUTSIDE the tree purely as .duplicate()
# sources, so they must be free()d manually (a Node outside the tree never auto-frees);
# queue_free() only applies if one somehow ended up inside the tree. Duplicates already
# placed in areas are independent nodes (their meshes/materials are refcounted Resources),
# so freeing the template never breaks a live scene.
func _free_template(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	if n.is_inside_tree():
		n.queue_free()
	else:
		n.free()


# ---------------- build helpers ----------------

func _build_room(root: Node, size: float, ground_spec) -> NavigationRegion3D:
	var nav := NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.7
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.navigation_mesh = nm
	root.add_child(nav)
	_ground_box(nav, Vector3(0, -0.5, 0), Vector3(size * 2, 1, size * 2), ground_spec)
	var ground_col := _spec_color(ground_spec)
	var wall := Color(ground_col.r * 0.7, ground_col.g * 0.7, ground_col.b * 0.78)
	_box(nav, Vector3(0, 1.5, -size), Vector3(size * 2, 4, 1), wall)
	_box(nav, Vector3(0, 1.5, size), Vector3(size * 2, 4, 1), wall)
	_box(nav, Vector3(-size, 1.5, 0), Vector3(1, 4, size * 2), wall)
	_box(nav, Vector3(size, 1.5, 0), Vector3(1, 4, size * 2), wall)
	return nav


func _box(parent: Node, pos: Vector3, sz: Vector3, col: Color, cast_shadow := true) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = _mat(col)
	if not cast_shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # e.g. the chunk floor slab -> no self-acne
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = sz
	cs.shape = bs
	body.add_child(cs)
	parent.add_child(body)


func _add_prop_collision(prop: Node3D, parent: Node) -> void:
	# Derive a solid box collider from the prop's mesh bounds. Called on the PLACED INSTANCE
	# (post-.duplicate()) and parented alongside the visual, so the collider is NEVER baked into
	# the cached GLB template and area/cell teardown (root.queue_free) reclaims it. Solidity is
	# the SOLID_MIN_DIM shared contract: largest world-AABB dimension >= 0.45m -> solid;
	# smaller -> step-over decoration, no collider (also covers a degenerate/meshless AABB).
	var aabb := _world_aabb(prop)
	if maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) < SOLID_MIN_DIM:
		return                       # step-over decoration (pebbles/grass/decals) — walkthrough
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# clamp the footprint a touch so tall canopies (trees) don't block a huge radius
	box.size = Vector3(
		clamp(aabb.size.x, 0.2, 3.5),
		max(aabb.size.y, 0.4),
		clamp(aabb.size.z, 0.2, 3.5))
	cs.shape = box
	body.add_child(cs)
	parent.add_child(body)
	# _world_aabb boxes are in the prop's PARENT frame (same frame as this
	# body's `position` since both share `parent`) — plain local assignment,
	# valid even while the subtree is still detached (global_position would
	# error + misplace there).
	body.position = aabb.position + aabb.size * 0.5


func _world_aabb(root: Node3D) -> AABB:
	# DETACHMENT-SAFE: accumulates transforms manually (root's own transform
	# included, expressed in root's parent frame). This helper is almost
	# always called on freshly-duplicated, NOT-YET-PARENTED models (grounding
	# + scale normalization) — there `global_transform` returns IDENTITY and
	# spams "!is_inside_tree()" errors, silently producing wrong AABBs
	# whenever inner GLB node transforms matter (a root cause of the old
	# floating/sunk-prop class of bugs).
	var merged := AABB()
	var first := true
	var stack: Array = [[root, root.transform]]
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


func _scatter_spot(size: float, placed: Array) -> Vector2:
	# pick a spot >= MIN apart from already-placed props and clear of the spawn centre;
	# fall back to a raw random spot after a few tries so placement never stalls.
	var fallback := Vector2(randf_range(-size + 2.0, size - 2.0), randf_range(-size + 2.0, size - 2.0))
	for _try in range(6):
		var c := Vector2(randf_range(-size + 2.0, size - 2.0), randf_range(-size + 2.0, size - 2.0))
		if c.length() < 3.0:
			continue
		var ok := true
		for q: Vector2 in placed:
			if c.distance_to(q) < 2.2:
				ok = false
				break
		if ok:
			return c
	return fallback


func _palette_url(np) -> String:
	if typeof(np) != TYPE_DICTIONARY:
		return ""
	var kind := String(np.get("kind", "")).to_lower().strip_edges()
	return (origin + PALETTE[kind]) if PALETTE.has(kind) else ""


# The authored [x, y, z] of one named prop, as an XZ pair. world.json is written by the
# agent, so `pos` is untrusted: it can be missing, short ([5, 0]), or not an array at all.
# The old code indexed pos[0]/pos[2] raw — fine while this whole path was stubbed out, a
# runtime "Invalid get index '2'" the moment it was re-enabled, and NOTHING catches the
# shape upstream (verify.mjs only counts props; qgcheck never reads them). An unusable pos
# falls back to the area centre — exactly what an absent `pos` already did.
func _prop_xz(np) -> Vector2:
	if typeof(np) != TYPE_DICTIONARY:
		return Vector2.ZERO
	var pos = np.get("pos", null)
	if not (pos is Array) or pos.size() < 3:
		return Vector2.ZERO
	return Vector2(_num(pos[0]), _num(pos[2]))


# float() raises on a Dictionary/Array/null, so coerce only what is actually numeric.
func _num(v) -> float:
	var t := typeof(v)
	if t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_BOOL:
		return float(v)
	if t == TYPE_STRING and String(v).is_valid_float():
		return String(v).to_float()
	return 0.0


func _v3(a) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _col(a) -> Color:
	return Color(a[0], a[1], a[2])


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


# ---------------- textured ground (the "real surface, not a flat colored plane" system) ----------------

# A floor/ground slab whose top surface is a tiled, relief-mapped material. `spec` may be a NAMED
# preset string ("sand"/"asphalt"/…), a {material,color,…} dict, or a legacy [r,g,b] array — all get
# a procedural normal map so the ground reads as a believable surface. cast_shadow=false by default
# (a big flat floor casting into the shadowmap self-shadows into acne).
func _ground_box(parent: Node, pos: Vector3, sz: Vector3, spec, cast_shadow := false) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = _ground_mat(spec)
	if not cast_shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = sz
	cs.shape = bs
	body.add_child(cs)
	parent.add_child(body)


# Build (cached) a tiled ground material with a procedural normal map for surface relief.
func _ground_mat(spec) -> StandardMaterial3D:
	var key := var_to_str(spec)
	if _ground_mat_cache.has(key):
		return _ground_mat_cache[key]
	var p := _ground_params(spec)
	var m := StandardMaterial3D.new()
	m.albedo_color = p["color"]
	m.roughness = p["rough"]
	m.metallic = 0.0
	m.uv1_scale = Vector3(p["tiling"], p["tiling"], p["tiling"])
	m.normal_enabled = true
	m.normal_texture = _noise_normal(int(p["seed"]), float(p["bump"]))
	m.normal_scale = clampf(float(p["bump"]), 0.0, 1.0)
	_ground_mat_cache[key] = m
	return m


# Resolve any ground spec form -> {color, rough, tiling, bump, seed}.
func _ground_params(spec) -> Dictionary:
	var out := {"color": Color(0.3, 0.33, 0.38), "rough": 0.92, "tiling": 10.0, "bump": 0.22, "seed": 1}
	if typeof(spec) == TYPE_STRING:
		var nm := String(spec).to_lower().strip_edges()
		if GROUND_PRESETS.has(nm):
			_apply_preset(out, GROUND_PRESETS[nm])
	elif typeof(spec) == TYPE_ARRAY and (spec as Array).size() >= 3:
		out["color"] = _col(spec)
	elif typeof(spec) == TYPE_DICTIONARY:
		var d: Dictionary = spec
		var nm2 := String(d.get("material", d.get("preset", ""))).to_lower().strip_edges()
		if GROUND_PRESETS.has(nm2):
			_apply_preset(out, GROUND_PRESETS[nm2])
		if d.has("color"):
			out["color"] = _col(d["color"])
		if d.has("rough"):
			out["rough"] = float(d["rough"])
		if d.has("tiling"):
			out["tiling"] = float(d["tiling"])
		if d.has("bump"):
			out["bump"] = float(d["bump"])
	out["seed"] = int(float(out["tiling"]) * 7.0) + int((out["color"] as Color).r * 255.0) + int((out["color"] as Color).b * 91.0)
	return out


func _apply_preset(out: Dictionary, pr: Dictionary) -> void:
	out["color"] = _col(pr["color"])
	out["rough"] = float(pr["rough"])
	out["tiling"] = float(pr["tiling"])
	out["bump"] = float(pr["bump"])


# Representative flat color for any ground spec (wall tint + nav fallback).
func _spec_color(spec) -> Color:
	return _ground_params(spec)["color"]


# A tiling, seamless procedural normal map (FastNoiseLite -> NoiseTexture2D as_normal_map). Runtime-
# generated, so no asset dependency and it works offline / on any build.
func _noise_normal(seed_i: int, bump: float) -> NoiseTexture2D:
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.frequency = 0.05
	fn.seed = seed_i
	fn.fractal_octaves = 3
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = maxf(0.6, bump * 16.0)
	nt.noise = fn
	return nt
