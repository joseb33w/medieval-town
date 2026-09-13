class_name ChunkManager extends Node
## CHUNK MANAGER — resident-RING streaming for mode=="chunk" worlds. Maintains a 3x3 ring of
## live cells around the player (Chebyshev radius RING_RADIUS), builds AT MOST ONE queued cell
## per frame (no ring-shift burst -> no main-thread jank), and EVICTS cells outside the ring
## (queue_free root+enemies) — eviction is what BOUNDS memory so the ring fits mobile Safari.
##
## This REPLACES SceneManager for chunk worlds. The one-resident ZONE path (mode!="chunk") is
## untouched — main.gd dispatches on world.mode and routes combat/HUD reads to whichever streamer
## is active. We deliberately expose the SAME public fields SceneManager does
## (enemies / current_id / current_root / transitioning) so those reads stay drop-in.
##
## NAV: props are gone -> the ground is flat, so we use ONE shared flat NavigationRegion3D sized
## to the ring instead of a per-cell runtime bake (the per-cell bake is the main-thread stall the
## prototype must avoid + would corrupt the memory/jank number). enemy.gd also direct-chases when
## the path is degenerate, so a missing/rebuilding region still chases.
##
## HOT-RELOAD (B2): reload(new_world) re-parses the grid in place when the polled world.json
## changes. RESIDENT cells whose record actually CHANGED are rebuilt at the SAME world offset
## (no player move, no fade); non-resident cells just refresh their grid record so the new layout
## is applied the next time they stream in. This is the chunk-mode counterpart of
## SceneManager.reload — which (wrongly for a ring) rebuilds the whole area behind a fade
## (it keeps the player's position, but a full rebuild + fade is still wrong for a ring).
##
## FAR RING: behind the resident ring sits a second, CHEAP ring of far-PROXY cells
## (RING_RADIUS < d <= FAR_RADIUS) so the world reads as a continuous place from afar instead of
## ending abruptly at the ring's edge. A proxy is silhouette-only: the ground + parametric structure
## shells (SOLID — the "interior" key is stripped, so no interior geometry / "gogi_door" leaves /
## interior lights ever exist in a proxy) + road strips — NO props, NO GLB/network fetches, NO
## scatter/populate/NPC/chest/door/enemy/traffic, and ZERO colliders. Proxies build through the same one-per-frame queue (residents
## always outrank them), demote (evicted resident -> proxy) and promote (proxy freed the moment the
## full build starts) as the ring moves, and stale ones beyond FAR_RADIUS are LRU-freed under a
## FAR_CAP ceiling so far-ring memory stays strictly bounded.
##
## COLLISION IS SOLID-BY-DEFAULT: every placement path here (props/landmark, populate, scatter)
## gives an object a static collider when its world AABB's largest dimension >= SOLID_MIN_DIM (the
## shared 0.45m contract, world-streaming.md §8); anything smaller is walkthrough decoration. A spec
## opts out with collider:false/"none". Scatter keeps its single MultiMesh draw call and carries its
## shapes in a parallel StaticBody3D container. Traffic cars are normalized to CAR_TARGET_LEN
## (longest horizontal dimension) before grounding so a toy-scale GLB never reads as a toy.

const SKELETON := "/godot-assets/enemies/skeleton_warrior.glb"
const EnemyScript := preload("res://enemy.gd")

const RING_RADIUS := 1                 # Chebyshev radius -> 3x3 footprint
# Wave 4 P6 ("see more of the world from afar"): FAR_RADIUS 3 -> 5 (7x7 -> 11x11 proxy ring, ~176m
# visible) — affordable now that proxies bake NO colliders (P4). FAR_CAP raised to match the bigger
# ring (11x11 - 3x3 resident = 112 proxies + headroom).
const FAR_RADIUS := 4                  # far-PROXY ring radius: silhouette-only cells past the resident ring (5->4: ~112->72 proxies, fewer per-move builds; the ~160m skyline still fills the horizon)
const FAR_CAP := 96                    # LRU ceiling on live far proxies (bounds far-ring memory). Lowered 128->96 for #10/#8 mobile-OOM headroom (the "sudden refresh" is a mobile tab-crash-reload under memory pressure, not a code reload)
const REAL_DETAIL_RADIUS := 2          # far cells WITHIN this Chebyshev distance of the player render REAL prop/scatter GLBs; beyond it, ground+structure silhouettes only. Bounds the far-ring draw calls (a tree at 60m+ is a few pixels) — mobile FPS
# FAR "LIFE" STAND-INS — OFF. build_proxy used to drop STATIC, deliberately un-animated duplicates of
# a far cell's enemies / crowds / NPC into the distance so the world read as populated from range. The
# intent was good and the cost was low, but the RESULT reads as broken: a herd of dinosaurs standing
# perfectly frozen mid-stride is more noticeable, and more damaging to the illusion, than empty
# scenery would be. Player verdict on a real device: "I see the dinosaurs frozen from afar. I don't
# like that." Empty distance beats wrong distance.
# Turning this off also removes SKINNED draws from the far ring — the most expensive kind — so it
# helps the framerate as well. Flip FAR_LIFE back to true to restore the old behaviour; the caps
# below are kept so it still works if re-enabled.
const FAR_LIFE := false
const PROXY_ENEMY_CAP := 3             # max STATIC enemy stand-ins per far cell (a skinned dup costs more than a rock)
const PROXY_POP_CAP := 4               # max static populate (animal/crowd) stand-ins per populate entry per far cell
const LIFE_MAX_DIM := 4.0              # far-life stand-in: SHRINK-ONLY a model whose max AABB dim exceeds this...
const LIFE_TARGET_DIM := 2.0           # ...down to ~this, so an oversized library beast can't fill the sky from the air (never scales UP)
const PROXY_LIFE_VIS_END := 95.0       # metres past which a far-life dup fades out (bounds skinned draw): still > REAL_DETAIL reach (48m) + plane altitude line-of-sight (~62m), but 130->95 culls the farthest barely-visible skinned dummies a flyer renders = fewer skinned draws in the air
# Wave 4 P6 SKYLINE tier: cells in the Chebyshev band (FAR_RADIUS, SKYLINE_RADIUS] render ONLY their
# structures, as ONE merged material-less silhouette mesh (no ground/roads/props/colliders/lights) —
# a distant city skyline for pennies (1 draw call). SKYLINE_RADIUS 10 cells ~= 160m past the proxies.
const SKYLINE_RADIUS := 10
const MAX_RESIDENT_CELLS := 9          # hard cap = (2*RING_RADIUS+1)^2 = 9
const PROP_CAP := 12                    # max INDIVIDUAL props placed per cell (live-node budget is 9*N)
const SCATTER_MAX := 40                 # max instances per MultiMesh scatter entry (1 draw call regardless)
const POP_WEB_CAP := 16                 # WEB/mobile: max LIVE populate instances per crowd entry. A "tribe"/herd can author up to 30
                                        # high-poly SKINNED characters; instancing all 30 in one cell build = a frame spike, and drawing 30
                                        # skinned meshes at once tanks a mobile GPU (runtime GLBs have no LOD). 16 still reads as a real crowd.
                                        # Desktop keeps the full authored count. Far proxies already use the tighter PROXY_POP_CAP.
# Per-frame WALL-CLOCK budget for building far proxies (mirrors area_builder's PARSE_BUDGET_US). A fixed
# COUNT budget hitches on dense cells (one cell can deep-clone 4 props + a dozen life stand-ins) and
# starves on empty ones. Bounding by TIME (always building >=1 so the queue can't stall) caps the
# worst-case per-frame proxy cost regardless of how heavy the popped cells are -> smooth flight.
const PROXY_BUDGET_US := 3500           # ~3.5ms/frame ceiling on proxy instantiation (leaves the frame's rest for render+physics)
const LIVE_ENEMY_BUDGET := 6            # HARD ring-wide ceiling on SIMULTANEOUS live skinned enemies. A raptor camp authors 5/cell across
                                        # many cells; on foot (9 resident cells) that's up to 45 high-poly skinned characters drawn+skinned
                                        # every frame on the mobile GPU (no runtime LOD) = the "lag around heavy assets". Nearest/forward cells
                                        # fill the budget first (forward-bias); the rest stay far static proxies. Evicting a cell frees its slots.
const MAX_ENEMIES_PER_CELL := 3         # cap live per-cell enemies (5->3: fewer high-poly SKINNED Meshy draws on the mobile GPU near a camp; the ring-wide LIVE_ENEMY_BUDGET is the hard ceiling). Each = a skinned GLB + a per-frame
                                        # NavigationAgent/RVO tick); a camp authoring 40 tanks the framerate
                                        # when they cluster near the player. 9 resident cells * 8 is the ceiling.
const BIG_ASSET_DIM := 8.0              # a prop/creature this large stops casting shadows (its big skinned/
                                        # mesh shadow pass is the main cost behind "huge monster" lag)
# Wave 3 (world structure): a structure landing within STRUCT_COINCIDE metres of one already placed in
# the cell is nudged up STRUCT_ZLIFT metres so physically-overlapping equal-height buildings don't
# z-fight (the author error itself is WARNed by verify). A tiny lift kills the coplanar-face shimmer
# without visibly moving the building.
const STRUCT_COINCIDE := 1.5
const STRUCT_ZLIFT := 0.04
# SHARED CONTRACT (world-streaming.md §8): an object is SOLID — it gets a static collider — when its
# world AABB's largest dimension >= 0.45m; anything smaller is walkthrough decoration. Every placement
# path here uses this one threshold, and other placement writers (vehicles etc.) pin the same value.
const SOLID_MIN_DIM := 0.45
const CAR_TARGET_LEN := 4.0            # traffic cars scaled so their longest HORIZONTAL dim = a sedan-ish 4m
const DEFAULT_GROUND := [0.3, 0.33, 0.38]   # matches area_builder build_area fallback

# --- public surface mirrored from SceneManager (main.gd reads these in chunk mode) ---
var enemies: Array = []                # UNION of every resident cell's live enemies
var current_root: Node3D = null        # non-null sentinel so main._physics_process gate passes
var current_id := "chunk"              # the resident cell's area id (HUD + reach_area target)
var transitioning := false             # chunk mode never fades, so always false after setup

# Emitted when the player crosses into a new cell — main.gd wires it to quest.notify_area
# so reach_area objectives + the world goal progress in chunk mode EXACTLY as in zone mode.
# The id matches the reassembler's idFor(gx,gz) = "c<gx>_<gz>", so quest reach_area targets
# and the qgcheck goal cell line up with what the runtime reports (full winnability parity).
signal area_entered(area_id: String)

# --- wiring (set in setup) ---
var builder: AreaBuilder               # reusable asset/cache/download layer + _box/_col/_mat helpers
var player: Node3D
var world_main: Node                   # passed to enemy.setup as `world` (-> on_enemy_killed)
var env: Environment
var interaction: InteractionSystem     # chunk npc/chest/door registration (per-cell, evict-cleaned)
var rpg: RpgState                      # for enemy/quest hooks parity with the zone path

# --- chunk world data ---
var cell_size := 16.0
var grid := {}                         # cell_key "gx,gz" -> cell record Dictionary
var start_cell := Vector2i.ZERO
var default_npc_model := ""            # world-level fallback character for NPCs with no own model
									   # (set a setting-appropriate one so unmodelled NPCs aren't a
									   # medieval knight in a modern city)
var terrain: GTerrain = null           # OPT-IN rolling terrain (world.json top-level `terrain`). When set, each
									   # cell floor is a heightmap mesh + collider and EVERY placed object is
									   # lifted onto the surface via _ground_y(); null = flat floor (cities).

# --- resident ring state ---
var resident := {}                     # cell_key "gx,gz" -> { root: Node3D, enemies: Array }
var _bridges := {}                     # cell_key -> bridge rig Node3D. Bridges are PERSISTENT (parented to world_main,
                                       # NOT the authoring cell's root): a long deck spans up to 2 cells, so if it evicted
                                       # with its cell a crosser lost the deck under their feet at the far end. Built once,
                                       # freed only when the player roams far (LRU-ish in _update_ring).
var _build_queue: Array = []           # Array[Vector2i] of in-ring cells awaiting build (FIFO-ish)
var _cur_cell := Vector2i(2147483647, 0)   # forces a ring update on the first frame
var _building := false                 # guards the at-most-one-per-frame async build
var _started := false
var _heading := Vector2i.ZERO          # last non-zero grid-step direction (for pre-warm ordering)
var _reloading := false                # guards a hot-reload rebuild so tick's per-frame build waits
var _last_stream_pos := Vector2(1e9, 1e9)   # last frame's player XZ, for stream-speed
var _stream_speed := 0.0               # planar cells/sec (drives the build budget: a plane outruns 1 build/frame)
var _hi_air := false                   # player high above the terrain (flying) -> full residents are wasted (flight LOD)
var _warming := false                  # a background flight asset-warm coroutine is in flight (keeps far proxies non-bare while flying)
# Wave 3 spawn-clearance: cell_key -> Array of {c:Vector2 world-xz centre, r:float footprint radius}
# for every placed resident structure; cleared on _evict. nudge_out() pushes a spawn (player/vehicle)
# out of any structure it lands inside, so a world authoring a spawn on top of a building can't strand.
var _struct_foots := {}

# --- far-proxy ring state (silhouettes past the resident ring; see FAR RING in the header) ---
var _proxies := {}                     # cell_key -> Node3D proxy root (ground+structures+roads, NO colliders)
var _proxy_lru: Array = []             # cell_key order, most-recently-wanted LAST (FAR_CAP eviction order)
var _proxy_queue: Array = []           # Array[Vector2i] proxies awaiting a frame slot (residents outrank)

# --- shared flat nav ---
var _nav_region: NavigationRegion3D = null
var _nav_root: Node3D = null           # parents the shared nav + apron colliders (never evicted)
var _far: MeshInstance3D = null        # the far-horizon terrain skirt (terrain worlds), recentred on the player
var _far_centre := Vector2(1e9, 1e9)
var water_cfg = null                   # OPT-IN ocean/sea (world.json top-level `water`); null = no water
var water_level := 0.0
var _water: MeshInstance3D = null      # the animated water body, recentred on the player like the far skirt
var _water_centre := Vector2(1e9, 1e9)
var _skyline: MeshInstance3D = null    # Wave 4 P6: distant structures merged into ONE silhouette mesh (no colliders)
var _skyline_cell := Vector2i(0x3fffffff, 0x3fffffff)   # player cell the skyline mesh was last built around


func setup(p: Node3D, b: AreaBuilder, main: Node, environment: Environment, inter: InteractionSystem = null, state: RpgState = null) -> void:
	player = p
	builder = b
	world_main = main
	env = environment
	interaction = inter
	rpg = state


# Called by main._boot when world.mode == "chunk" (in place of scene_manager.start()).
func start(world: Dictionary) -> void:
	cell_size = float(world.get("grid", {}).get("cell_size", 16.0))
	if cell_size <= 0.0:
		cell_size = 16.0

	var sc: Array = world.get("start_cell", [0, 0])
	if sc.size() >= 2:
		start_cell = Vector2i(int(sc[0]), int(sc[1]))

	default_npc_model = String(world.get("default_npc_model", ""))

	# OPT-IN terrain: a top-level `terrain` dict (or `true`) turns on rolling heightmap ground.
	var tcfg = world.get("terrain", null)
	if typeof(tcfg) == TYPE_DICTIONARY or tcfg == true:
		terrain = GTerrain.new()   # a RefCounted helper; held by this var, not a tree node
		terrain.setup(tcfg if typeof(tcfg) == TYPE_DICTIONARY else {})
	else:
		terrain = null

	# OPT-IN water: a top-level `water` dict turns on an animated ocean/sea (water.gd) at `level`.
	var wcfg = world.get("water", null)
	if typeof(wcfg) == TYPE_DICTIONARY or wcfg == true:
		water_cfg = wcfg if typeof(wcfg) == TYPE_DICTIONARY else {}
		water_level = float(water_cfg.get("level", 0.0))
	else:
		water_cfg = null

	# index every authored cell by its "gx,gz" key
	grid.clear()
	for c in world.get("cells", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc: Array = c.get("cell", [])
		if cc.size() < 2:
			continue
		grid[_key(int(cc[0]), int(cc[1]))] = c

	# tint the SHARED env ONCE (per-cell tinting would flicker as the ring shifts);
	# skipped entirely when the Weather3D system owns the sky/ambient.
	if env and not env.has_meta("weather_owned"):
		var a = world.get("ambient", [0.6, 0.6, 0.66])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)

	# build the persistent nav holder + the shared flat NavigationRegion3D
	_nav_root = Node3D.new()
	world_main.add_child(_nav_root)
	_rebuild_shared_nav()

	# place the persistent player on the start cell centre (lifted onto the terrain + a little, so it drops on)
	var spawn := _cell_centre(start_cell.x, start_cell.y)
	spawn.y = _ground_y(spawn.x, spawn.z) + 1.5
	player.global_position = spawn
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO

	# non-null sentinel so main._physics_process's `current_root == null` gate passes in chunk mode
	current_root = _nav_root
	current_id = "chunk"
	transitioning = false
	_started = true

	# build the start cell immediately so the player never spawns over a hole, then seed the ring
	_cur_cell = start_cell
	await _build_cell_at(start_cell.x, start_cell.y)
	# now the start cell's structures exist: push the player out if the world authored the start on
	# top of a building (spawn-clearance), then re-ground so it still drops onto the terrain.
	var clear := nudge_out(player.global_position, 0.6)
	clear.y = _ground_y(clear.x, clear.z) + 1.5
	player.global_position = clear
	_update_ring(start_cell)
	_update_far(player.global_position)   # build the far horizon (terrain worlds)
	_update_water(player.global_position) # build the ocean/sea (water worlds)
	_update_skyline(start_cell)           # Wave 4 P6: build the distant merged-silhouette skyline
	# announce the spawn cell so a reach_area objective on the start cell counts immediately
	current_id = _area_id(start_cell)
	area_entered.emit(current_id)


# Driven every frame from main._process (which already reads player.global_position).
func tick(delta: float) -> void:
	if not _started:
		return

	var here := _player_cell()
	# STREAM SPEED (planar cells/sec) + ALTITUDE (above terrain) drive the flight LOD below. player.global_position
	# already tracks the plane (vehicle parks the driver on it), so no new wiring is needed.
	var pxz := Vector2(player.global_position.x, player.global_position.z)
	if _last_stream_pos.x < 1e8 and delta > 0.0:
		_stream_speed = (pxz.distance_to(_last_stream_pos) / delta) / cell_size
	_last_stream_pos = pxz
	_hi_air = (player.global_position.y - _ground_y(player.global_position.x, player.global_position.z)) > 14.0
	if here != _cur_cell:
		var step := here - _cur_cell
		if step != Vector2i.ZERO:
			_heading = Vector2i(signi(step.x), signi(step.y))
		_cur_cell = here
		_update_ring(here)
		# Wave 4: stagger the two heavy full re-meshes — never rebuild the far skirt AND the water on
		# the same frame (each is a ~224m-radius re-mesh). If the skirt rebuilt this recentre, defer
		# water to a later cell-cross frame; its own 2-cell gate still keeps it current.
		if not _update_far(player.global_position):
			_update_water(player.global_position)
		_update_skyline(here)                 # Wave 4 P6: distant merged-silhouette skyline ring
		# crossing into a new cell counts as entering its area (reach_area + goal progression)
		current_id = _area_id(here)
		area_entered.emit(current_id)
		if _hi_air and not _warming:
			_warm_flight()   # flying: keep the region's asset cache warm so far proxies show REAL props/life, not bare ground

	# build AT MOST ONE queued cell per frame (await keeps it a single in-flight build). Pause the
	# per-frame stream while a hot-reload rebuild is in flight so the two builds never interleave.
	# RESIDENT builds always take the frame slot before far proxies, so walking forward never
	# stalls behind horizon dressing; a proxy build is synchronous (fetches nothing) so it fits
	# the slot without an await.
	if not _building and not _reloading and not _build_queue.is_empty():
		var next: Vector2i = _build_queue.pop_front()
		if not resident.has(_key(next.x, next.y)) and grid.has(_key(next.x, next.y)):
			_building = true
			await _build_cell_at(next.x, next.y)
			_building = false
	# PROXIES are synchronous (fetch nothing). Drain under a per-frame TIME budget (not a fixed count): a
	# dense cell deep-clones props + life stand-ins and costs ~10x an empty one, so a fixed count hitches on
	# the dense frames a plane keeps hitting. Always build at least one (the queue can't stall), then keep
	# going only while under PROXY_BUDGET_US -> the worst-case per-frame proxy cost is bounded regardless of
	# how heavy the popped cells are. This is THE plane-smoothness lever (residents stay 1/frame; rr=0 in air).
	var pt0 := Time.get_ticks_usec()
	var pbuilt := 0
	while not _building and not _reloading and not _proxy_queue.is_empty():
		var pnext: Vector2i = _proxy_queue.pop_front()
		var pd := _cheb(pnext, _cur_cell)
		if pd > RING_RADIUS and pd <= FAR_RADIUS:   # stale queue entries (player moved) just drop
			_build_proxy_at(pnext.x, pnext.y)
			pbuilt += 1
		if pbuilt >= 1 and Time.get_ticks_usec() - pt0 > PROXY_BUDGET_US:
			break

	_drain_shapes()   # attach trimesh colliders baked off-thread since the last tick (native only)
	_drain_meshes()   # swap in horizon skirt/water rebuilt off-thread (native only)
	_prune_enemies()


# BACKGROUND flight asset-warm: while airborne the resident ring collapses to 1 cell (altitude LOD), so few
# GLBs get cached and the far proxies (cache-only) show BARE GROUND. This fetches the prop/scatter/enemy/
# populate/npc GLBs for cells a bit WIDER than the real-prop ring (async; _ensure dedupes — only unique+uncached
# actually download), so cells enter the far ring already-cached and their proxies render REAL props/life.
# Fire-and-forget, guarded so only one runs; the download is async I/O (never a CPU hitch), bounded by the
# world's unique-asset set.
func _warm_flight() -> void:
	_warming = true
	var urls: Array = []
	var r := REAL_DETAIL_RADIUS + 2
	for gx in range(_cur_cell.x - r, _cur_cell.x + r + 1):
		for gz in range(_cur_cell.y - r, _cur_cell.y + r + 1):
			var k := _key(gx, gz)
			if grid.has(k):
				_gather_life_urls(grid[k], urls)
	if not urls.is_empty():
		await builder._ensure(urls)
	_warming = false


# Collect a cell's prop/scatter/enemy/populate/npc asset URLs (deduped into `urls`) for the flight warm.
func _gather_life_urls(rec: Dictionary, urls: Array) -> void:
	for lk in ["scatter", "props"]:
		var lst = rec.get(lk, [])
		if lst is Array:
			for e in lst:
				var u := _asset_url(e)
				if u != "" and not urls.has(u):
					urls.append(u)
	if int(rec.get("enemies", 0)) > 0:
		var eu := _enemy_model_url(rec)
		if eu != "" and not urls.has(eu):
			urls.append(eu)
	var pl = rec.get("populate", [])
	if pl is Array:
		for pp in pl:
			if typeof(pp) == TYPE_DICTIONARY and pp.get("set", []) is Array:
				for su in pp["set"]:
					var ru := _resolve(String(su))
					if ru != "" and not urls.has(ru):
						urls.append(ru)
	var npc = rec.get("npc", null)
	if typeof(npc) == TYPE_DICTIONARY:
		var nu := _npc_model_url(npc)
		if nu != "" and not urls.has(nu):
			urls.append(nu)


# ---------------- live hot-reload (B2) ----------------

# Called by main._poll_world when chunk_mode and the polled world.json raw text changed.
# Unlike SceneManager.reload (which rebuilds the whole area at the spawn and TELEPORTS the player),
# this re-parses the grid IN PLACE and rebuilds ONLY the resident cells whose record actually
# changed, at their SAME world offset — the player never moves and nothing fades. Cells that are
# not currently resident just get their grid record refreshed; the new layout streams in next time
# the ring reaches them.
func reload(new_world: Dictionary) -> void:
	if not _started:
		return

	# re-derive cell_size + start_cell (mirror start()); guard against a degenerate/zero size.
	var new_size := float(new_world.get("grid", {}).get("cell_size", cell_size))
	if new_size <= 0.0:
		new_size = cell_size
	var new_sc: Array = new_world.get("start_cell", [start_cell.x, start_cell.y])
	if new_sc.size() >= 2:
		start_cell = Vector2i(int(new_sc[0]), int(new_sc[1]))
	default_npc_model = String(new_world.get("default_npc_model", default_npc_model))

	# re-index the authored cells into a FRESH grid so we can diff against the prior one.
	var new_grid := {}
	for c in new_world.get("cells", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc: Array = c.get("cell", [])
		if cc.size() < 2:
			continue
		new_grid[_key(int(cc[0]), int(cc[1]))] = c

	# re-tint the SHARED env (cheap, no flicker — it's a single environment, not per-cell);
	# skipped when the Weather3D system owns the sky/ambient.
	if env and not env.has_meta("weather_owned"):
		var a = new_world.get("ambient", [env.ambient_light_color.r, env.ambient_light_color.g, env.ambient_light_color.b])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)

	# remember the prior grid so we can diff each resident record before swapping the grid in.
	var old_grid := grid

	# WORLD CHANGED -> drop all persistent bridges (a moved/removed bridge spec must not leave a stale
	# deck floating). Each surviving bridge rebuilds via _ensure_bridge when its cell next streams in.
	for bk in _bridges.keys():
		if is_instance_valid(_bridges[bk]):
			(_bridges[bk] as Node).queue_free()
	_bridges.clear()

	# A cell_size change moves every cell's world offset -> the only safe response is a full
	# re-stream. Swap the grid, drop all residents, and let the ring rebuild from the player cell.
	if not is_equal_approx(new_size, cell_size):
		cell_size = new_size
		grid = new_grid
		var all_keys: Array = resident.keys()
		for rk: String in all_keys:
			_evict(rk)
		_build_queue.clear()
		# every proxy's world offset moved too -> free them all; the ring update re-queues in-range ones
		var all_proxy_keys: Array = _proxies.keys()
		for pk: String in all_proxy_keys:
			_free_proxy(pk)
		_proxy_queue.clear()
		_rebuild_shared_nav()
		_cur_cell = _player_cell()
		_update_ring(_cur_cell)
		return

	# normal case: cell_size unchanged -> world offsets are stable -> rebuild changed residents only.
	grid = new_grid

	# guard the per-frame stream while we rebuild (these builds await on _ensure / GLB cache).
	_reloading = true

	var resident_keys: Array = resident.keys()
	for rk: String in resident_keys:
		var new_rec = new_grid.get(rk)
		var old_rec = old_grid.get(rk)
		if new_rec == null:
			# cell was DELETED from the world -> evict it; the ring will re-queue if it returns later.
			_evict(rk)
			continue
		if _records_equal(old_rec, new_rec):
			continue   # unchanged -> leave the live cell exactly as it is (no player move, no rebuild)
		# CHANGED resident -> rebuild IN PLACE at the SAME (gx,gz) world offset.
		var gx := 0
		var gz := 0
		var parts := rk.split(",")
		if parts.size() >= 2:
			gx = int(parts[0])
			gz = int(parts[1])
		# evict the old root (frees floor/walls/apron + child enemies) but DO NOT touch the player.
		_evict(rk)
		# build_cell uses a deterministic offset from gx/gz, so the cell reappears in the same spot.
		var built: Dictionary = await build_cell(new_rec, gx, gz)
		if built.is_empty():
			continue
		resident[rk] = built
		for e in built.get("enemies", []):
			enemies.append(e)

	# far proxies of DELETED or CHANGED cells are stale -> free them now; the closing _update_ring
	# re-queues any still on the horizon so the silhouette reflects the edit too.
	var proxy_keys: Array = _proxies.keys()
	for pk: String in proxy_keys:
		var nrec = new_grid.get(pk)
		if nrec == null or not _records_equal(old_grid.get(pk), nrec):
			_free_proxy(pk)

	# the resident footprint may have shifted (deletions) -> refresh the shared flat nav once.
	_rebuild_shared_nav()
	_reloading = false

	# a cell newly ADDED to the grid within the current ring should stream in NOW (not only on the
	# next cell change); non-resident cells already hold their new record for when they stream in.
	_update_ring(_cur_cell)


# Two cell records are "equal" for reload purposes iff their authored JSON is identical. We compare
# the whole Dictionary (Godot does deep == on Dictionaries/Arrays) so ANY authored field change
# (ground, enemies, props, etc.) triggers an in-place rebuild.
func _records_equal(a, b) -> bool:
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY:
		return a == b
	return (a as Dictionary) == (b as Dictionary)


# ---------------- ring maintenance ----------------

# Recompute the in-ring set around `centre`: queue cells that EXIST in the grid but aren't
# resident, and EVICT resident cells now outside the ring (this is the memory bound). Then
# maintain the FAR-PROXY ring behind it: silhouette-only cells for RING_RADIUS < d <= FAR_RADIUS
# (an evicted resident lands at d==2, so eviction DEMOTES full -> proxy via the far pass
# re-queueing it), and LRU-free stale proxies beyond FAR_RADIUS once over FAR_CAP.
func _update_ring(centre: Vector2i) -> void:
	# FLIGHT LOD: high above the ground, collapse the RESIDENT ring to just the cell under the player. Full
	# residents (colliders + live enemies/npc/populate + a per-build nav rebuild) are wasted on a flyer who
	# can't touch them and are the source of the plane's build hitches; the far-proxy ring covers the rest
	# cheaply (and, with far-life proxies, keeps the world looking inhabited from the air).
	var rr := 0 if _hi_air else RING_RADIUS
	var wanted := {}   # cell_key -> Vector2i, the existing cells within the ring
	for gx in range(centre.x - rr, centre.x + rr + 1):
		for gz in range(centre.y - rr, centre.y + rr + 1):
			var k := _key(gx, gz)
			if grid.has(k):
				wanted[k] = Vector2i(gx, gz)

	# EVICT residents now outside the ring (grid-distance > RING_RADIUS); the far pass below
	# immediately re-queues them as proxies (demotion: silhouette stays, physics/props go)
	var resident_keys: Array = resident.keys()
	for rk: String in resident_keys:
		if not wanted.has(rk):
			_evict(rk)

	# QUEUE in-ring cells that aren't resident yet (and aren't already queued)
	var order: Array = wanted.values()
	order.sort_custom(_ring_priority.bind(centre))
	for cell: Vector2i in order:
		var k := _key(cell.x, cell.y)
		if resident.has(k):
			continue
		if cell in _build_queue:
			continue
		_build_queue.append(cell)

	# FAR-PROXY pass: every existing cell with RING_RADIUS < d <= FAR_RADIUS should have a live
	# proxy (or one queued). Touch live ones so the LRU keeps what's currently on the horizon.
	# Collect the cells that still need a proxy, then queue them AHEAD-OF-HEADING first (same
	# _ring_priority the resident queue uses) so a moving player — especially a plane — sees the
	# horizon it's flying INTO fill before the cells beside/behind it ("props show up in advance").
	var need_proxy: Array = []
	for gx in range(centre.x - FAR_RADIUS, centre.x + FAR_RADIUS + 1):
		for gz in range(centre.y - FAR_RADIUS, centre.y + FAR_RADIUS + 1):
			var fc := Vector2i(gx, gz)
			if _cheb(fc, centre) <= rr:
				continue   # resident territory — always full cells, never proxies (rr collapses to 0 in flight)
			var fk := _key(gx, gz)
			if not grid.has(fk):
				continue
			if _proxies.has(fk):
				_proxy_touch(fk)
				continue
			if resident.has(fk) or fc in _proxy_queue:
				continue   # safety (eviction above already demoted) / already queued
			need_proxy.append(fc)
	need_proxy.sort_custom(_ring_priority.bind(centre))
	for fc2: Vector2i in need_proxy:
		_proxy_queue.append(fc2)

	# LRU-free proxies once over FAR_CAP — always ones that fell beyond FAR_RADIUS (everything
	# in range was just touched to the recent end, so the stale ones sit at the front)
	while _proxies.size() > FAR_CAP and not _proxy_lru.is_empty():
		var lk: String = _proxy_lru[0]
		if _cheb(_key_cell(lk), centre) <= FAR_RADIUS:
			break   # safety: never free an on-horizon proxy (in-range count 40 < FAR_CAP)
		_free_proxy(lk)

	# PERSISTENT BRIDGES: free one only once its authoring cell is well beyond the far ring (SKYLINE_RADIUS
	# ~160m) — far past any crossing, so the deck never vanishes under a crosser but a long roam can't leak.
	for bk in _bridges.keys():
		if not is_instance_valid(_bridges[bk]) or _cheb(_key_cell(bk), centre) > SKYLINE_RADIUS:
			if is_instance_valid(_bridges[bk]):
				(_bridges[bk] as Node).queue_free()
			_bridges.erase(bk)


# Pre-warm the cell AHEAD of the heading first, then nearest-first (Chebyshev), so a moving
# player gets the cell they're walking into before the diagonals.
func _ring_priority(a: Vector2i, b: Vector2i, centre: Vector2i) -> bool:
	var ah := _ahead_score(a, centre)
	var bh := _ahead_score(b, centre)
	if ah != bh:
		return ah > bh                 # higher "ahead" score builds first
	return _cheb(a, centre) < _cheb(b, centre)


func _ahead_score(cell: Vector2i, centre: Vector2i) -> int:
	if _heading == Vector2i.ZERO:
		return 0
	var d := cell - centre
	return d.x * _heading.x + d.y * _heading.y


# Spawn-clearance (Wave 3): push a world point OUT of any resident structure it lands inside, so a
# world that authors a player start or vehicle pos on top of a building can't strand you. `radius` is
# the spawnee's own clearance (a person ~0.6m, a car ~2.5m). Analytic (structure footprints only, so
# the terrain floor is never a false hit); a few passes settle overlaps between adjacent buildings.
# No structures resident near `pos` -> returns it unchanged (the common, spaced-out case).
func nudge_out(pos: Vector3, radius: float) -> Vector3:
	var p2 := Vector2(pos.x, pos.z)
	for _iter in 3:
		var moved := false
		for foots in _struct_foots.values():
			for f in foots:
				var c: Vector2 = f["c"]
				var minsep: float = float(f["r"]) + radius
				var dist := p2.distance_to(c)
				if dist < minsep:
					var dir := (p2 - c) / dist if dist > 0.01 else Vector2(1, 0)
					p2 = c + dir * (minsep + 0.1)
					moved = true
		if not moved:
			break
	return Vector3(p2.x, pos.y, p2.y)


# queue_free the cell's root (which parents its enemies) and drop the dict entry.
func _evict(k: String) -> void:
	var rec = resident.get(k)
	if rec == null:
		resident.erase(k)
		return
	var root = rec.get("root")
	if root != null and is_instance_valid(root):
		(root as Node).queue_free()   # frees floor/walls/apron + child enemies
	resident.erase(k)
	# drop this cell's enemies from the union list (root.queue_free already kills the nodes)
	var cell_enemies: Array = rec.get("enemies", [])
	for e in cell_enemies:
		enemies.erase(e)
	if interaction != null:
		interaction.remove_cell(k)   # drop this cell's npc/chest/door entries -> no ghost interactables
	_struct_foots.erase(k)          # drop this cell's structure footprints (spawn-clearance registry)


# ---------------- far-proxy ring (silhouette cells past the resident ring) ----------------

# Build the far proxy for one cell if it still needs one. Synchronous (build_proxy fetches
# nothing), so it runs inside tick's one-per-frame slot without an await.
func _build_proxy_at(gx: int, gz: int) -> void:
	var k := _key(gx, gz)
	if _proxies.has(k) or resident.has(k) or not grid.has(k):
		return
	_proxies[k] = build_proxy(grid[k], gx, gz)
	_proxy_touch(k)


# A cell's FAR PROXY: only what a player can actually make out from 2-3 cells away — the ground
# (terrain patch or a ground-matching slab), the parametric structure shells, and the road strips.
# STRICTLY nothing else: no props, no GLB/network fetches, no scatter/populate/NPCs/chests/doors/
# enemies/traffic — and ZERO colliders (physics exists only inside the resident ring).
func build_proxy(rec: Dictionary, gx: int, gz: int) -> Node3D:
	var half := cell_size * 0.5
	var centre := Vector3(float(gx) * cell_size + half, 0.0, float(gz) * cell_size + half)
	var root := Node3D.new()
	world_main.add_child(root)
	# GROUND, matching the cell's real look. Terrain -> the same heightmap patch (the trimesh
	# collider it always bakes is removed by the final strip pass); flat -> a mesh-only slab in
	# the cell's ground material (builder._ground_box would bring a StaticBody3D, so bare mesh).
	if terrain != null:
		# far proxy matches the resident cell's per-cell ground override (city reads as asphalt from afar
		# too); collide=false (Wave 4) so the costly trimesh collider is never baked just to be stripped.
		root.add_child(terrain.cell_terrain(centre, cell_size, rec.get("ground", null), false))
	else:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(cell_size, 1.0, cell_size)
		mi.mesh = bm
		mi.material_override = builder._ground_mat(rec.get("ground", DEFAULT_GROUND))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = centre + Vector3(0.0, -0.5, 0.0)
		root.add_child(mi)
	# ROADS: the same terrain-following builder residents use, with collide=false (Wave 4) so no road
	# StaticBody3D is built for a proxy (it was only stripped again by _strip_physics anyway)
	var road_list = rec.get("roads", [])
	if road_list is Array:
		for r in road_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_road(root, r, centre, half, false)
	# STRUCTURES: the far skyline. Full parametric shells; their colliders — and sign-light pools
	# (40+ proxy cells of OmniLights would blow the web renderer's per-mesh light budget) — are
	# removed by the final strip pass. Wave 2: the "interior" key is STRIPPED from a cheap spec
	# copy FIRST, so a proxy shows the SOLID SHELL only (byte-identical to a no-interior build) —
	# no interior geometry, no "gogi_door" leaves, no interior lights are ever built for a proxy
	# (cheaper than build-then-strip, and honours the far-proxies-never-contain-interiors contract
	# at the source; _strip_physics below stays the defensive backstop).
	var struct_list = rec.get("structures", [])
	if struct_list is Array:
		for st in struct_list:
			if typeof(st) != TYPE_DICTIONARY:
				continue
			var shell: Dictionary = (st as Dictionary).duplicate()   # shallow — we only drop a top-level key
			shell.erase("interior")
			# proxy=true is belt-and-suspenders with the erase above: either
			# alone yields a solid shell (no interior geometry / gogi_door /
			# lights in far proxies — the pinned Wave-2 contract).
			var node := GBuild.structure(shell, true)
			if node == null:
				continue
			var xz := _xz(st.get("pos", [0, 0]))
			var p := centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
			p.y = _ground_y(p.x, p.z)
			node.position = p
			root.add_child(node)
	# LANDMARK: tall set-pieces (VOLCANOES) show as a dark cone + a glowing crater from afar so the player
	# can see where they're headed. Silhouette only — no lava dome/particles/light/collider.
	var lava_far = rec.get("lava", [])
	if lava_far is Array:
		for lf in lava_far:
			if typeof(lf) == TYPE_DICTIONARY:
				_place_volcano_silhouette(root, lf as Dictionary, centre, half)
	# FAR REAL PROPS: render the ACTUAL prop/scatter GLB models (visual-only) for assets ALREADY cached by
	# the resident ring — so distant cells show the real trees/rocks, NOT stand-ins. _strip_physics below
	# drops their colliders. Assets not yet cached are skipped (they appear once a nearer cell loads them).
	# NOTE kept deliberately LIGHT: unbounded far props (real meshes + throwaway colliders across up to
	# FAR_CAP cells, growing as you roam) risk exhausting the fixed WASM heap ("out of bounds memory
	# access"). Scatter is a cheap 1-draw MultiMesh with NO collider in the far ring; individual props are
	# capped hard. The full-detail props return the instant the cell becomes resident.
	# ...only in the INNER far cells (REAL_DETAIL_RADIUS) — outer proxies stay ground+structure silhouettes so
	# the far ring's real-prop draw calls stay bounded on mobile (a tree past ~60m is a handful of pixels).
	# SCATTER (forests/rocks/vegetation) renders across the WHOLE far ring — it's a GPU-instanced MultiMesh
	# (ONE draw call per entry, <=SCATTER_MAX instances, no collider, cache-gated), so it's nearly free and
	# safe to push out to FAR_RADIUS. This is what makes the vegetated landscape read from the air well AHEAD
	# of the plane ("props show up in advance"); the pricey per-node individual props + life stand-ins below
	# stay within the tighter REAL_DETAIL_RADIUS to bound heap + CPU (the pinned no-unbounded-far-props rule).
	var scat_far = rec.get("scatter", [])
	if scat_far is Array:
		for sf in scat_far:
			if typeof(sf) == TYPE_DICTIONARY:
				var su := _asset_url(sf)
				if su != "" and builder.cache.has(su):
					_place_scatter(root, sf, centre, half, false)   # false = no collider (visual-only far ring)
	if _cheb(Vector2i(gx, gz), _cur_cell) <= REAL_DETAIL_RADIUS:
		# FAR LANDMARK: a cell's authored set-piece (a tower/monument/mountain GLB) should read from the proxy
		# ring, not pop in only when its cell goes fully resident. Same REAL_DETAIL gate + cache-only rule as
		# the props below (single big mesh, no collider on the proxy). (Kept when re-syncing the engine template.)
		var lm_far = rec.get("landmark", null)
		if typeof(lm_far) == TYPE_DICTIONARY:
			var lu := _asset_url(lm_far)
			if lu != "" and builder.cache.has(lu):
				_place_one(root, lm_far, centre, half, "")
		var prop_far = rec.get("props", [])
		if prop_far is Array:
			var placed_far := 0
			for pf in prop_far:
				if placed_far >= 2:   # far-ring node/memory budget (residents keep the full PROP_CAP)
					break
				if typeof(pf) == TYPE_DICTIONARY:
					var pu := _asset_url(pf)
					if pu != "" and builder.cache.has(pu):
						if _place_one(root, pf, centre, half, ""):
							placed_far += 1
		# FAR LIFE: cheap STATIC stand-ins for this cell's LIVE entities (enemies / populate animals / npc) so
		# the world reads as INHABITED from the air. Same REAL_DETAIL gate + cache-only rule as the props above;
		# the real AI entities take over the instant the cell becomes resident.
		_place_proxy_life(root, rec, centre, half)
	# SHADOWS OFF for the whole proxy: silhouette cells must never cast into the sun's 42m cascade (double
	# draw for zero benefit — proxies are backdrop, not lit contact geometry).
	_no_shadows(root)
	# INVARIANT: a proxy contains ZERO physics. One defensive pass over the whole finished subtree
	# (roads/structures above + anything a future edit adds) instead of trusting each placement.
	_strip_physics(root)
	root.reset_physics_interpolation()   # freshly-spawned subtree: pin its transforms so it doesn't render a one-frame smear from origin
	return root


# Cheap far-ring STAND-INS for a cell's LIVE inhabitants — enemies, populate (herds/crowds), the npc — as
# JUST the cached GLB duplicated at its spawn spot: NO enemy.gd/AI, NO NavigationAgent/RVO, NO collider, NO
# interaction registration, processing DISABLED (a stray embedded AnimationPlayer never ticks). Called ONLY
# inside build_proxy's REAL_DETAIL gate and only for CACHED assets, so it never fetches and never grows the
# far ring past its bounds; per-source caps + FAR_CAP LRU keep the skinned-dup count bounded on mobile.
func _place_proxy_life(root: Node3D, rec: Dictionary, centre: Vector3, half: float) -> void:
	if not FAR_LIFE:
		return   # frozen stand-ins read as broken, not as distant life — see the FAR_LIFE note

	var enemy_n := mini(int(rec.get("enemies", 0)), MAX_ENEMIES_PER_CELL)
	if enemy_n > 0:
		var emu := _enemy_model_url(rec)
		if emu != "" and builder.cache.has(emu) and builder.cache[emu] != null:
			var shown := mini(enemy_n, PROXY_ENEMY_CAP)
			for i in range(shown):
				var ang := TAU * float(i) / float(enemy_n)   # /enemy_n -> same angular ring the residents use
				var epos := centre + Vector3(cos(ang) * (half * 0.45), 0.0, sin(ang) * (half * 0.45))
				epos.y = _ground_y(epos.x, epos.z)
				_spawn_life_dummy(root, builder.cache[emu] as Node, epos)
	var pop_list = rec.get("populate", [])
	if pop_list is Array:
		var cell_seed := int(centre.x) * 73856093 + int(centre.z) * 19349663
		for pp in pop_list:
			if typeof(pp) != TYPE_DICTIONARY:
				continue
			var pset = pp.get("set", [])
			if not (pset is Array) or (pset as Array).is_empty():
				continue
			var pcount := mini(clampi(int(pp.get("count", 6)), 1, 30), PROXY_POP_CAP)
			for i in range(pcount):
				var rng := GCast.rng_for(cell_seed + i * 1013)
				var u := _resolve(GCast.pick(pset, rng))
				if u == "" or not builder.cache.has(u) or builder.cache[u] == null:
					continue
				var wp := centre + Vector3(rng.randf_range(-half + 1.0, half - 1.0), 0.0, rng.randf_range(-half + 1.0, half - 1.0))
				wp.y = _ground_y(wp.x, wp.z)
				_spawn_life_dummy(root, builder.cache[u] as Node, wp)
	var npc = rec.get("npc", null)
	if typeof(npc) == TYPE_DICTIONARY:
		var nmu := _npc_model_url(npc)
		if nmu != "" and builder.cache.has(nmu) and builder.cache[nmu] != null:
			var np := _xz(npc.get("pos", [0, 0]))
			var npos := centre + Vector3(clampf(np.x, -half + 1.0, half - 1.0), 0.0, clampf(np.y, -half + 1.0, half - 1.0))
			npos.y = _ground_y(npos.x, npos.z)
			_spawn_life_dummy(root, builder.cache[nmu] as Node, npos)


# Duplicate a cached GLB as a STATIC, script-free, collider-free far stand-in: shrink-only normalize (never
# up), ground it, disable processing, and give every mesh a visibility_range_end fade. pos.y must carry
# _ground_y; this only subtracts the model's base offset so its feet rest on the surface.
func _spawn_life_dummy(root: Node3D, src: Node, pos: Vector3) -> void:
	var n := src.duplicate() as Node3D
	if n == null:
		return
	n.process_mode = Node.PROCESS_MODE_DISABLED   # a stray embedded AnimationPlayer never ticks -> truly static (rendering is NOT gated by process_mode)
	var ab := builder._world_aabb(n)
	var mdim: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	if mdim > LIFE_MAX_DIM and mdim > 0.001:
		# n.position is still ZERO here, so the parent-frame AABB scales uniformly about the origin —
		# scale it arithmetically instead of a second full-subtree _world_aabb walk (this runs up to a
		# dozen times per far cell; the redundant walk was a measurable slice of the flight hitch).
		var f := LIFE_TARGET_DIM / mdim
		n.scale *= f
		ab.position *= f
		ab.size *= f
	n.position = pos
	n.position.y -= maxf(0.0, ab.position.y)
	root.add_child(n)
	_proxy_vis(n, PROXY_LIFE_VIS_END)


# Give every mesh in a subtree a visibility_range_end soft fade (recursive) so far-life dups range-cull.
func _proxy_vis(n: Node, vis_end: float) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		gi.visibility_range_end = vis_end
		gi.visibility_range_end_margin = vis_end * 0.15
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children():
		_proxy_vis(c, vis_end)


# A cheap far-distance VOLCANO: dark cone + an emissive crater cap (no light node, no particles, no
# collider) so a volcano is a visible landmark from the far-proxy ring, swapped for the full one up close.
func _place_volcano_silhouette(root: Node3D, spec: Dictionary, centre: Vector3, half: float) -> void:
	var p := _xz(spec.get("pos", [0, 0]))
	var r := clampf(float(spec.get("radius", 6.0)), 1.5, half * 1.6)
	var pos := centre + Vector3(clampf(p.x, -half * 1.5, half * 1.5), 0.0, clampf(p.y, -half * 1.5, half * 1.5))
	var gy := _ground_y(pos.x, pos.z)
	var cone_h := clampf(r * 1.15, 3.0, 26.0)
	var cone := MeshInstance3D.new()
	var cmz := CylinderMesh.new()
	cmz.bottom_radius = r * 1.75
	cmz.top_radius = r * 1.12
	cmz.height = cone_h
	cmz.radial_segments = 14
	cone.mesh = cmz
	cone.material_override = GSurf.surface({"color": [0.13, 0.10, 0.09], "rough": 1.0})
	cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(cone)
	cone.global_position = Vector3(pos.x, gy + cone_h * 0.5 - 0.3, pos.z)
	var cap := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r * 0.95
	cm.bottom_radius = r * 0.95
	cm.height = 0.2
	cap.mesh = cm
	var em := StandardMaterial3D.new()
	em.albedo_color = Color(1.0, 0.4, 0.1)
	em.emission_enabled = true
	em.emission = Color(1.0, 0.45, 0.12)
	em.emission_energy_multiplier = 2.5
	cap.material_override = em
	cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(cap)
	cap.global_position = Vector3(pos.x, gy + cone_h - 0.5, pos.z)


# free one proxy's scene subtree + drop it from the dict and the LRU order
func _free_proxy(k: String) -> void:
	var p = _proxies.get(k)
	if p != null and is_instance_valid(p):
		(p as Node).queue_free()
	_proxies.erase(k)
	_proxy_lru.erase(k)


# mark a proxy most-recently-wanted (kept longest once the FAR_CAP eviction runs)
func _proxy_touch(k: String) -> void:
	_proxy_lru.erase(k)
	_proxy_lru.append(k)


# Strip every physics body (and light pool) out of a subtree — a far proxy must contain ZERO
# colliders, and shouldn't add to the per-mesh light budget. remove_child detaches first, so the
# immediate free() (which drops the node together with its children) is safe in- or pre-tree.
# Wave 2 defense-in-depth: door discovery is BY GROUP ("gogi_door"), so any surviving proxy node
# is also DEGROUPED — a proxy door can never be discovered/registered even if a future builder
# change tags one (normally none exist: build_proxy strips the "interior" key before building).
func _strip_physics(node: Node) -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		var nn = stack.pop_back()
		if nn is Node and (nn as Node).is_in_group("gogi_door"):
			(nn as Node).remove_from_group("gogi_door")
		for c in nn.get_children():
			if c is StaticBody3D or c is OmniLight3D:
				nn.remove_child(c)
				(c as Node).free()
			else:
				stack.append(c)


# ---------------- cell build (world-space, open-edge walls, apron, shared nav) ----------------

func _build_cell_at(gx: int, gz: int) -> void:
	var k := _key(gx, gz)
	if resident.has(k) or not grid.has(k):
		return
	# PROMOTE proxy -> full: the silhouette dies the moment the real build starts (never both live
	# at once — the proxy's coplanar ground/structures would z-fight the resident's real ones)
	if _proxies.has(k):
		_free_proxy(k)
	var rec: Dictionary = grid[k]
	var built: Dictionary = await build_cell(rec, gx, gz)
	if built.is_empty():
		return
	resident[k] = built
	for e in built.get("enemies", []):
		enemies.append(e)
	# the ring grew -> the shared flat nav should cover the new footprint
	if not _hi_air:
		_rebuild_shared_nav()   # a flyer needs no ground nav; proxies carry no enemies -> skip the free+recreate burst in the air

	# hard-cap safety net: should never trip (eviction keeps us <= 9), but if it does, evict the
	# farthest resident from the current cell so the cap is a true ceiling for the memory number.
	while resident.size() > MAX_RESIDENT_CELLS:
		_evict_farthest()


# Build a cell at WORLD offset (gx*cell_size, 0, gz*cell_size) — NOT origin-centered like
# build_area. Floor tile colored by cell.ground; walls ONLY on TRUE world-border edges (no
# neighbor cell in the grid), OPEN on edges shared with an adjacent existing cell; a thin apron
# collider over shared edges so the player can't fall through a not-yet-built neighbor.
# Returns { root: Node3D, enemies: Array } (compatible with the resident dict / SceneManager shape).
func build_cell(rec: Dictionary, gx: int, gz: int) -> Dictionary:
	var half := cell_size * 0.5
	var ox := float(gx) * cell_size
	var oz := float(gz) * cell_size
	var centre := Vector3(ox + half, 0.0, oz + half)

	var enemy_n := mini(int(rec.get("enemies", 0)), MAX_ENEMIES_PER_CELL)   # cap skinned+RVO characters/cell

	# ---- gather EVERY asset url (enemy + scenery) for ONE parallel download (cache-shared) ----
	var scatter_list = rec.get("scatter", [])
	var prop_list = rec.get("props", [])
	var landmark = rec.get("landmark", null)
	var urls: Array = []
	if enemy_n > 0:
		var eu := _enemy_model_url(rec)
		if eu != "" and not urls.has(eu):
			urls.append(eu)
	if scatter_list is Array:
		for s in scatter_list:
			var su := _asset_url(s)
			if su != "" and not urls.has(su):
				urls.append(su)
	if prop_list is Array:
		for p in prop_list:
			var pu := _asset_url(p)
			if pu != "" and not urls.has(pu):
				urls.append(pu)
	if landmark != null:
		var lu := _asset_url(landmark)
		if lu != "" and not urls.has(lu):
			urls.append(lu)
	# row/ring layout parts that reference a library GLB need fetching too
	for lk in ["rows", "rings"]:
		var ll = rec.get(lk, [])
		if ll is Array:
			for entry in ll:
				if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("part", null)) == TYPE_DICTIONARY:
					var pu2 := _asset_url(entry["part"])
					if pu2 != "" and not urls.has(pu2):
						urls.append(pu2)
	# populate `set` urls (the cast/kit models instanced as a varied many)
	var pl = rec.get("populate", [])
	if pl is Array:
		for entry in pl:
			if typeof(entry) == TYPE_DICTIONARY and entry.get("set", []) is Array:
				for su2 in entry["set"]:
					var ru := _resolve(String(su2))
					if ru != "" and not urls.has(ru):
						urls.append(ru)
	# traffic car-model `set` urls
	var tspec = rec.get("traffic", null)
	if typeof(tspec) == TYPE_DICTIONARY and tspec.get("set", []) is Array:
		for cu in tspec["set"]:
			var ru2 := _resolve(String(cu))
			if ru2 != "" and not urls.has(ru2):
				urls.append(ru2)
	if typeof(rec.get("npc", null)) == TYPE_DICTIONARY:
		var nu := _npc_model_url(rec.get("npc"))
		if nu != "" and not urls.has(nu):
			urls.append(nu)
	var root := Node3D.new()
	world_main.add_child(root)

	# FLOOR. TERRAIN mode -> a rolling heightmap mesh + collider (seamless across cells, so no aprons/walls
	# needed: the terrain colliders are continuous). FLAT mode -> the textured slab floor + edge walls/aprons.
	var ground_spec = rec.get("ground", DEFAULT_GROUND)
	if terrain != null:
		# per-cell "ground" (e.g. a city cell's asphalt/plaza) overrides the global terrain material
		# for THIS cell only, conforming to the slope; absent -> null -> keeps the world terrain look.
		root.add_child(terrain.cell_terrain(centre, cell_size, rec.get("ground", null)))
		# CONTAINMENT (fixes "the whole world disappears when you walk away"): terrain ground is
		# continuous with NO edge walls, so without this the player walks off the authored grid ->
		# the ring evicts every cell -> the entire world vanishes (only sky + the player-following
		# skirt/water remain). Add INVISIBLE collision-only walls on TRUE world-border edges (no
		# neighbor cell in the grid) so the world is bounded and can never disappear. Edges shared
		# with an existing cell stay OPEN (seamless interior traversal).
		_terrain_border_walls(root, gx, gz, centre, half)
	else:
		# flat floor (slab below y=0; cast_shadow off so the big floor can't self-shadow into acne).
		builder._ground_box(root, centre + Vector3(0.0, -0.5, 0.0), Vector3(cell_size, 1.0, cell_size), ground_spec, false)
		# walls ONLY on TRUE world-border edges; OPEN + APRON on shared edges (anti fall-through).
		var ground := builder._spec_color(ground_spec)
		var wall := Color(ground.r * 0.7, ground.g * 0.7, ground.b * 0.78)
		var wall_h := 4.0
		var wall_t := 1.0
		var apron := half * 0.25
		if grid.has(_key(gx, gz - 1)):
			_collider_box(root, centre + Vector3(0.0, -0.5, -half - apron * 0.5), Vector3(cell_size, 1.0, apron))
		else:
			builder._box(root, centre + Vector3(0.0, wall_h * 0.5 - 0.5, -half), Vector3(cell_size, wall_h, wall_t), wall)
		if grid.has(_key(gx, gz + 1)):
			_collider_box(root, centre + Vector3(0.0, -0.5, half + apron * 0.5), Vector3(cell_size, 1.0, apron))
		else:
			builder._box(root, centre + Vector3(0.0, wall_h * 0.5 - 0.5, half), Vector3(cell_size, wall_h, wall_t), wall)
		if grid.has(_key(gx - 1, gz)):
			_collider_box(root, centre + Vector3(-half - apron * 0.5, -0.5, 0.0), Vector3(apron, 1.0, cell_size))
		else:
			builder._box(root, centre + Vector3(-half, wall_h * 0.5 - 0.5, 0.0), Vector3(wall_t, wall_h, cell_size), wall)
		if grid.has(_key(gx + 1, gz)):
			_collider_box(root, centre + Vector3(half + apron * 0.5, -0.5, 0.0), Vector3(apron, 1.0, cell_size))
		else:
			builder._box(root, centre + Vector3(half, wall_h * 0.5 - 0.5, 0.0), Vector3(wall_t, wall_h, cell_size), wall)

	# The FLOOR + border walls now EXIST — only NOW await the scenery GLB downloads. The floor is
	# built BEFORE this await deliberately: since Wave 2 the player is under gravity, so a start cell
	# containing any downloaded prop/crowd/traffic/scatter/landmark asset used to drop the player
	# through the not-yet-built floor into an endless fall during the download. Roads + every
	# GLB-dependent placement (traffic, structures, rows/rings, props, populate, npc, enemies) run
	# after this point, so they still get their fetched assets.
	# BRIDGE deck is a load-bearing WALKABLE surface of pure primitives (Box/Cylinder + GSurf, no GLB), and
	# its ends reach the outer edge of this cell's resident band -> a crosser can be over the gorge the instant
	# the cell enters the ring. Build it NOW, BEFORE the scenery await, for the SAME reason the floor is: post-
	# await the deck would appear only after every prop GLB lands, and the crosser free-falls into the gorge.
	var _br_pre = rec.get("bridge", null)
	if typeof(_br_pre) == TYPE_DICTIONARY:
		_ensure_bridge(_key(gx, gz), _br_pre as Dictionary, centre, half)   # PERSISTENT (world-parented): never freed with this evicting cell, so a crosser keeps the deck to the far rim
	await builder._ensure(urls)

	# ---- ROADS: tiled-asphalt strips with a dashed centerline, laid on the floor BEFORE scenery so
	# buildings/props sit on top. A cell's `roads` is an array of {dir:"ns"|"ew"|"x", width}. This is
	# what turns "drive over a flat colored plane" into actual streets. ----
	# collide=false: the road is VISUAL-ONLY (parity with far proxies). The terrain/floor collider
	# beneath is already walkable at the road footprint, so a separate proud road collider only added
	# a ~10cm edge lip that the player/enemies/vehicles caught on ("can't get onto the flat road").
	# Walk/drive ON the terrain beneath; the asphalt is decoration laid over it.
	var road_list = rec.get("roads", [])
	if road_list is Array:
		for r in road_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_road(root, r, centre, half, false)
	# ---- AMBIENT TRAFFIC: cars driving along this cell's roads (the "living city" cue, traffic.gd) ----
	var traffic_spec = rec.get("traffic", null)
	if typeof(traffic_spec) == TYPE_DICTIONARY and road_list is Array:
		_place_traffic(root, traffic_spec, road_list, centre, half)

	# ---- STRUCTURES: parametric buildings composed from the shape vocabulary + surface cookbook
	# (build_structure.gd) — a house, tower, pyramid, pylon, ziggurat from ONE spec. Placed before
	# scenery/props so dressing sits against them. Base-grounded by contract (no extra drop needed).
	# ckey is declared HERE because interior door leaves (Wave 2) register with the interaction
	# system under this cell's key, exactly like the npc/chest/doors block further down. ----
	var ckey := _key(gx, gz)
	var struct_list = rec.get("structures", [])
	if struct_list is Array:
		for st in struct_list:
			if typeof(st) == TYPE_DICTIONARY:
				_place_structure(root, st, centre, half, ckey)

	# TIME-SLICE (1/3): a dense camp cell instantiates dozens of .duplicate()s + first-draw shader compiles;
	# doing it all on one frame is the measured ~100ms hitch when you cross into the cell. Yield a frame between
	# the heavy dressing phases so the cost spreads over ~4 frames. reset_physics_interpolation FIRST so the
	# nodes placed in this slice don't render one frame smeared from world origin. (_building gates reentrancy.)
	root.reset_physics_interpolation()
	await get_tree().process_frame

	# ---- LAYOUT (ARRANGEMENT axis, layout.gd): place a repeated part along a line (`rows`) or around a
	# perimeter (`rings`) — a colonnade, a fence, a streetlight row, a court of columns, an avenue. ----
	var row_list = rec.get("rows", [])
	if row_list is Array:
		for r in row_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_row(root, r, centre, half)
	var ring_list = rec.get("rings", [])
	if ring_list is Array:
		for r in ring_list:
			if typeof(r) == TYPE_DICTIONARY:
				_place_ring(root, r, centre, half)

	# ---- POPULATE (Meshy KIT/CAST deploy): instance a VARIED MANY from a small `set` of models — a crowd, a
	# herd, a varied prop field from a few generated GLBs (per-instance recolor/scale/yaw, cast.gd GCast). ----
	var pop_list = rec.get("populate", [])
	if pop_list is Array:
		for pp in pop_list:
			if typeof(pp) == TYPE_DICTIONARY:
				_place_populate(root, pp, centre, half, ckey)

	# TIME-SLICE (2/3): populate (a crowd of up to POP_WEB_CAP skinned dups) is the heaviest dressing — yield.
	root.reset_physics_interpolation()
	await get_tree().process_frame

	# ---- per-cell SCENERY: landmark (1) -> individual props (capped) -> scatter (MultiMesh) ----
	# All parented to `root`, so eviction (root.queue_free) reclaims them. Grounded so nothing floats.
	# ckey rides along so a {"sit": true} entry registers its seat under this cell (dies on evict).
	if landmark != null:
		_place_one(root, landmark, centre, half, ckey)
	if prop_list is Array:
		var placed := 0
		for p in prop_list:
			if placed >= PROP_CAP:
				break
			if _place_one(root, p, centre, half, ckey):
				placed += 1
	if scatter_list is Array:
		for s in scatter_list:
			_place_scatter(root, s, centre, half)

	# TIME-SLICE (3/3): props + scatter placed; yield before the interactables + enemy skeletons (heaviest spawn).
	root.reset_physics_interpolation()
	await get_tree().process_frame

	# ---- interactables: npc / chest / doors, parented to THIS cell (root) + tagged with the cell
	# key (ckey, declared at the STRUCTURES block) so _evict -> interaction.remove_cell drops the
	# registry entries (no ghost interactables) ----
	if interaction != null:
		var npc = rec.get("npc", null)
		if typeof(npc) == TYPE_DICTIONARY:
			var np := _xz(npc.get("pos", [0, 0]))
			var npos := centre + Vector3(clampf(np.x, -half + 1.0, half - 1.0), 0.0, clampf(np.y, -half + 1.0, half - 1.0))
			npos.y = _ground_y(npos.x, npos.z)
			var nmu := _npc_model_url(npc)
			var nmodel: Node = null
			if builder.cache.has(nmu):
				nmodel = (builder.cache[nmu] as Node).duplicate()
				_no_shadows(nmodel)   # skinned NPCs don't cast shadows (perf)
			interaction.add_npc(npos, String(npc.get("id", "")), String(npc.get("name", "Stranger")),
				String(npc.get("persona", "")), npc.get("lines", []), nmodel, root, ckey, String(npc.get("sound", "")))
		var chest = rec.get("chest", null)
		if typeof(chest) == TYPE_DICTIONARY:
			var cp := _xz(chest.get("pos", [0, 0]))
			var cpos := centre + Vector3(clampf(cp.x, -half + 1.0, half - 1.0), 0.0, clampf(cp.y, -half + 1.0, half - 1.0))
			cpos.y = _ground_y(cpos.x, cpos.z)
			interaction.add_chest(cpos, chest.get("contents", []), int(chest.get("gold", 0)), root, ckey)
		var door_list = rec.get("doors", [])
		if door_list is Array:
			for d in door_list:
				if typeof(d) != TYPE_DICTIONARY:
					continue
				var dp := _xz(d.get("pos", [0, 0]))
				var dpos := centre + Vector3(clampf(dp.x, -half + 1.0, half - 1.0), 0.0, clampf(dp.y, -half + 1.0, half - 1.0))
				dpos.y = _ground_y(dpos.x, dpos.z)
				interaction.add_door(dpos, float(d.get("facing", 0.0)), String(d.get("lock", "")),
					String(d.get("label", "Door")), root, ckey, String(d.get("id", "")))

	# spawn this cell's enemies at the world offset (ring around the cell centre)
	var cell_enemies: Array = []
	var emu := _enemy_model_url(rec)
	if enemy_n > 0 and builder.cache.has(emu):
		for i in range(enemy_n):
			if enemies.size() + cell_enemies.size() >= LIVE_ENEMY_BUDGET:
				break   # ring-wide skinned-enemy ceiling hit -> the rest of this camp reads via static far proxies, not live skinned bodies
			var e := CharacterBody3D.new()
			e.set_script(EnemyScript)
			root.add_child(e)
			var ang := TAU * float(i) / float(enemy_n)
			var epos := centre + Vector3(cos(ang) * (half * 0.45), 0.0, sin(ang) * (half * 0.45))
			epos.y = _ground_y(epos.x, epos.z)   # spawn ON the terrain (not cell-centre y=0), same as every other placement path
			e.global_position = epos
			var model: Node = (builder.cache[emu] as Node).duplicate()
			_no_shadows(model)   # skinned enemies (incl. a boss) don't cast shadows — big clustered-combat win
			var eopts := {}
			for pair in [["enemy_hp", "hp"], ["enemy_damage", "damage"], ["enemy_speed", "speed"],
					["enemy_range", "range"], ["enemy_height", "height"],
					["enemy_aquatic", "aquatic"], ["enemy_aerial", "aerial"], ["enemy_hover", "hover"]]:
				if rec.has(pair[0]):
					eopts[pair[1]] = rec[pair[0]]
			e.setup(player, model, world_main, i, enemy_n, String(rec.get("enemy_type", "skeleton")), eopts)
			cell_enemies.append(e)

	# ---- island set-piece extras (data-driven; resident ring only): lava pools, waterfalls,
	# a rope-and-log bridge, ambient particle moods (fireflies / embers / mist) ----
	_place_extras(root, rec, centre, half)

	root.reset_physics_interpolation()   # pin all spawned props/enemies/crowd so they don't render a smear from origin on their first frame
	return {root = root, enemies = cell_enemies}


# A collision-ONLY box (no visible mesh) — for the edge aprons, so they stop fall-through into a
# not-yet-built neighbor WITHOUT z-fighting the neighbor's coplanar floor mesh.
func _collider_box(parent: Node, pos: Vector3, sz: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = sz
	cs.shape = box
	body.add_child(cs)
	parent.add_child(body)


# INVISIBLE boundary walls for a TERRAIN cell on its TRUE world-border edges (no grid neighbor on
# that side). Flat-mode cells already get visible border walls in build_cell; terrain cells skip
# them (continuous ground) and so MUST get this containment, or the player walks off the grid and
# the world disappears. Open edges (a neighbor exists) get nothing, keeping interior travel seamless.
func _terrain_border_walls(root: Node, gx: int, gz: int, centre: Vector3, half: float) -> void:
	var wall_h := 8.0
	var wall_t := 1.0
	if not grid.has(_key(gx, gz - 1)):
		_edge_wall(root, centre + Vector3(0.0, 0.0, -half), Vector3(cell_size, wall_h, wall_t))
	if not grid.has(_key(gx, gz + 1)):
		_edge_wall(root, centre + Vector3(0.0, 0.0, half), Vector3(cell_size, wall_h, wall_t))
	if not grid.has(_key(gx - 1, gz)):
		_edge_wall(root, centre + Vector3(-half, 0.0, 0.0), Vector3(wall_t, wall_h, cell_size))
	if not grid.has(_key(gx + 1, gz)):
		_edge_wall(root, centre + Vector3(half, 0.0, 0.0), Vector3(wall_t, wall_h, cell_size))


# One invisible (no mesh) tall collider wall at a cell edge, vertically centred on the terrain
# surface at the edge midpoint so it blocks the player regardless of the rolling height.
func _edge_wall(root: Node, edge_centre: Vector3, sz: Vector3) -> void:
	var gy := _ground_y(edge_centre.x, edge_centre.z)
	_collider_box(root, Vector3(edge_centre.x, gy + sz.y * 0.5 - 1.0, edge_centre.z), sz)


# ---------------- roads ----------------

# Lay a road across the cell: a tiled-asphalt, TERRAIN-FOLLOWING strip with a dashed centerline so
# streets READ as streets (and hug the hills instead of knifing through them). dir = "ns" | "ew" |
# "x"/"cross" (both). The strip keeps the walk-on-asphalt collider residents always had; a far
# proxy strips it back out (zero-collider contract).
func _place_road(root: Node, spec: Dictionary, centre: Vector3, half: float, collide := true) -> void:
	var dir := String(spec.get("dir", "ew")).to_lower()
	var width := clampf(float(spec.get("width", 6.0)), 2.0, cell_size)
	if dir == "x" or dir == "cross" or dir == "+":
		_road_strip(root, centre, "ew", width, collide)
		_road_strip(root, centre, "ns", width, collide)
	else:
		_road_strip(root, centre, dir, width, collide)


# One strip, TERRAIN-FOLLOWING: tessellated along the long axis into ~2.5m thin-box segments, each
# centred at the ground height of its midpoint, PITCHED to the slope between its endpoints
# (atan2 rise/run), sitting +0.06 proud of the surface, with ~4% length overlap so a slope never
# opens a gap between segments. The dashed centerline rides the same heights (+0.10, same per-dash
# pitch). A flat world degenerates to height 0 / pitch 0 -> looks exactly like the old single-slab
# road. The strip carries ONE StaticBody3D with a pitched box shape per segment (parity with the
# old _ground_box road: the player walks ON the asphalt, not 10cm inside it); far proxies reuse
# this builder and strip that body back out (_strip_physics) to honour the zero-collider contract.
func _road_strip(root: Node, centre: Vector3, dir: String, width: float, collide := true) -> void:
	var ew := dir != "ns"
	var asphalt: StandardMaterial3D = builder._ground_mat("asphalt")
	var seg_n := maxi(1, ceili(cell_size / 2.5))
	var seg := cell_size / float(seg_n)
	# Wave 4: far proxies pass collide=false — the road is silhouette-only out there, so skip the
	# StaticBody3D entirely instead of building it and stripping it later (_strip_physics).
	var body: StaticBody3D = null
	if collide:
		body = StaticBody3D.new()   # parallel shape container (one body, seg_n shapes)
		body.collision_layer = 1
	for i in range(seg_n):
		var t0 := -cell_size * 0.5 + seg * float(i)
		var t1 := t0 + seg
		var tm := (t0 + t1) * 0.5
		var h0 := _ground_y(centre.x + t0, centre.z) if ew else _ground_y(centre.x, centre.z + t0)
		var h1 := _ground_y(centre.x + t1, centre.z) if ew else _ground_y(centre.x, centre.z + t1)
		var hm := _ground_y(centre.x + tm, centre.z) if ew else _ground_y(centre.x, centre.z + tm)
		var sz := Vector3(seg * 1.04, 0.08, width) if ew else Vector3(width, 0.08, seg * 1.04)
		var pos := centre + (Vector3(tm, 0.0, 0.0) if ew else Vector3(0.0, 0.0, tm))
		pos.y = hm + 0.06
		var pitch := atan2(h1 - h0, seg)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		mi.mesh = bm
		mi.material_override = asphalt
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = pos
		if ew:
			mi.rotation.z = pitch      # rotate about z: +x end lifts with rising ground
		else:
			mi.rotation.x = -pitch     # rotate about x: +z end lifts with rising ground
		root.add_child(mi)
		if body != null:              # collider only on resident cells (proxies skip it, Wave 4)
			var cs := CollisionShape3D.new()
			var bx := BoxShape3D.new()
			bx.size = sz
			cs.shape = bx
			cs.position = pos
			if ew:
				cs.rotation.z = pitch
			else:
				cs.rotation.x = -pitch
			body.add_child(cs)
	if body != null:
		root.add_child(body)
	if not collide:
		return   # far proxies: skip the dashed centerline (5 sub-pixel emissive boxes/strip, invisible at 40-88m = pure wasted draws)
	# dashed centerline: short softly-glowing boxes spaced along the road, riding the same heights
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.78, 0.70, 0.30)   # <= 0.85/channel: near-white dashes clipped in daylight
	line_mat.emission_enabled = true
	line_mat.emission = Color(0.8, 0.7, 0.2)
	line_mat.emission_energy_multiplier = 0.6
	var step := 3.0   # dash + gap
	var n := int(cell_size / step)
	for i in range(n):
		var t := -cell_size * 0.5 + step * (float(i) + 0.5)
		var dh0 := _ground_y(centre.x + t - 0.8, centre.z) if ew else _ground_y(centre.x, centre.z + t - 0.8)
		var dh1 := _ground_y(centre.x + t + 0.8, centre.z) if ew else _ground_y(centre.x, centre.z + t + 0.8)
		var dy := (_ground_y(centre.x + t, centre.z) if ew else _ground_y(centre.x, centre.z + t)) + 0.10
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.6, 0.04, 0.22) if ew else Vector3(0.22, 0.04, 1.6)
		mi.mesh = bm
		mi.material_override = line_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = centre + (Vector3(t, 0.0, 0.0) if ew else Vector3(0.0, 0.0, t))
		mi.position.y = dy
		var dpitch := atan2(dh1 - dh0, 1.6)
		if ew:
			mi.rotation.z = dpitch
		else:
			mi.rotation.x = -dpitch
		root.add_child(mi)


# ---------------- structures (parametric buildings) ----------------

# Place ONE parametric building (build_structure.gd) at a cell-local pos. The structure is base-grounded at
# y=0 by contract, so no AABB drop is needed; pos is clamped inside the cell. Parented to the cell root so
# eviction reclaims it. A `sound` field anchors a localized loop to the building (traffic/market hum).
# Wave 2: a structure built with an "interior" carries openable door leaves (group "gogi_door") — those are
# registered with the interaction system under cell_key AFTER the node is placed in the tree (registration
# reads the leaf's live transform) and die with the cell via _evict -> interaction.remove_cell.
# True when a structure spec opts into an enterable interior (build_structure._interior_spec accepts
# `interior: true` or an `interior: {...}` dict).
func _has_interior(spec: Dictionary) -> bool:
	var iv = spec.get("interior", null)
	return (typeof(iv) == TYPE_BOOL and iv) or typeof(iv) == TYPE_DICTIONARY


# World XZ of an enterable building's DOORWAY — the footprint-edge centre on the door face, honouring
# the building's `rot` (yaw, degrees) and `scale`. Used to ground the base at the door-side terrain so
# the threshold stays walkable on slopes. Mirrors build_structure._interior_spec's door_face default.
func _door_world_xz(spec: Dictionary, p: Vector3) -> Vector2:
	var iv = spec.get("interior", null)
	var face := "s"
	if typeof(iv) == TYPE_DICTIONARY:
		var f := String((iv as Dictionary).get("door_face", "s")).to_lower()
		# tolerate a door_face carried on the `door` key (same coercion build_structure does)
		if not (f in ["n", "s", "e", "w"]):
			f = String((iv as Dictionary).get("door", "s")).to_lower()
		if f in ["n", "s", "e", "w"]:
			face = f
	var foot := _xz(spec.get("footprint", [8, 8]))
	var sc := maxf(0.1, float(spec.get("scale", 1.0)))
	var local := Vector2.ZERO   # (x, z) offset from centre to the door, building-local
	match face:
		"n": local = Vector2(0.0, foot.y * 0.5)
		"e": local = Vector2(foot.x * 0.5, 0.0)
		"w": local = Vector2(-foot.x * 0.5, 0.0)
		_:   local = Vector2(0.0, -foot.y * 0.5)   # "s" (default, -Z face)
	local *= sc
	# rotate by the building yaw (Node3D.rotation.y about +Y: x' = x·c + z·s, z' = -x·s + z·c)
	var rot := deg_to_rad(float(spec.get("rot", 0.0)))
	var c := cos(rot)
	var s := sin(rot)
	return Vector2(p.x + local.x * c + local.y * s, p.z - local.x * s + local.y * c)


func _place_structure(root: Node, spec: Dictionary, centre: Vector3, half: float, cell_key := "") -> void:
	var node := GBuild.structure(spec)
	if node == null:
		return
	var xz := _xz(spec.get("pos", [0, 0]))
	var p := centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
	p.y = _ground_y(p.x, p.z)   # sit the building base on the terrain surface
	# INTERIOR ENTRY (slopes): an enterable building grounded at its CENTRE leaves the DOORWAY — at the
	# footprint EDGE, where the terrain differs on a slope — either a big step UP to the interior floor
	# (can't climb in past the step-up cap) or a door header BELOW head height (bonk the lintel). Both
	# read as "the door opens but I can't enter". Re-ground the base at the DOOR-SIDE terrain so the
	# threshold is always a ~0.1 m step, enterable from any slope and any door orientation.
	if _has_interior(spec):
		var dxz := _door_world_xz(spec, p)
		p.y = _ground_y(dxz.x, dxz.y)
	# ANTI-COINCIDENCE (Wave 3): lift a structure that lands (nearly) on top of one already placed in
	# this cell so their coplanar faces don't z-fight. Normal spaced-out worlds never trigger this
	# (bump stays 0); verify separately WARNs the author about the overlap.
	var foots: Array = _struct_foots.get(cell_key, [])
	var foot := _xz(spec.get("footprint", [8, 8]))
	var fsc := maxf(0.1, float(spec.get("scale", 1.0)))
	var frad := 0.5 * maxf(foot.x, foot.y) * fsc   # circle over-approx (rotation-safe) of the base
	var here := Vector2(p.x, p.z)
	for f in foots:
		if here.distance_to(f["c"]) < STRUCT_COINCIDE:
			p.y += STRUCT_ZLIFT
	if cell_key != "":
		foots.append({"c": here, "r": frad})
		_struct_foots[cell_key] = foots
	node.position = p
	root.add_child(node)
	_register_structure_doors(node, cell_key)
	var snd := String(spec.get("sound", ""))
	# stream_for() checks the .pck FIRST and then the remote cache, so this resolves a template
	# default AND a game's own loose bed. A ResourceLoader.exists() guard here would silently skip
	# every remote sound; stream_for returns null when genuinely unavailable and attach_loop no-ops.
	if snd != "":
		AudioManager.attach_loop(node, AudioManager.stream_for("res://audio/%s.ogg" % snd))


# Wave 2 (interiors): find every openable door LEAF inside a placed RESIDENT structure —
# build_structure.gd tags each swinging panel into node group "gogi_door" with meta "door_label"
# (the ONLY discovery channel, per the Wave-2 door contract) — and register it with the interaction
# system so USE opens/closes it. Entries carry the cell key, so eviction (_evict ->
# interaction.remove_cell) drops the registrations in the same breath that queue_free reclaims the
# nodes: registration dies with the cell, no ghost doors. Proxies never reach here — build_proxy
# strips the "interior" key before building (and _strip_physics degroups defensively).
func _register_structure_doors(structure: Node3D, cell_key: String) -> void:
	if interaction == null:
		return
	var stack: Array = [structure]
	while not stack.is_empty():
		var nn = stack.pop_back()
		for c in nn.get_children():
			stack.append(c)
		if nn is Node3D and (nn as Node3D).is_in_group("gogi_door"):
			interaction.add_structure_door(nn as Node3D,
				String(nn.get_meta("door_label", "Open Door")), cell_key)


# ---------------- layout (ARRANGEMENT axis) ----------------

# Place a repeated part along a LINE (colonnade / fence / streetlight row / avenue).
func _place_row(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var part = spec.get("part", null)
	if typeof(part) != TYPE_DICTIONARY:
		return
	var pts := GLayout.along(_xz(spec.get("from", [0, 0])), _xz(spec.get("to", [0, 0])),
		maxf(0.3, float(spec.get("spacing", 3.0))), float(spec.get("jitter", 0.0)))
	_place_parts(root, part, pts, centre, half)


# Place a repeated part around a rect PERIMETER (fence/wall/columns around a yard/court).
func _place_ring(root: Node, spec: Dictionary, centre: Vector3, half: float) -> void:
	var part = spec.get("part", null)
	if typeof(part) != TYPE_DICTIONARY:
		return
	var hv := _xz(spec.get("half", [4, 4]))
	var pts := GLayout.around(hv.x, hv.y, maxf(0.3, float(spec.get("spacing", 2.0))))
	_place_parts(root, part, pts, centre, half)


# Instance `part` at each cell-local point (capped for the live-node budget), grounded onto the terrain.
func _place_parts(root: Node, part: Dictionary, pts: Array, centre: Vector3, half: float) -> void:
	var cap := mini(pts.size(), 80)
	for i in cap:
		var p: Vector2 = pts[i]
		var node := _make_part(part)
		if node == null:
			continue
		var wp := centre + Vector3(clampf(p.x, -half + 0.3, half - 0.3), 0.0, clampf(p.y, -half + 0.3, half - 0.3))
		wp.y = _ground_y(wp.x, wp.z)
		node.position = wp
		if part.has("rot"):
			node.rotation.y = deg_to_rad(float(part["rot"]))
		root.add_child(node)


# Resolve a part spec to a base-at-origin Node3D WITH a collider: a GBuild structure, a GShapes primitive, or a
# library GLB. Null if unresolved (e.g. a url that didn't download).
func _make_part(part: Dictionary) -> Node3D:
	if typeof(part.get("structure", null)) == TYPE_DICTIONARY:
		return GBuild.structure(part["structure"])
	if part.has("shape"):
		var node := _shape_part(part)
		if node != null:
			GShapes.set_material(node, GSurf.surface(part.get("material", "concrete")))
			if String(part.get("collider", "box")) != "none":
				GShapes.add_collider(node, String(part.get("collider", "box")))
		return node
	var u := String(part.get("url", part.get("model", part.get("asset", ""))))
	if u != "":
		u = _resolve(u)
	elif part.has("kind"):
		u = builder._palette_url(part)
	if u != "" and builder.cache.has(u) and builder.cache[u] != null:
		var g := (builder.cache[u] as Node).duplicate() as Node3D
		if g == null:
			return null
		var ab := builder._world_aabb(g)
		var wrap := Node3D.new()
		g.position.y = -maxf(0.0, ab.position.y)   # GLB base -> wrapper origin (consistent placement)
		wrap.add_child(g)
		if String(part.get("collider", "box")) != "none":
			GShapes.add_collider(wrap, String(part.get("collider", "box")))
		return wrap
	return null


func _shape_part(part: Dictionary) -> Node3D:
	match String(part.get("shape", "")).to_lower():
		"box": return GShapes.box(_v3(part.get("size", [1, 2, 1])))
		"column": return GShapes.column(float(part.get("radius", 0.5)), float(part.get("height", 6.0)), int(part.get("sides", 24)))
		"cylinder": return GShapes.cylinder(float(part.get("radius", 0.5)), float(part.get("top_radius", part.get("radius", 0.5))), float(part.get("height", 3.0)), int(part.get("sides", 24)))
		"pyramid": return GShapes.pyramid(_xz(part.get("base", [2, 2])), float(part.get("height", 2.0)))
		"frustum": return GShapes.frustum(_xz(part.get("base", [2, 2])), _xz(part.get("top", [1, 1])), float(part.get("height", 3.0)))
		"wedge": return GShapes.wedge(_v3(part.get("size", [2, 1, 2])))
		"dome": return GShapes.dome(float(part.get("radius", 2.0)), float(part.get("height", 1.5)))
		"prism": return GShapes.prism_ngon(int(part.get("sides", 6)), float(part.get("radius", 0.5)), float(part.get("height", 3.0)))
	return null


func _v3(a) -> Vector3:
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3(1, 1, 1)


# ---------------- populate (Meshy KIT/CAST deploy: a varied many from a small set) ----------------

# Instance `count` models, each PICKED at random from `set` (a few generated GLBs) + per-instance variation
# (recolor/scale/yaw, cast.gd) so a handful reads as a real crowd / herd / varied prop field. Grounded onto the
# terrain, deterministic per cell (stable across reloads), parented to the cell (evicted with it).
# Wave 3: {"sit": true} on a STATIC entry registers every placed instance as a USE "Sit" target.
func _place_populate(root: Node, spec: Dictionary, centre: Vector3, half: float, cell_key := "") -> void:
	var set = spec.get("set", [])
	if not (set is Array) or (set as Array).is_empty():
		return
	var count := clampi(int(spec.get("count", 6)), 1, 30)
	if OS.has_feature("web"):
		count = mini(count, POP_WEB_CAP)   # mobile GPU can't draw a 30-strong high-poly skinned crowd (tribe/herd) — cap the LIVE count
	var do_vary := bool(spec.get("vary", true))
	var collide_spec = spec.get("collider", null)   # null = solid-by-default (SOLID_MIN_DIM rule)
	var snd := String(spec.get("sound", ""))
	var behaviour := String(spec.get("behaviour", spec.get("behavior", "static")))   # "static" | "wander"
	var cell_seed := int(centre.x) * 73856093 + int(centre.z) * 19349663
	for i in count:
		var rng := GCast.rng_for(cell_seed + i * 1013)
		var u := _resolve(GCast.pick(set, rng))
		if u == "" or not builder.cache.has(u) or builder.cache[u] == null:
			continue
		var n := (builder.cache[u] as Node).duplicate() as Node3D
		if n == null:
			continue
		if behaviour == "wander":
			_no_shadows(n)   # a moving crowd/herd of skinned characters doesn't cast shadows (perf)
		var ab := builder._world_aabb(n)
		# SCALE-NORMALIZE oversized library animals: some creature GLBs are authored at a HUGE scale
		# (fox.glb ~155 m, farm_Pig.glb ~10 m). Populate has no per-profile normalize like mounts/enemies,
		# so a raw instance renders as a GIANT animal that fills the sky when you fly over its cell. If the
		# model measures implausibly large, uniformly scale it down to ~2 m. Skin-baked-scale rigs (Meshy
		# civilians read a tiny ~0.02 m mesh-bind AABB here) fall UNDER the threshold and keep their natural
		# render size, so people crowds are unchanged; only the oversized library beasts are corrected.
		var mdim: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
		if mdim > float(spec.get("max_size", 4.0)):
			n.scale *= float(spec.get("scale", 2.0)) / mdim
			ab = builder._world_aabb(n)   # re-measure so the grounding below uses the scaled base
		n.position.y = -maxf(0.0, ab.position.y)   # GLB base -> origin (collider added BEFORE the wrap scales)
		# SOLID-BY-DEFAULT (shared SOLID_MIN_DIM contract): a big-enough instance blocks the player
		# unless the spec opts out with collider:false/"none".
		var cmode := _collider_mode(collide_spec, ab, u)
		if cmode != "none":
			GShapes.add_collider(n, cmode)
		# Clip retarget (same guard as enemy.gd): library people ship with NO
		# embedded clips — without this the crowd GLIDES IN A T-POSE because
		# WanderAgent finds no walk/idle to play. Models that already carry
		# clips (Meshy rigged characters) are left untouched.
		var pap := AnimRig._find_ap(n)
		if pap == null or pap.get_animation_list().is_empty():
			AnimRig.attach(n, {"idle": "Idle_A", "walk": "Walking_A"}, ["idle", "walk"])
		var wrap: Node3D = WanderAgent.new() if behaviour == "wander" else Node3D.new()
		wrap.add_child(n)
		if do_vary:
			GCast.vary(wrap, rng)
		var spot := Vector2(rng.randf_range(-half + 1.0, half - 1.0), rng.randf_range(-half + 1.0, half - 1.0))
		var wp := centre + Vector3(spot.x, 0.0, spot.y)
		wp.y = _ground_y(wp.x, wp.z)
		wrap.position = wp
		root.add_child(wrap)
		if behaviour == "wander":
			(wrap as WanderAgent).setup(terrain, Vector2(wp.x, wp.z), float(spec.get("radius", 6.0)), float(spec.get("speed", 1.5)), cell_seed + i, (water_level if water_cfg != null else -1e9), bool(spec.get("aquatic", false)))
		# SITTABLE (Wave 3, mirror of the "sound" plumbing): {"sit": true} makes THIS instance a USE
		# "Sit" target (a bench/chair/log set — each placed copy is its own seat). Seat surface = the
		# instance's world-AABB top clamped 0.3–1.2 m above the local ground. Wandering instances are
		# excluded — a seat that walks away breaks the stored seat point (riding a creature is the
		# vehicles[] mount-profile path, not furniture).
		if interaction != null and behaviour != "wander" and bool(spec.get("sit", false)):
			var sab := builder._world_aabb(wrap)
			var sgy := _ground_y(wp.x, wp.z)
			interaction.add_seat(wrap, sgy + clampf(sab.end.y - sgy, 0.3, 1.2), cell_key)
		if snd != "":
			AudioManager.attach_loop(wrap, AudioManager.stream_for("res://audio/%s.ogg" % snd))


# ---------------- ambient traffic ----------------

# Spawn cars driving along this cell's roads (traffic.gd). For each road, lay `count` cars in a lane offset to one
# side, staggered along the lane + looping, so the street has moving traffic. One-way ambient per lane.
func _place_traffic(root: Node, spec: Dictionary, road_list: Array, centre: Vector3, half: float) -> void:
	var set = spec.get("set", [])
	if not (set is Array) or (set as Array).is_empty():
		return
	var count := clampi(int(spec.get("count", 3)), 1, 10)
	var speed := float(spec.get("speed", 6.0))
	var lane := clampf(float(spec.get("lane", half * 0.25)), 0.5, half - 0.5)
	var cell_seed := int(centre.x) * 9176 + int(centre.z) * 4423
	var idx := 0
	for r in road_list:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var dir := String(r.get("dir", "ew")).to_lower()
		var dds: Array = ["ew", "ns"] if (dir == "x" or dir == "cross" or dir == "+") else [dir]
		for dd in dds:
			var a: Vector3
			var b: Vector3
			if dd == "ns":
				a = centre + Vector3(-lane, 0.0, -half)
				b = centre + Vector3(-lane, 0.0, half)
			else:
				a = centre + Vector3(-half, 0.0, lane)
				b = centre + Vector3(half, 0.0, lane)
			for k in count:
				var rng := GCast.rng_for(cell_seed + idx)
				idx += 1
				var u := _resolve(GCast.pick(set, rng))
				if u == "" or not builder.cache.has(u) or builder.cache[u] == null:
					continue
				var model := (builder.cache[u] as Node).duplicate() as Node3D
				if model == null:
					continue
				# CAR NORMALIZATION (world-streaming.md §8): source vehicles arrive at wildly
				# different scales (toy-sized library GLBs vs Meshy exports); scale UNIFORMLY so
				# the longest HORIZONTAL dimension is CAR_TARGET_LEN, then re-ground from the
				# SCALED bounds so the wheels still touch the road.
				var ab := builder._world_aabb(model)
				var hdim := maxf(ab.size.x, ab.size.z)
				if hdim > 0.001:
					var sc := clampf(CAR_TARGET_LEN / hdim, 0.5, 12.0)
					if not is_equal_approx(sc, 1.0):
						model.scale *= sc
						ab = builder._world_aabb(model)
				model.position.y = -maxf(0.0, ab.position.y)   # car base -> origin
				var car := TrafficCar.new()
				car.add_child(model)
				root.add_child(car)
				car.setup(a, b, speed, terrain, float(k) / float(count))


# ---------------- per-cell scenery (Phase 1) ----------------

# Resolve a scenery ref to an absolute asset URL. Accepts {kind:"<palette>"} (library palette)
# OR {url|model|asset:"<path>"} where <path> is a full https url, a leading-slash R2 path
# (e.g. /<BUILD_ID>/models/keep.glb for a Meshy asset, or /godot-assets/...), or a bare
# "group/file.glb" relative to the library.
func _asset_url(ref) -> String:
	if typeof(ref) != TYPE_DICTIONARY:
		return ""
	var u := String(ref.get("url", ref.get("model", ref.get("asset", ""))))
	if u != "":
		return _resolve(u)
	return builder._palette_url(ref)   # {kind} -> origin + PALETTE[kind] (or "")


func _resolve(u: String) -> String:
	# Delegate to main's _norm so absolute /cloud-<id>/ paths get the SAME build-id self-heal
	# scenery/vehicle URLs get — this resolver used to keep NPC/enemy models pinned to the
	# stale authoring build's path (404 -> gray placeholder on any rebuild/bare-origin serve).
	if world_main != null and world_main.has_method("_norm"):
		return String(world_main.call("_norm", u))
	if u.begins_with("http"):
		return u
	if u.begins_with("/"):
		return builder.origin + u
	return builder.origin + "/godot-assets/" + u


# NPC model URL. A cell's npc may set {model|url|asset:"<path>"} to render as a CUSTOM character —
# a Meshy-generated person at /<BUILD_ID>/models/<name>.glb, a /godot-assets/... library char, a
# full https url, or a bare "group/file.glb". With no such field it falls back to the default
# library NPC model (KayKit Knight). interaction.add_npc idle-animates self-animated models (Meshy
# chars ship their own AnimationPlayer), so a generated person renders + idles, not T-posed.
func _npc_model_url(npc) -> String:
	if typeof(npc) == TYPE_DICTIONARY:
		var u := String(npc.get("model", npc.get("url", npc.get("asset", ""))))
		if u != "":
			return _resolve(u)
	# no per-NPC model: prefer the world-level default (a setting-appropriate character) so an
	# unmodelled NPC isn't the medieval-knight library fallback in a modern/realistic world.
	if default_npc_model != "":
		return _resolve(default_npc_model)
	return builder.origin + AreaBuilder.NPC_MODEL


# Enemy model URL. A cell may set {enemy_model|enemy_url:"<path>"} so its enemies render as a CUSTOM
# creature (e.g. a Meshy villain) instead of the default skeleton; same path forms as above. enemy.gd
# auto-plays an embedded AnimationPlayer (self-animated Meshy chars) or retargets KayKit rigs via
# AnimRig, so either model type animates. With no field it falls back to the default skeleton.
func _enemy_model_url(rec) -> String:
	if typeof(rec) == TYPE_DICTIONARY:
		var u := String(rec.get("enemy_model", rec.get("enemy_url", "")))
		if u != "":
			return _resolve(u)
	return builder.origin + SKELETON


# read a cell-LOCAL [x,z] (or [x,y,z]) offset from a ref's pos field
func _xz(p) -> Vector2:
	if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2:
		var zi := 2 if (p as Array).size() > 2 else 1
		return Vector2(float(p[0]), float(p[zi]))
	return Vector2.ZERO


# Place ONE individual prop/landmark: instance from cache, position cell-local, scale, GROUND
# (drop so its base rests on the floor at y=0; never lift embedded meshes), then a box or trimesh
# collider. collider:"mesh" -> ConcavePolygonShape3D so the player walks INTO it (arches/rooms/gates).
# Wave 3: {"sit": true} additionally registers the placed object as a USE "Sit" target.
func _place_one(root: Node, ref, centre: Vector3, half: float, cell_key := "") -> bool:
	if typeof(ref) != TYPE_DICTIONARY:
		return false
	# LADDER (Wave 2 climb): a {"shape":"ladder","height":H} prop is built straight from the shape
	# vocabulary (no GLB fetch) and registered as a walk-through "Climb" target — handled here, before
	# the asset-url path (which would early-return false on a shape-only spec).
	if String(ref.get("shape", "")).to_lower() == "ladder":
		return _place_ladder(root, ref, centre, half, cell_key)
	var url := _asset_url(ref)
	if url == "" or not builder.cache.has(url):
		return false
	var src = builder.cache[url]
	if src == null:
		return false
	var n := (src as Node).duplicate() as Node3D
	if n == null:
		return false
	root.add_child(n)
	var xz := _xz(ref.get("pos", [0, 0]))
	n.position = centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
	if ref.has("rot"):
		n.rotation.y = deg_to_rad(float(ref.get("rot", 0.0)))
	var sc := float(ref.get("scale", 1.0))
	if sc > 0.0 and sc != 1.0:
		n.scale = Vector3(sc, sc, sc)
	# SCALE SANITY: a hallucinated `scale` (the 160-280x coastal-stroll failure) or
	# oversized source art must never make a prop span the whole cell. Cap the
	# horizontal FOOTPRINT to the cell; height is left alone so tall-but-thin
	# buildings/towers still work.
	var foot_ab := builder._world_aabb(n)
	var foot := maxf(foot_ab.size.x, foot_ab.size.z)
	if foot > half * 2.0 and foot > 0.001:
		n.scale *= (half * 2.0) / foot
	# GROUND: floor top is y=0; drop the model so its lowest point rests there (origins vary per .glb)
	var ab := builder._world_aabb(n)
	n.position.y -= maxf(0.0, ab.position.y)
	n.position.y += _ground_y(n.position.x, n.position.z)   # then lift onto the terrain surface
	if maxf(ab.size.x, maxf(ab.size.y, ab.size.z)) >= BIG_ASSET_DIM:
		_no_shadows(n)   # a huge landmark/creature's shadow pass is a main cause of "big monster" lag
	# SOLID-BY-DEFAULT (shared SOLID_MIN_DIM contract): props + landmarks big enough to read as an
	# obstacle get a derived box (or the explicit "mesh" trimesh); collider:false/"none" opts out.
	var cmode := _collider_mode(ref.get("collider", null), ab, _asset_url(ref))
	if cmode == "mesh" or cmode == "mesh_exact":
		# "mesh_exact" opts OUT of the convex substitution in _collision_shape_for — use it when a
		# doorway/arch/tunnel must stay passable and a hull would seal it.
		_add_mesh_collision(n, cmode == "mesh_exact", _asset_url(ref))
	elif cmode == "trunk":
		GShapes.add_collider(n, "trunk")   # TREES: slim trunk pole, NOT builder's full-canopy box (this path was the real bug)
	elif cmode != "none":
		builder._add_prop_collision(n, root)
	# POSITIONAL place sound (a fountain hums, a machine whirs, a road has traffic) —
	# anchored to THIS prop so it fades with distance, NOT a global bed. world.json:
	# {"url":…, "sound":"fountain"} → res://audio/fountain.ogg (curl the loop into res://audio/).
	var snd := String(ref.get("sound", ""))
	if snd != "":
		AudioManager.attach_loop(n, AudioManager.stream_for("res://audio/%s.ogg" % snd))
	# SITTABLE (Wave 3, mirror of the "sound" plumbing above): {"sit": true} turns this placed
	# object into a USE "Sit" target — registered under this cell's key so eviction/hot-reload
	# drops the seat (remove_cell stands a seated player first). Seat surface = the object's
	# world-AABB top clamped 0.3–1.2 m above the local ground under it.
	if interaction != null and bool(ref.get("sit", false)):
		var sab := builder._world_aabb(n)
		var sgy := _ground_y(n.position.x, n.position.z)
		interaction.add_seat(n, sgy + clampf(sab.end.y - sgy, 0.3, 1.2), cell_key)
	# CLIMBABLE (Wave 2, mirror of the "sit" plumbing above): {"climb": true} on a placed GLB prop (a
	# modeled ladder/scaffold) registers it as a "Climb" target — the controller drives the Y climb from
	# the grounded foot (n.position) up by the climb height (an explicit "height" or the world-AABB
	# height). Outward step-off facing = the ladder's local +Z rotated by `rot`. A purely-climbable prop
	# should set collider:"none" so its box doesn't block approach to the base (solid-by-default otherwise).
	if interaction != null and bool(ref.get("climb", false)):
		var ch := maxf(0.6, float(ref.get("height", ab.size.y)))
		var cyaw := deg_to_rad(float(ref.get("rot", 0.0)))
		interaction.add_ladder(n.position, ch, Vector3(sin(cyaw), 0.0, cos(cyaw)), n, cell_key)
	return true


# Build + place a {"shape":"ladder"} prop from the shape vocabulary and register it as a "Climb"
# interactable. NO collider by contract: it is WALK-THROUGH — the player-controller drives the vertical
# climb along Y between base_y and top_y (a solid ladder would read as a wall and block the ascent).
# Grounded so the foot rests on the surface; `rot` yaws the ladder AND defines the outward step-off
# facing (local +Z after yaw = where the player steps onto the top surface). Registered under cell_key
# so _evict -> interaction.remove_cell drops it with the cell (no ghost ladder). An optional "material"
# overrides the baked wood look via the surface cookbook. Returns true so it counts against PROP_CAP.
func _place_ladder(root: Node, ref: Dictionary, centre: Vector3, half: float, cell_key: String) -> bool:
	var height := maxf(0.6, float(ref.get("height", 3.0)))
	var node := GShapes.ladder(height, float(ref.get("width", 0.5)))
	if ref.has("material"):
		GShapes.set_material(node, GSurf.surface(String(ref.get("material", "wood"))))
	root.add_child(node)
	var xz := _xz(ref.get("pos", [0, 0]))
	node.position = centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
	var yaw := deg_to_rad(float(ref.get("rot", 0.0)))
	node.rotation.y = yaw
	node.position.y = _ground_y(node.position.x, node.position.z)   # foot on the terrain surface
	if interaction != null:
		# outward step-off = the ladder's local +Z after yaw (rot=0 -> +Z); the player steps forward
		# onto the surface here at the top of the climb.
		var anchor := node.position
		var top_y := node.position.y + height
		# A gorge-escape ladder's foot can rest metres below the water line — a swimmer grabs it at
		# the SURFACE, so the USE anchor rides the water level (a foot anchor ~13m underwater sat
		# outside the floating player's USE range: the escape was dead). The climb still tops out
		# at the ladder's real top.
		if water_cfg != null and anchor.y < water_level - 0.5:
			anchor.y = water_level
		interaction.add_ladder(anchor, maxf(1.0, top_y - anchor.y), Vector3(sin(yaw), 0.0, cos(yaw)), node, cell_key)
	return true


# Scatter N copies of one decorative mesh as a SINGLE MultiMeshInstance3D (= one draw call).
# Grounded by the source mesh's base offset. SOLID-BY-DEFAULT keyed on the FOOTPRINT (x,z) only: an
# entry with a wide enough footprint also gets a PARALLEL per-instance shape container (the visual
# stays one draw call); tall-thin foliage (grass/reeds) and tiny clutter (pebbles) stay walkthrough
# regardless of height, so ambient scenery never fences the player/NPCs/vehicles in.
func _place_scatter(root: Node, ref, centre: Vector3, half: float, collide := true) -> void:
	if typeof(ref) != TYPE_DICTIONARY:
		return
	var url := _asset_url(ref)
	if url == "" or not builder.cache.has(url):
		return
	var src = builder.cache[url]
	if src == null:
		return
	var cnt := clampi(int(ref.get("count", 8)), 1, SCATTER_MAX)
	var cspec = ref.get("collider", null)   # null = solid-by-default (SOLID_MIN_DIM rule)
	var mesh := _extract_mesh(src as Node)
	if mesh != null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = cnt
		# bake the GLB's node transform (many library assets: 1/100 verts under a x100 node)
		# into every instance, or the scatter renders centimetre-tall (the invisible-forest bug)
		var mxf := _extract_mesh_xform(src as Node)
		var tab: AABB = mxf * mesh.get_aabb()               # authored-size bounds
		var drop := maxf(0.0, tab.position.y)               # source-mesh base offset
		# SCALE SANITY: scatter is small ambient clutter — cap an oversized source
		# mesh so a single instance can't fill the cell (footprint <= ~5u).
		var msz := tab.size
		var mdim := maxf(msz.x, msz.z)
		var base := 1.0 if (mdim <= 5.0 or mdim < 0.001) else 5.0 / mdim
		# solid entry (base-scaled mesh AABB max-dim >= SOLID_MIN_DIM, no opt-out) -> ONE
		# StaticBody3D holding a box shape per instance, parented to the cell root below so
		# eviction reclaims the physics together with the visuals.
		var body: StaticBody3D = null
		# FOOTPRINT-GATED solid-by-default for scatter: the auto-collider keys on the horizontal
		# footprint (x,z) ONLY, not height — so tall-thin foliage (grass/reeds/stalks) stays
		# WALK-THROUGH while wide clutter (rocks/wide bushes) can still auto-collide. Individually-
		# placed props/landmarks keep the full-AABB rule (they don't route through here); only ambient
		# scatter is relaxed. Explicit collider:true/false/"mesh" still wins over this default.
		var foot_sz := msz * base
		# scattered TREES ("trunk" mode) stay WALK-THROUGH here (a per-instance pole isn't worth the cost for
		# ambient scatter, and it's what makes the jungle traversable); solid clutter (box/mesh) still collides.
		if collide and _collider_mode(cspec, AABB(Vector3.ZERO, Vector3(foot_sz.x, 0.0, foot_sz.z)), url) in ["box", "mesh"]:
			body = StaticBody3D.new()
			body.collision_layer = 1
			body.position = centre
		for i in range(cnt):
			var sj := randf_range(0.8, 1.2) * base
			var b := Basis().rotated(Vector3.UP, randf() * TAU).scaled(Vector3(sj, sj, sj)) * mxf.basis
			var spot := Vector2(randf_range(-half + 1.0, half - 1.0), randf_range(-half + 1.0, half - 1.0))
			var sy := -drop * sj + _ground_y(centre.x + spot.x, centre.z + spot.y)   # ride the terrain
			mm.set_instance_transform(i, Transform3D(b, Vector3(spot.x, sy, spot.y)))
			if body != null:
				var cs := CollisionShape3D.new()
				var bx := BoxShape3D.new()
				bx.size = msz * sj   # scale baked into the SHAPE (a scaled CollisionShape3D is unsupported)
				cs.shape = bx
				# same yaw + spot as the instance, box centred on the instance's authored-AABB centre
				cs.transform = Transform3D(Basis(b.get_rotation_quaternion()),
					Vector3(spot.x, sy, spot.y) + Basis(b.get_rotation_quaternion()) * (tab.get_center() * sj))
				body.add_child(cs)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # dense resident foliage was drawn TWICE (colour + 42m shadow cascade); ambient clutter shadows are cosmetically negligible — half the fill
		mmi.position = centre
		root.add_child(mmi)
		if body != null:
			root.add_child(body)
		return
	# fallback (multi-mesh asset): a few duplicated nodes instead of a MultiMesh
	for i in range(mini(cnt, 6)):
		var d := (src as Node).duplicate() as Node3D
		if d == null:
			continue
		root.add_child(d)
		d.position = centre + Vector3(randf_range(-half + 1.0, half - 1.0), 0.0, randf_range(-half + 1.0, half - 1.0))
		d.rotation.y = randf() * TAU
		var ab := builder._world_aabb(d)
		d.position.y -= maxf(0.0, ab.position.y)
		# same FOOTPRINT-gated rule for the duplicated-node fallback (flatten Y so tall-thin foliage
		# stays walk-through; wide clutter can still collide)
		if _collider_mode(cspec, AABB(ab.position, Vector3(ab.size.x, 0.0, ab.size.z)), url) != "none":
			builder._add_prop_collision(d, root)


# first usable Mesh in a loaded GLB scene (handles both runtime MeshInstance3D and headless
# ImporterMeshInstance3D) — for MultiMesh scatter
func _extract_mesh(scene: Node) -> Mesh:
	var stack: Array = [scene]
	while not stack.is_empty():
		var nn = stack.pop_back()
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			return (nn as MeshInstance3D).mesh
		if nn is ImporterMeshInstance3D and (nn as ImporterMeshInstance3D).mesh != null:
			return (nn as ImporterMeshInstance3D).mesh.get_mesh()
		for c in nn.get_children():
			stack.append(c)
	return null


# The cumulative node TRANSFORM from `scene` down to its first mesh. Many library GLBs
# (q_unature, kenney_nature) keep vertices at 1/100 scale under a x100 node transform, so a
# MultiMesh built from the RAW mesh renders centimetre-tall trees (the invisible-forest bug).
# Bake this into every scatter instance so the mesh renders at its authored size.
func _extract_mesh_xform(scene: Node) -> Transform3D:
	var stack: Array = [[scene, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var nn = entry[0]
		var xf: Transform3D = entry[1]
		if nn is Node3D:
			xf = xf * (nn as Node3D).transform
		if (nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null) \
				or (nn is ImporterMeshInstance3D and (nn as ImporterMeshInstance3D).mesh != null):
			return xf
		for c in nn.get_children():
			stack.append([c, xf])
	return Transform3D.IDENTITY


# Stop a node's meshes casting Directional shadows (recursive). A skinned character (or a huge asset)
# pays a SECOND full skin/mesh pass into the shadow map every frame; dropping it is the biggest safe
# GPU win when several characters or a big monster cluster near the player. Terrain/roads/structures
# keep their shadows (already tuned), so the scene still reads grounded.
func _no_shadows(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_no_shadows(c)


# Trimesh (concave) static collider over every mesh in a prop -> walkable interiors/gates/arches.
#
var _on_web := OS.has_feature("web")   # cached: gates the mobile particle/fill budgets (see _place_mood)


# Trimesh (concave) static collider over every mesh in a prop -> walkable interiors/gates/arches.
# STOCK immediate bake. A deferred queue + a shared shape cache were tried here and BOTH were
# reverted: a hard freeze appeared on-device that had not existed before, and new machinery on the
# collision hot path was the only plausible source. The measured 43ms bake they were meant to avoid
# is instead addressed at the DATA end — by decimating the few `collider:"mesh"` landmarks heavy
# enough to cause it. Do not reintroduce caching here without a way to reproduce that freeze.
func _add_mesh_collision(node: Node, exact := false, asset := "") -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		var nn = stack.pop_back()
		for c in nn.get_children():
			stack.append(c)
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			var mi := nn as MeshInstance3D
			if _threaded_shapes:
				var id := WorkerThreadPool.add_task(
					_shape_worker.bind({"mi": mi, "mesh": mi.mesh, "exact": exact, "asset": asset}),
					false, "gogi_trimesh")
				_shape_tasks[id] = true
			else:
				# WEB: same SHAPE CHOICE as native (that is the win — see _collision_shape_for),
				# just built inline because `nothreads` WASM has nowhere else to build it.
				var sh := _collision_shape_for(mi.mesh, exact)
				_report_hull(asset, mi.mesh, sh)
				_attach_shape(mi, sh)


# THE COLLISION-COST FIX, shared by both tiers.
#
# MEASURED at the wall on device: `player.move_and_slide()` alone cost 76ms, one enemy's physics tick
# 72ms, and the engine's own physics step 139ms. ConcavePolygonShape3D has NO internal broadphase —
# its cost scales with triangle count and is paid EVERY TICK by EVERY body touching it, so a detailed
# prop taxes the player and every NPC forever, not just when it streams in.
#
# The split is by triangle count because that tracks what the mesh IS:
#   LOW-POLY  -> concave trimesh. Architecture — gate arches, doorways, the wall's opening. Concavity
#                is the entire point and must survive so the player can walk through.
#   HIGH-POLY -> convex hull. Detailed art — statues, boulders, totems. Convex-ish blobs you only
#                bump into, so a hull is indistinguishable in play and orders of magnitude cheaper.
#
# This is NOT a threading fix and never was: the web tier pays the same per-tick cost, so it runs
# here too. Only WHERE the shape gets built differs between tiers.
static func _collision_shape_for(mesh: Mesh, exact := false) -> Shape3D:
	if mesh == null:
		return null
	if not exact and _tri_verts(mesh) > TRIMESH_MAX_VERTS:
		return mesh.create_convex_shape(true, true)   # clean + simplify
	return mesh.create_trimesh_shape()


# Triangle CORNERS (3 per triangle), matching what get_faces() would report — but read from the
# surface metadata instead of get_faces(), which copies the whole geometry. That copy is itself
# expensive, and on web it would run on the frame thread and eat part of the win.
static func _tri_verts(mesh: Mesh) -> int:
	var am := mesh as ArrayMesh
	if am == null:
		return mesh.get_faces().size()
	var n := 0
	for i in am.get_surface_count():
		if am.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var idx := am.surface_get_array_index_len(i)
		n += idx if idx > 0 else am.surface_get_array_len(i)
	return n


# Mirrors exactly what create_trimesh_collision() builds — a StaticBody3D child holding a
# CollisionShape3D — so collision layers and transforms are identical however the shape was made.
# Announce a convex SUBSTITUTION so it is never silent.
#
# A hull is a solid blob: it keeps the prop's outer form but loses any hole through it. For the 16
# `collider:"mesh"` records in a world like Kong that is the right trade, but a doorway or arch that
# MUST stay passable would be sealed with no symptom until a player walked into it. verify.mjs greps
# this line and WARNs, naming the asset, so the swap shows up at build time and `collider:"mesh_exact"`
# is the documented answer.
static func _report_hull(asset: String, mesh, shape) -> void:
	if asset == "" or shape == null or not (shape is ConvexPolygonShape3D):
		return
	if asset in _hull_reported:
		return          # once per asset, not once per placement (11 huts = 1 line)
	_hull_reported[asset] = true
	var n := 0
	if mesh is Mesh:
		n = _tri_verts(mesh)
	print("GOGI_COLLIDER_HULL %s tris=%d (concave collider replaced by a convex hull; any hole through this prop is now closed — set collider:\"mesh_exact\" if it must stay passable)" % [asset, n / 3])


static var _hull_reported := {}


static func _attach_shape(mi: MeshInstance3D, shape: Shape3D) -> void:
	if shape == null or mi == null or not is_instance_valid(mi):
		return
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	mi.add_child(body)


# ---- THREADED TRIMESH BAKE (native only) --------------------------------------------------------
# MEASURED: main._process peaked at 386ms on device while streaming, and this is what it was. The
# note above records a 43ms bake PER MESH — a cell that places several `collider:"mesh"` landmarks
# stacks those into one frame, which is the "lag near heavy assets" that has been there all along.
#
# The reverted attempt described above deferred the bake with a QUEUE and a shape CACHE, and a hard
# on-device freeze followed. That freeze was later traced to the memory ceiling and fixed elsewhere
# (GLB_CACHE_CAP 48->32, WEB_TEX_CAP 512->320). This is deliberately NOT that: no cache, no
# reordering, no shared state — the same shape is built for the same mesh exactly once, just on a
# worker thread instead of the frame thread. And it is NATIVE-ONLY, so the web tier that the freeze
# was observed on keeps the stock immediate bake, byte for byte.
#
# Only `Mesh.create_trimesh_shape()` moves off-thread; it reads the mesh and builds a BVH, touching
# no scene state. Attaching the body is main-thread, in _drain_shapes below.
const COLLIDER_THREADS := 3
# get_faces() returns 3 verts per triangle, so this is ~1,000 triangles. Above it a mesh is detailed
# art rather than architecture and gets a convex hull instead of a concave trimesh — see _shape_worker.
const TRIMESH_MAX_VERTS := 3000
var _threaded_shapes := not OS.has_feature("web")
var _shape_tasks := {}                # WorkerThreadPool id -> true, for the _exit_tree drain
var _shape_done: Array = []           # [{mi, shape}] baked shapes awaiting main-thread attach
var _shape_mutex := Mutex.new()       # guards _shape_done ONLY

# ---- THREADED HORIZON RE-MESH (native only) -----------------------------------------------------
# The far skirt and the water body are each a ~224m-radius grid whose every corner samples terrain
# noise, and both are rebuilt when the player crosses a cell. MEASURED at 360ms of a 374ms frame on
# device — the largest single spike in the game and the "lag near heavy assets" that survived every
# other fix. The mesh build is pure math (terrain.far_skirt_mesh / GWater.body_mesh), so it moves to
# a worker; only wrapping it in a MeshInstance3D and parenting stays on the frame thread.
#
# The OLD mesh is left in place until the new one lands, so the horizon never gaps. Web keeps the
# synchronous path unchanged.
var _far_building := false
var _water_building := false
var _far_mesh: ArrayMesh = null       # finished skirt awaiting main-thread swap
var _water_mesh: ArrayMesh = null
var _mesh_tasks := {}                 # WorkerThreadPool id -> true, for the _exit_tree drain
var _mesh_mutex := Mutex.new()        # guards _far_mesh / _water_mesh ONLY


func _far_worker(c: Vector3) -> void:
	var m := terrain.far_skirt_mesh(c, cell_size * 14.0, 44)
	_mesh_mutex.lock()
	_far_mesh = m
	_mesh_mutex.unlock()


func _water_worker(c: Vector3) -> void:
	var m := GWater.body_mesh(c, cell_size * 14.0, water_level, terrain, 48, water_cfg)
	_mesh_mutex.lock()
	_water_mesh = m
	_mesh_mutex.unlock()


# MAIN THREAD. Swap in any horizon mesh that finished baking. Freeing the old node only HERE means
# the player never sees a missing skirt or a missing ocean.
func _drain_meshes() -> void:
	if _far_mesh == null and _water_mesh == null:
		return
	_mesh_mutex.lock()
	var fm := _far_mesh
	var wm := _water_mesh
	_far_mesh = null
	_water_mesh = null
	_mesh_mutex.unlock()
	if fm != null and _nav_root != null and is_instance_valid(_nav_root):
		if _far != null and is_instance_valid(_far):
			_far.queue_free()
		_far = terrain.far_skirt_wrap(fm)
		_nav_root.add_child(_far)
		_far_building = false
	if wm != null and _nav_root != null and is_instance_valid(_nav_root):
		if _water != null and is_instance_valid(_water):
			_water.queue_free()
		_water = GWater.body_wrap(wm, water_cfg)
		_nav_root.add_child(_water)
		_water_building = false


# WORKER THREAD. Touches only the mesh (read-only) and _shape_done under the mutex. `mi` is carried
# through untouched — the worker never dereferences it, because a Node is not thread-safe and may
# already be freed by the time this lands.
func _shape_worker(item: Dictionary) -> void:
	# The SHAPE CHOICE lives in _collision_shape_for so both tiers are guaranteed identical; the only
	# thing native buys is that this runs off the frame thread.
	var shape := _collision_shape_for(item["mesh"], bool(item.get("exact", false)))
	_shape_mutex.lock()
	_shape_done.append({"mi": item["mi"], "shape": shape,
		"asset": item.get("asset", ""), "mesh": item["mesh"]})
	_shape_mutex.unlock()


# MAIN THREAD. Attach whatever finished baking. Mirrors exactly what create_trimesh_collision() does
# (a StaticBody3D child holding a CollisionShape3D), so collision layers and transforms are identical
# to the stock path — this changes WHEN the shape is built, never WHAT it is.
#
# The prop is visible for the frames between placement and attach. That is the one behavioural
# difference, and it is bounded: cells build ahead of the player at RING_RADIUS, so a prop is
# normally solid long before it is reachable.
func _drain_shapes() -> void:
	if _shape_done.is_empty():
		return
	_shape_mutex.lock()
	var done: Array = _shape_done
	_shape_done = []
	_shape_mutex.unlock()
	for d in done:
		# Reported from the MAIN thread — printing from a worker interleaves with other output.
		_report_hull(String(d.get("asset", "")), d.get("mesh"), d["shape"])
		# _attach_shape self-guards a pruned cell (the node can be freed while a bake is in flight).
		_attach_shape(d["mi"] as MeshInstance3D, d["shape"])


# A worker holds a Callable bound to THIS node; freeing it mid-bake would let a thread write into a
# dead object. Block on every outstanding task first.
func _exit_tree() -> void:
	for id in _shape_tasks.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	_shape_tasks.clear()
	for id in _mesh_tasks.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	_mesh_tasks.clear()


# Resolve a spec's `collider` field + the object's AABB to a collider mode ("box"/"mesh"/"none").
# SOLID-BY-DEFAULT (shared SOLID_MIN_DIM contract, world-streaming.md §8): no field -> a box
# collider when the AABB's largest dimension >= SOLID_MIN_DIM, walkthrough decoration below it.
# Explicit false/"none" always opts out; explicit true -> "box"; any other string is used as-is.
func _collider_mode(spec_val, ab: AABB, asset := "") -> String:
	if typeof(spec_val) == TYPE_BOOL:
		return "box" if spec_val else "none"
	if typeof(spec_val) == TYPE_STRING and String(spec_val) != "":
		return String(spec_val)
	# DEFAULT (no explicit collider): SOFT VEGETATION — bushes, grass, flowers, ferns, reeds, hedges —
	# is WALK-THROUGH so the player pushes through foliage instead of hitting a brick wall. TREES/logs
	# keep the size rule (a trunk stays solid). An explicit collider:true/false/"mesh" still wins above.
	if asset != "" and _is_soft_vegetation(asset):
		return "none"
	var dim := maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	if dim < SOLID_MIN_DIM:
		return "none"
	# TREES/trunks/logs/palms: a slim TRUNK-only collider, not the full canopy-wide box — so the player
	# moves freely through the foliage/canopy footprint and only the narrow trunk blocks them (universal,
	# keyed on the asset name like the soft-veg rule).
	if asset != "" and _is_tree_like(asset):
		return "trunk"
	return "box"


# Soft, pushable vegetation (bushes, grass, flowers, ferns, shrubs, reeds, hedges, weeds, ivy, moss)
# keyed on the asset name/URL — rendered WALK-THROUGH by default so foliage never blocks the player.
# TREES / trunks / logs / stumps are deliberately EXCLUDED (a trunk stays a solid obstacle).
static func _is_soft_vegetation(asset: String) -> bool:
	if _is_tree_like(asset):
		return false
	var s := asset.to_lower()
	for kw in ["bush", "shrub", "grass", "fern", "flower", "weed", "reed", "hedge", "foliage",
			"ivy", "bramble", "sprout", "tuft", "clover", "moss", "vine", "blossom", "berries",
			"fungus", "mushroom", "plant", "petal", "lily", "nettle", "thistle", "sedge"]:
		if kw in s:
			return true
	return false


# Tree-class assets (trees/trunks/logs/stumps/palms) — EXCLUDED from soft-vegetation (a trunk stays a
# solid obstacle) and given a slim TRUNK-only collider (see _collider_mode) instead of a canopy-wide box.
static func _is_tree_like(asset: String) -> bool:
	var s := asset.to_lower()
	return "tree" in s or "trunk" in s or "log" in s or "stump" in s or "palm" in s


# ---------------- shared flat nav ----------------

# Rebuild ONE flat NavigationRegion3D spanning the current resident footprint (+1 cell margin).
# Flat plane -> trivial mesh, NO per-cell collider parse/bake (the main-thread stall). enemy.gd
# direct-chases when no path is available, so this is best-effort encircle quality, not required.
func _rebuild_shared_nav() -> void:
	if _nav_root == null:
		return
	if _nav_region != null and is_instance_valid(_nav_region):
		_nav_region.queue_free()
		_nav_region = null

	# bounding box of resident cells (fall back to the start cell so there's always a region)
	var min_gx: int = start_cell.x
	var max_gx: int = start_cell.x
	var min_gz: int = start_cell.y
	var max_gz: int = start_cell.y
	for k: String in resident.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var cgx := int(parts[0])
		var cgz := int(parts[1])
		min_gx = mini(min_gx, cgx)
		max_gx = maxi(max_gx, cgx)
		min_gz = mini(min_gz, cgz)
		max_gz = maxi(max_gz, cgz)

	var pad := 1.0
	var x0 := float(min_gx) * cell_size - pad
	var x1 := float(max_gx + 1) * cell_size + pad
	var z0 := float(min_gz) * cell_size - pad
	var z1 := float(max_gz + 1) * cell_size + pad

	var nav := NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.7
	# author a single flat quad at y=0 by hand -> NO geometry parse, NO bake stall
	var verts := PackedVector3Array([
		Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z0),
		Vector3(x1, 0.0, z1), Vector3(x0, 0.0, z1),
	])
	nm.set_vertices(verts)
	nm.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav.navigation_mesh = nm
	_nav_root.add_child(nav)
	_nav_region = nav


# ---------------- enemy union upkeep ----------------

func _prune_enemies() -> void:
	# drop freed/dead-and-collected enemies so the union list (read by main._attack/_refresh_stats)
	# doesn't accumulate stale refs as cells evict / enemies die.
	var live: Array = []
	for e in enemies:
		if is_instance_valid(e):
			live.append(e)
	enemies = live


# ---------------- helpers ----------------

func _key(gx: int, gz: int) -> String:
	return str(gx) + "," + str(gz)


# parse a "gx,gz" cell key back to its cell coordinate
func _key_cell(k: String) -> Vector2i:
	var parts := k.split(",")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


# Area id for a cell — MUST match the reassembler's idFor(gx,gz) ("c<gx>_<gz>") so quest
# reach_area targets and the qgcheck goal cell agree with what area_entered reports.
func _area_id(c: Vector2i) -> String:
	return "c" + str(c.x) + "_" + str(c.y)


func _player_cell() -> Vector2i:
	var p := player.global_position
	return Vector2i(floori(p.x / cell_size), floori(p.z / cell_size))


func _cell_centre(gx: int, gz: int) -> Vector3:
	return Vector3(float(gx) * cell_size + cell_size * 0.5, 0.0, float(gz) * cell_size + cell_size * 0.5)


# Rebuild + recentre the far-horizon terrain skirt on the player (only when they've moved ~1.5 cells, so it's
# cheap). terrain worlds only — gives a landscape stretching to the fog-faded horizon past the detailed ring.
# Returns true if it rebuilt this call (so tick can stagger it against the water re-mesh — Wave 4).
func _update_far(pc: Vector3) -> bool:
	if terrain == null or _nav_root == null:
		return false
	# Wave 4: recentre gate widened 1.5 -> 2.0 cells (fewer full 224m-radius rebuilds; the skirt
	# radius has huge margin over a 2-cell step, so no horizon edge ever shows).
	if Vector2(pc.x, pc.z).distance_to(_far_centre) < cell_size * (2.0 + 2.0 * clampf(_stream_speed, 0.0, 2.0)):   # widen the re-mesh gate for a fast mover -> fewer 224m skirt rebuilds while flying
		return false
	_far_centre = Vector2(pc.x, pc.z)
	if _threaded_shapes:
		# NATIVE: 360ms of measured frame spike lives in this rebuild. Build the mesh on a worker and
		# swap it in from _drain_meshes(); the OLD skirt stays visible until the new one is ready, so
		# there is no horizon gap. Returning true still claims this cell-cross's re-mesh slot, which
		# keeps the existing "never far AND water on the same crossing" stagger intact.
		if not _far_building:
			_far_building = true
			_mesh_tasks[WorkerThreadPool.add_task(
				_far_worker.bind(Vector3(pc.x, 0.0, pc.z)), false, "gogi_far")] = true
		return true
	if _far != null and is_instance_valid(_far):
		_far.queue_free()
	_far = terrain.far_skirt(Vector3(pc.x, 0.0, pc.z), cell_size * 14.0, 44)
	_nav_root.add_child(_far)
	return true


# Rebuild + recentre the water body on the player (terrain/depth under it changes as they move). Like the far
# skirt: only when they've moved ~1.5 cells, so it's cheap.
func _update_water(pc: Vector3) -> bool:
	if water_cfg == null or _nav_root == null:
		return false
	if Vector2(pc.x, pc.z).distance_to(_water_centre) < cell_size * (2.0 + 2.0 * clampf(_stream_speed, 0.0, 2.0)):   # 2.0 + speed-widened -> fewer 224m water rebuilds while flying
		return false
	_water_centre = Vector2(pc.x, pc.z)
	if _threaded_shapes:
		if not _water_building:
			_water_building = true
			_mesh_tasks[WorkerThreadPool.add_task(
				_water_worker.bind(Vector3(pc.x, 0.0, pc.z)), false, "gogi_water")] = true
		return true
	if _water != null and is_instance_valid(_water):
		_water.queue_free()
	_water = GWater.body(Vector3(pc.x, 0.0, pc.z), cell_size * 14.0, water_level, terrain, 48, water_cfg)
	_nav_root.add_child(_water)
	return true


# Wave 4 P6 — the distant SKYLINE. Cells in the Chebyshev band (FAR_RADIUS, SKYLINE_RADIUS] around the
# player contribute ONLY their structures, merged into ONE material-less silhouette mesh (no ground,
# roads, props, colliders, or lights). Reads the authored `grid` dict directly (those cells are neither
# resident nor proxied), so a whole city's far towers show for ~1 draw call. Rebuilt when the player
# has crossed ~2 cells; a world with nothing out there produces no mesh. Parented to _nav_root, so it
# shares the far skirt / water lifecycle (freed with the streamer on reload).
func _update_skyline(pcell: Vector2i) -> void:
	if _nav_root == null:
		return
	if _skyline != null and maxi(absi(pcell.x - _skyline_cell.x), absi(pcell.y - _skyline_cell.y)) < (2 + int(round(clampf(_stream_speed, 0.0, 3.0)))):
		return
	_skyline_cell = pcell
	if _skyline != null and is_instance_valid(_skyline):
		_skyline.queue_free()
		_skyline = null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := cell_size * 0.5
	var any := false
	for k in grid:
		var gc := _key_cell(k)
		var cheb := maxi(absi(gc.x - pcell.x), absi(gc.y - pcell.y))
		if cheb <= FAR_RADIUS or cheb > SKYLINE_RADIUS:
			continue   # only the band BEYOND the proxy ring, out to the skyline radius
		var structs = grid[k].get("structures", [])
		if not (structs is Array):
			continue
		var ccx := float(gc.x) * cell_size + half
		var ccz := float(gc.y) * cell_size + half
		for s in structs:
			if typeof(s) != TYPE_DICTIONARY:
				continue
			var foot := _xz(s.get("footprint", [8, 8]))
			var floors := maxi(1, int(s.get("floors", 1)))
			var h := float(s.get("height", float(floors) * float(s.get("floor_height", 3.2))))
			var sc := maxf(0.1, float(s.get("scale", 1.0)))
			var sp := _xz(s.get("pos", [0, 0]))
			var bx := ccx + clampf(sp.x, -half + 0.5, half - 0.5)
			var bz := ccz + clampf(sp.y, -half + 0.5, half - 0.5)
			var by := _ground_y(bx, bz)
			_st_box(st, Vector3(bx, by + h * sc * 0.5, bz), Vector3(foot.x * sc, h * sc, foot.y * sc))
			any = true
		# VOLCANO landmarks -> a distant dark cone on the horizon so the player can navigate toward them.
		var lava_sky = grid[k].get("lava", [])
		if lava_sky is Array:
			for lv in lava_sky:
				if typeof(lv) != TYPE_DICTIONARY:
					continue
				var lr := clampf(float(lv.get("radius", 6.0)), 1.5, half * 1.6)
				var lxz := _xz(lv.get("pos", [0, 0]))
				var lx := ccx + clampf(lxz.x, -half + 0.5, half - 0.5)
				var lz := ccz + clampf(lxz.y, -half + 0.5, half - 0.5)
				_st_cone(st, Vector3(lx, _ground_y(lx, lz), lz), lr * 1.5, clampf(lr * 1.15, 3.0, 26.0))
				any = true
	if not any:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _skyline_mat()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_nav_root.add_child(mi)
	_skyline = mi


# Append a box (12 tris) to a SurfaceTool, centred at `c` with full-extent `s`. The skyline material is
# UNSHADED + cull-disabled, so winding/normals don't matter — positions only.
func _st_box(st: SurfaceTool, c: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var v := [
		c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z),
		c + Vector3(h.x, -h.y, h.z), c + Vector3(-h.x, -h.y, h.z),
		c + Vector3(-h.x, h.y, -h.z), c + Vector3(h.x, h.y, -h.z),
		c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z)]
	for tri in [[0,1,2],[0,2,3],[4,6,5],[4,7,6],[0,4,5],[0,5,1],[1,5,6],[1,6,2],[2,6,7],[2,7,3],[3,7,4],[3,4,0]]:
		for idx in tri:
			st.set_normal(Vector3.UP)
			st.add_vertex(v[idx])


# Append a CONE (base ring -> apex) to a SurfaceTool for the skyline silhouette — a distant volcano/peak.
func _st_cone(st: SurfaceTool, base: Vector3, radius: float, height: float) -> void:
	var segs := 10
	var apex := base + Vector3(0.0, height, 0.0)
	for i in range(segs):
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		var v0 := base + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var v1 := base + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		for vtx in [apex, v0, v1]:
			st.set_normal(Vector3.UP)
			st.add_vertex(vtx)


# Flat, dark, hazy silhouette material for the distant skyline — reads as fogged far buildings, never
# a lit detailed block. Unshaded (no per-vertex light cost) + cull-disabled (winding-agnostic).
func _skyline_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.18, 0.20, 0.26)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# Surface height at a WORLD (x,z) — the terrain heightfield when terrain is on, else 0 (flat). Every placed
# object adds this to its y so it sits ON the ground; the heightfield is the single source of truth shared with
# the terrain mesh, so a prop and the ground beneath it always agree.
func _ground_y(wx: float, wz: float) -> float:
	return terrain.height(wx, wz) if terrain != null else 0.0


func _cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _evict_farthest() -> void:
	var worst_key := ""
	var worst_d := -1
	for k: String in resident.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var d := _cheb(Vector2i(int(parts[0]), int(parts[1])), _cur_cell)
		if d > worst_d:
			worst_d = d
			worst_key = k
	if worst_key != "":
		_evict(worst_key)


# Min/max GRID INDICES of all authored cells, as (min_gx, min_gz, max_gx, max_gz). Shared by both
# world-rect helpers below so they can never drift apart about which cells exist. A grid with no
# cells returns min > max; both callers check for it.
func _grid_index_bounds() -> Vector4i:
	var min_gx := 2147483647
	var max_gx := -2147483648
	var min_gz := 2147483647
	var max_gz := -2147483648
	for k: String in grid.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var gx := int(parts[0])
		var gz := int(parts[1])
		min_gx = mini(min_gx, gx)
		max_gx = maxi(max_gx, gx)
		min_gz = mini(min_gz, gz)
		max_gz = maxi(max_gz, gz)
	return Vector4i(min_gx, min_gz, max_gx, max_gz)


# CENTRE-to-CENTRE bounds of the edge cells — for main.gd's auto-roam, which steers the player toward
# a point on this rect. Centres are the RIGHT answer there: a target on the true outer edge would aim
# the walk straight into the border wall and stall against it.
#
# NOT for containment. See grid_bounds_rect() below.
func grid_world_rect() -> Rect2:
	var b := _grid_index_bounds()
	if b.x > b.z:
		return Rect2(cell_size * 0.5, cell_size * 0.5, cell_size, cell_size)
	var x0 := float(b.x) * cell_size + cell_size * 0.5
	var z0 := float(b.y) * cell_size + cell_size * 0.5
	var w := float(b.z - b.x) * cell_size
	var h := float(b.w - b.y) * cell_size
	return Rect2(x0, z0, w, h)


# TRUE OUTER EDGES of the authored grid — where _terrain_border_walls actually stand. This is what
# player/vehicle containment must use.
#
# WHY THIS EXISTS AS A SEPARATE FUNCTION: main.gd's clamp used grid_world_rect() — a function whose
# own doc comment says it is for auto-roam — and centre bounds silently throw away HALF A CELL on all
# four sides. A 3x3 grid at cell_size 16 is authored over (0..48) and its border walls stand at 0 and
# 48, but the centre rect is (8..40): the player was fenced 8m short of a wall they could see, and
# 56% of the arena was visible, decorated, collidable and unreachable. It shipped, and the report
# that came back was "the world was small".
#
# A function can be correct for the job it was written for and wrong for the next one. The fix is a
# second function with its own name, not a tweak to the first — auto-roam still wants centres.
#
# Cell (gx,gz) spans [gx*cell_size, (gx+1)*cell_size], so the outer edges are min*cs and (max+1)*cs.
func grid_bounds_rect() -> Rect2:
	var b := _grid_index_bounds()
	if b.x > b.z:
		return Rect2(0.0, 0.0, cell_size, cell_size)
	return Rect2(float(b.x) * cell_size, float(b.y) * cell_size,
		float(b.z - b.x + 1) * cell_size, float(b.w - b.y + 1) * cell_size)


# ══════════════════════ ISLAND SET-PIECE EXTRAS (data-driven, resident-ring only) ══════════════════════
# Cell keys (all optional):
#   "lava":      [{"pos":[x,z], "radius": 6}]                          glowing lava pool + embers + light
#   "waterfall": [{"pos":[x,z], "height": 12, "width": 5, "facing": 0}] scrolling falls + splash at the base
#   "bridge":    {"from":[x,z], "to":[x,z]}                            walkable rope-and-log bridge (planks + ropes)
#   "particles": "fireflies" | "embers" | "mist" | "ash"               an ambient mood volume over the cell

var _extra_light_n := 0   # dynamic-light budget across the resident ring (mobile: point lights are the expensive thing)

func _place_extras(root: Node3D, rec: Dictionary, centre: Vector3, half: float) -> void:
	var lava_list = rec.get("lava", [])
	if lava_list is Array:
		for l0 in lava_list:
			if typeof(l0) == TYPE_DICTIONARY:
				_place_lava(root, l0 as Dictionary, centre, half)
	var wf_list = rec.get("waterfall", [])
	if wf_list is Array:
		for w0 in wf_list:
			if typeof(w0) == TYPE_DICTIONARY:
				_place_waterfall(root, w0 as Dictionary, centre, half)
	# bridge deck now built BEFORE the scenery await in build_cell (load-bearing walkable surface) — not here
	var mood := String(rec.get("particles", ""))
	if mood != "":
		_place_mood(root, mood, centre, half)


static var _noise_tex: NoiseTexture2D = null

static func _shared_noise() -> NoiseTexture2D:
	if _noise_tex == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n.frequency = 0.06
		_noise_tex = NoiseTexture2D.new()
		_noise_tex.width = 128
		_noise_tex.height = 128
		_noise_tex.seamless = true
		_noise_tex.noise = n
	return _noise_tex


func _place_lava(root: Node3D, spec: Dictionary, centre: Vector3, half: float) -> void:
	var p := _xz(spec.get("pos", [0, 0]))
	var r := clampf(float(spec.get("radius", 6.0)), 1.5, half * 1.6)
	var pos := centre + Vector3(clampf(p.x, -half * 1.5, half * 1.5), 0.0, clampf(p.y, -half * 1.5, half * 1.5))
	var gy := _ground_y(pos.x, pos.z)
	pos.y = gy
	# VOLCANO: a dark basalt CONE rising from the ground with the molten pool in its crater — so lava reads
	# as a volcano even on flat terrain (authored lava rarely lands on an actual terrain peak). Cone size
	# scales with the pool radius r. A bare flat disc on flat ground was the "doesn't look like a volcano".
	var cone_h := clampf(r * 1.15, 3.0, 26.0)
	var base_r := r * 1.75
	var rim_r := r * 1.12                    # crater rim; lava sits just inside it
	var rock := GSurf.surface({"color": [0.13, 0.10, 0.09], "rough": 1.0})
	var cone := MeshInstance3D.new()
	var cmz := CylinderMesh.new()
	cmz.bottom_radius = base_r
	cmz.top_radius = rim_r
	cmz.height = cone_h
	cmz.radial_segments = 24
	cone.mesh = cmz
	cone.material_override = rock
	root.add_child(cone)
	cone.global_position = Vector3(pos.x, gy + cone_h * 0.5 - 0.3, pos.z)   # base sunk slightly into the ground
	# solid collider (cylinder ~ the cone) so the player can't walk through the mountain
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = base_r * 0.9
	cyl.height = cone_h
	col.shape = cyl
	body.add_child(col)
	root.add_child(body)
	body.global_position = cone.global_position
	# crater LAVA — ONE boiling molten mass heaped in the MIDDLE of the crater (a single flattened dome, so
	# there's no separate disc/ring reading as an extra lava part). Uses the boiling lava shader.
	var crater_y := gy + cone_h - 0.7
	var sh := load("res://lava.gdshader")
	var dome := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = rim_r * 0.9
	sph.height = rim_r * 1.8
	dome.mesh = sph
	if sh != null:
		var lmat := ShaderMaterial.new()
		lmat.shader = sh
		lmat.set_shader_parameter("noise_tex", _shared_noise())
		dome.material_override = lmat
	root.add_child(dome)
	dome.global_position = Vector3(pos.x, crater_y, pos.z)
	dome.scale = Vector3(1.0, 0.3, 1.0)   # flattened molten mound filling the crater, bulging up in the middle
	# embers spitting up from the crater
	var p3 := CPUParticles3D.new()
	p3.amount = 30
	p3.lifetime = 3.0
	p3.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p3.emission_sphere_radius = rim_r * 0.7
	p3.direction = Vector3(0, 1, 0)
	p3.spread = 16.0
	p3.gravity = Vector3(0, 1.0, 0)
	p3.initial_velocity_min = 1.0
	p3.initial_velocity_max = 2.6
	p3.scale_amount_min = 0.06
	p3.scale_amount_max = 0.16
	p3.color = Color(1.0, 0.55, 0.15)
	root.add_child(p3)
	p3.global_position = Vector3(pos.x, crater_y + 0.5, pos.z)
	# a dark smoke/ash plume above the crater
	var smoke := CPUParticles3D.new()
	smoke.amount = 16
	smoke.lifetime = 4.5
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = rim_r * 0.5
	smoke.direction = Vector3(0, 1, 0)
	smoke.spread = 22.0
	smoke.gravity = Vector3(0, 1.5, 0)
	smoke.initial_velocity_min = 1.4
	smoke.initial_velocity_max = 3.0
	smoke.scale_amount_min = 0.8
	smoke.scale_amount_max = 2.4
	smoke.color = Color(0.14, 0.12, 0.11)
	root.add_child(smoke)
	smoke.global_position = Vector3(pos.x, crater_y + 1.6, pos.z)
	# warm glow from the crater, budgeted across the ring
	if _extra_light_n < 6:
		_extra_light_n += 1
		var li := OmniLight3D.new()
		li.light_color = Color(1.0, 0.45, 0.12)
		li.light_energy = 3.0
		li.omni_range = maxf(10.0, r * 2.4)
		li.shadow_enabled = false
		li.tree_exited.connect(func() -> void: _extra_light_n = maxi(0, _extra_light_n - 1))
		root.add_child(li)
		li.global_position = Vector3(pos.x, crater_y + 1.2, pos.z)


func _place_waterfall(root: Node3D, spec: Dictionary, centre: Vector3, half: float) -> void:
	var p := _xz(spec.get("pos", [0, 0]))
	var h := clampf(float(spec.get("height", 10.0)), 3.0, 40.0)
	var w := clampf(float(spec.get("width", 5.0)), 1.5, 18.0)
	var facing := deg_to_rad(float(spec.get("facing", 0.0)))
	var pos := centre + Vector3(clampf(p.x, -half * 1.5, half * 1.5), 0.0, clampf(p.y, -half * 1.5, half * 1.5))
	var base_y := _ground_y(pos.x, pos.z)
	var fwd := Vector3(sin(facing), 0.0, cos(facing))     # direction the falls FACE (out from the cliff)
	var side := Vector3(cos(facing), 0.0, -sin(facing))   # along the cliff face
	var rock := GSurf.surface({"color": [0.20, 0.18, 0.17], "rough": 1.0})
	var rock2 := GSurf.surface({"color": [0.16, 0.15, 0.14], "rough": 1.0})
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(pos.x) * 131.0 + absf(pos.z) * 71.0) + 7
	# NATURAL ROCK CLIFF: a rough outcrop of TILTED rock slabs + boulders (not a clean block) the water pours
	# down. A hidden solid backing slab occludes + carries the collider; the visible chunks are all irregular.
	var cdep := 3.0
	var back := StaticBody3D.new()
	back.collision_layer = 1
	var bcs := CollisionShape3D.new()
	var bbx := BoxShape3D.new()
	bbx.size = Vector3(w + 2.5, h + 3.0, cdep)
	bcs.shape = bbx
	back.add_child(bcs)
	root.add_child(back)
	back.global_position = Vector3(pos.x, base_y + (h + 3.0) * 0.5, pos.z) - fwd * (cdep * 0.75)
	back.rotation.y = facing
	# a matching hidden backing MESH (dark) so you never see through the gaps between the loose chunks
	var backm := MeshInstance3D.new()
	var bm2 := BoxMesh.new()
	bm2.size = bbx.size
	backm.mesh = bm2
	backm.material_override = rock2
	root.add_child(backm)
	backm.global_position = back.global_position
	backm.rotation.y = facing
	# irregular rock chunks stacked over the face to break the block silhouette
	for i in range(8):
		var chunk := MeshInstance3D.new()
		if rng.randf() < 0.35:
			var s := SphereMesh.new()
			var rr := rng.randf_range(w * 0.22, w * 0.45)
			s.radius = rr
			s.height = rr * rng.randf_range(1.4, 2.4)
			chunk.mesh = s
		else:
			var b := BoxMesh.new()
			b.size = Vector3(rng.randf_range(w * 0.35, w * 0.8), rng.randf_range(h * 0.25, h * 0.55), rng.randf_range(1.4, 2.6))
			chunk.mesh = b
		chunk.material_override = rock if (i % 2 == 0) else rock2
		root.add_child(chunk)
		var lat := rng.randf_range(-w * 0.55, w * 0.55)
		var vert := rng.randf_range(0.2, h + 1.0)
		chunk.global_position = Vector3(pos.x, base_y + vert, pos.z) - fwd * (cdep * 0.35 + rng.randf_range(0.0, 0.5)) + side * lat
		chunk.rotation = Vector3(rng.randf_range(-0.18, 0.18), facing + rng.randf_range(-0.4, 0.4), rng.randf_range(-0.18, 0.18))
	# TOP LIP: a couple of jutting rocks at the crest where the water spills over (a visible source)
	for lsign in [-0.5, 0.5]:
		var lip := MeshInstance3D.new()
		var lb := BoxMesh.new()
		lb.size = Vector3(rng.randf_range(w * 0.4, w * 0.7), 0.7, rng.randf_range(1.4, 2.2))
		lip.mesh = lb
		lip.material_override = rock
		root.add_child(lip)
		lip.global_position = Vector3(pos.x, base_y + h + rng.randf_range(0.0, 0.4), pos.z) + fwd * rng.randf_range(0.2, 0.5) + side * (lsign * w * 0.4)
		lip.rotation = Vector3(rng.randf_range(-0.1, 0.1), facing + rng.randf_range(-0.2, 0.2), 0.0)
	# WATER SHEET: FLUSH on the cliff face, from just under the lip down into the pool.
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	quad.mesh = qm
	var sh := load("res://waterfall.gdshader")
	if sh != null:
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("noise_tex", _shared_noise())
		quad.material_override = m
	root.add_child(quad)
	quad.global_position = Vector3(pos.x, base_y + h * 0.5, pos.z) + fwd * 0.5   # clearly in FRONT of the loose chunks
	quad.rotation.y = facing
	# PLUNGE POOL: a shallow translucent water disc where the falls land
	var pool := MeshInstance3D.new()
	var pcm := CylinderMesh.new()
	pcm.top_radius = w * 0.75
	pcm.bottom_radius = w * 0.75
	pcm.height = 0.12
	pool.mesh = pcm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.5, 0.72, 0.82, 0.6)
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.roughness = 0.12
	pmat.metallic = 0.2
	pool.material_override = pmat
	root.add_child(pool)
	pool.global_position = Vector3(pos.x, base_y + 0.06, pos.z) + fwd * (w * 0.25)
	# a couple of wet boulders framing the plunge, grounding the falls in the scene
	for bsign in [-1.0, 1.0]:
		var boul := MeshInstance3D.new()
		var bsph := SphereMesh.new()
		var br := w * 0.3
		bsph.radius = br
		bsph.height = br * 1.5
		boul.mesh = bsph
		boul.material_override = rock
		root.add_child(boul)
		boul.global_position = Vector3(pos.x, base_y + br * 0.25, pos.z) + fwd * (w * 0.15) + side * (bsign * w * 0.6)
		boul.scale = Vector3(1.0, 0.7, 1.0)
	# splash foam where the water hits the pool
	var p3 := CPUParticles3D.new()
	p3.amount = 34
	p3.lifetime = 0.9
	p3.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p3.emission_box_extents = Vector3(w * 0.5, 0.2, 0.7)
	p3.direction = Vector3(0, 1, 0)
	p3.spread = 55.0
	p3.gravity = Vector3(0, -7.0, 0)
	p3.initial_velocity_min = 1.5
	p3.initial_velocity_max = 3.5
	p3.scale_amount_min = 0.08
	p3.scale_amount_max = 0.3
	p3.color = Color(0.9, 0.96, 1.0)
	root.add_child(p3)
	p3.global_position = Vector3(pos.x, base_y + 0.3, pos.z) + fwd * (w * 0.2)
	if ResourceLoader.exists("res://audio/waterfall.wav"):
		AudioManager.attach_loop(quad, load("res://audio/waterfall.wav"), -6.0, 30.0, 7.0)


# March a bridge endpoint OUTWARD along `outward` (~1m steps, up to 8m) until the ground stops rising
# (the local crest = a walkable rim), so a deck end lands on the rim instead of partway down a steep
# gorge wall (which would strand the player at the foot of an unclimbable wall after crossing).
func _rim_anchor(p: Vector3, outward: Vector2) -> Vector3:
	var best := Vector3(p.x, _ground_y(p.x, p.z), p.z)
	var cx := p.x
	var cz := p.z
	for s in range(1, 9):
		cx += outward.x
		cz += outward.y
		var gy := _ground_y(cx, cz)
		if gy + 0.05 < best.y:
			break
		best = Vector3(cx, gy, cz)
	return best


# Build a bridge ONCE per authoring cell and keep it in _bridges, parented to the PERSISTENT world root
# (not the cell that authored it — that cell evicts while the player is still mid-span). Re-entry of the
# cell is a no-op; the free-when-far pass in _update_ring reclaims it.
func _ensure_bridge(k: String, spec: Dictionary, centre: Vector3, half: float) -> void:
	if _bridges.has(k) and is_instance_valid(_bridges[k]):
		return
	var rig := _place_bridge(world_main, spec, centre, half)
	if rig != null:
		rig.reset_physics_interpolation()   # pin the deck so it doesn't render a smear from origin when it first appears
		_bridges[k] = rig


func _place_bridge(root: Node, spec: Dictionary, centre: Vector3, half: float) -> Node3D:
	var a2 := _xz(spec.get("from", [0, 0]))
	var b2 := _xz(spec.get("to", [0, 0]))
	var a := centre + Vector3(clampf(a2.x, -half * 2.0, half * 2.0), 0.0, clampf(a2.y, -half * 2.0, half * 2.0))
	var b := centre + Vector3(clampf(b2.x, -half * 2.0, half * 2.0), 0.0, clampf(b2.y, -half * 2.0, half * 2.0))
	a.y = _ground_y(a.x, a.z)
	b.y = _ground_y(b.x, b.z)
	# RIM-ANCHOR each end so the deck flies rim-to-rim OVER the walls onto flat ground (an authored
	# endpoint often lands partway down a steep gorge wall; without this the crosser is dumped at the
	# foot of an unclimbable >55deg wall and trapped).
	var ax := Vector2(b.x - a.x, b.z - a.z)
	if ax.length() > 0.01:
		ax = ax.normalized()
		a = _rim_anchor(a, Vector2(-ax.x, -ax.y))
		b = _rim_anchor(b, ax)
	var span := Vector2(b.x - a.x, b.z - a.z).length()
	if span < 2.0:
		return null
	var yaw := atan2(b.x - a.x, b.z - a.z)
	var n := maxi(6, int(span / 1.1))
	var wood := GSurf.surface("timber")
	var rope_m := GSurf.surface({"color": [0.45, 0.36, 0.22], "rough": 1.0})
	var rig := Node3D.new()
	root.add_child(rig)
	rig.global_position = Vector3((a.x + b.x) * 0.5, 0.0, (a.z + b.z) * 0.5)
	rig.rotation.y = yaw
	var ya := a.y   # FLUSH with the rim (no proud lip -> no step to board from either end)
	var yb := b.y
	var pitch := atan2(yb - ya, span)
	# TERRAIN-CLAMPED per-segment causeway: each plank sits at the HIGHER of the pitched rim-to-rim line
	# (arches over the chasm) and the local terrain + 0.35 clearance — so near the rims it never buries
	# under a convex lip, is always above the ground-stick threshold (+0.1) so the player is never yanked
	# off/under it, and 0.35m is a trivial <=STEP_MAX step on/off. Each segment gets its OWN short collider
	# box overlapping its neighbour (no gaps), so the deck is walkable end-to-end.
	var seg_len := span / float(n)
	for i in range(n):
		var t := (float(i) + 0.5) / float(n)
		var wx := lerpf(a.x, b.x, t)
		var wz := lerpf(a.z, b.z, t)
		# FLUSH at the rims (clearance tapers to 0 at both ends -> board with no step), arching to +0.35
		# over the chasm so the deck clears the terrain in the middle.
		var top := maxf(lerpf(ya, yb, t), _ground_y(wx, wz) + 0.35 * sin(t * PI))
		var lz := -span * 0.5 + t * span
		var plank := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.2, 0.14, seg_len * 0.86)
		plank.mesh = bm
		plank.material_override = wood
		rig.add_child(plank)
		plank.position = Vector3(0.0, top, lz)
		plank.rotation.y = randf_range(-0.05, 0.05)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bx := BoxShape3D.new()
		bx.size = Vector3(2.2, 0.3, seg_len + 0.2)   # overlaps its neighbour ~0.2m -> no gap
		cs.shape = bx
		body.add_child(cs)
		rig.add_child(body)
		body.position = Vector3(0.0, top - 0.15, lz)
	# rail COLLIDERS: sidling along the deck must never drop the player into the gorge — the rope
	# visuals below are walk-through, so each side gets a thin invisible barrier the full span.
	for side in [-1.0, 1.0]:
		var rail := StaticBody3D.new()
		rail.collision_layer = 1
		var rcs := CollisionShape3D.new()
		var rbx := BoxShape3D.new()
		rbx.size = Vector3(0.14, 1.3, span / cos(pitch) + 0.6)
		rcs.shape = rbx
		rail.add_child(rcs)
		rig.add_child(rail)
		rail.position = Vector3(side * 1.18, (ya + yb) * 0.5 + 0.55, 0.0)
		rail.rotation.x = -pitch
	# rope handrails: segmented thin cylinders following the sag, plus end posts
	for side in [-1.0, 1.0]:
		var segs := 8
		for i in range(segs):
			var t0 := float(i) / float(segs)
			var t1 := float(i + 1) / float(segs)
			var p0 := Vector3(side * 1.05, lerpf(ya, yb, t0) + 1.0 + sin(t0 * PI) * -0.4, -span * 0.5 + t0 * span)
			var p1 := Vector3(side * 1.05, lerpf(ya, yb, t1) + 1.0 + sin(t1 * PI) * -0.4, -span * 0.5 + t1 * span)
			var seg := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.035
			cyl.bottom_radius = 0.035
			cyl.height = p0.distance_to(p1)
			seg.mesh = cyl
			seg.material_override = rope_m
			rig.add_child(seg)
			seg.position = (p0 + p1) * 0.5
			# align the cylinder's +Y long axis to the rig-LOCAL segment direction (no global math)
			var dirv := (p1 - p0).normalized()
			var axis := Vector3.UP.cross(dirv)
			if axis.length() > 0.001:
				seg.basis = Basis(axis.normalized(), Vector3.UP.angle_to(dirv))
		for e in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			var pc := CylinderMesh.new()
			pc.top_radius = 0.09
			pc.bottom_radius = 0.11
			pc.height = 1.4
			post.mesh = pc
			post.material_override = wood
			rig.add_child(post)
			post.position = Vector3(side * 1.05, (ya if e < 0.0 else yb) + 0.7, e * (span * 0.5 - 0.2))
	return rig


func _place_mood(root: Node3D, mood: String, centre: Vector3, half: float) -> void:
	var p3 := CPUParticles3D.new()
	p3.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p3.emission_box_extents = Vector3(half * 0.9, 2.5, half * 0.9)
	var gy := _ground_y(centre.x, centre.z)
	match mood:
		"fireflies":
			p3.amount = 24
			p3.lifetime = 4.0
			p3.gravity = Vector3.ZERO
			p3.initial_velocity_min = 0.2
			p3.initial_velocity_max = 0.6
			p3.scale_amount_min = 0.04
			p3.scale_amount_max = 0.09
			p3.color = Color(1.0, 0.95, 0.45)
			p3.position = Vector3(0, 1.6, 0)
		"embers", "ash":
			p3.amount = 12 if _on_web else 30   # small quads, but 124 authored cells carry them — see the mist note
			p3.lifetime = 3.5
			p3.gravity = Vector3(0.4, 0.5, 0.2)
			p3.initial_velocity_min = 0.4
			p3.initial_velocity_max = 1.2
			p3.scale_amount_min = 0.04
			p3.scale_amount_max = 0.1
			p3.color = Color(1.0, 0.5, 0.15) if mood == "embers" else Color(0.55, 0.53, 0.5)
			p3.position = Vector3(0, 4.0, 0)
		"mist":
			# FILL-RATE, not geometry. Mist was 14 quads per cell at 2.2-4.5 METRES each — a single one
			# of those near the camera covers most of the screen, and with ~9 resident cells they stack
			# into a hundred-plus layers of alpha the GPU must blend every frame. Measured on a real
			# device in the volcano region: 180k triangles, 409 draws, 7ms script — everything CHEAP —
			# and still 133ms frames (8fps). Particles are 2 triangles each, so they are invisible to
			# the triangle counter while dominating the frame. Smaller quads, fewer of them, and a
			# lower alpha keep the look (a haze in the air) at a fraction of the overdraw.
			p3.amount = 6 if _on_web else 14
			p3.lifetime = 6.0
			p3.gravity = Vector3(0.3, 0.02, 0.1)
			p3.initial_velocity_min = 0.1
			p3.initial_velocity_max = 0.4
			p3.scale_amount_min = 1.0 if _on_web else 2.2
			p3.scale_amount_max = 1.8 if _on_web else 4.5
			p3.color = Color(0.85, 0.9, 0.92, 0.045 if _on_web else 0.06)
			p3.position = Vector3(0, 1.2, 0)
		_:
			p3.queue_free()
			return
	root.add_child(p3)
	p3.global_position = Vector3(centre.x, gy, centre.z) + p3.position
