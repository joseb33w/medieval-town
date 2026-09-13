extends Node
## SAVE — the engine's persistence layer. One interface, two backends.
##
## WHY IT DID NOT EXIST BEFORE
## Until now the engine wrote exactly ONE file: the auth refresh token. No score survived a quit, no
## inventory, no progress, nothing. Every game was amnesiac by construction. That was invisible while
## games were single-session demos and became load-bearing the moment vars could be marked `persist`
## and players could BUILD things they expect to find tomorrow.
##
## TWO BACKENDS, CHOSEN BY THE GAME — and the choice follows a rule the user set, not a preference:
##   local  ->  user://gogi_save_<game>.json     solo games. NO account, no network, works on a plane.
##   cloud  ->  Supabase `gogi_saves`            multiplayer / cross-device. Needs sign-in, which a
##                                               multiplayer game already required anyway.
## Never gate a solo game behind a login just to remember a high score. That is the whole reason
## there are two backends instead of one.
##
## WRITES ARE DEBOUNCED. A building game places a block every half second; a var ticks every frame.
## Writing through on each change would hammer local storage and, on cloud, turn a placement into a
## network round trip. Callers `put()` freely and the flush happens on a timer or at a checkpoint.

const LOCAL_PREFIX := "user://gogi_save_"
const FLUSH_EVERY := 4.0        # seconds between automatic flushes when dirty
const TABLE := "gogi_saves"     # engine-owned, shared by every game — the ENGINE cannot run
                                # migrations (it ships inside the app), so it can never assume a
                                # per-game table exists. One table, keyed by (user, game).

var backend := "local"          # "local" | "cloud" | "off"
var game_id := ""
var loaded := false              # true once load_state() has completed at least once

var _state: Dictionary = {}
var _dirty := false
var _t := 0.0
var _in_flight := false


func configure(p_game_id: String, p_backend: String) -> void:
	game_id = p_game_id if p_game_id != "" else "default"
	backend = p_backend
	# Cloud without a signed-in user is not an error worth failing a game over — it means the world
	# asked for cloud saves and the player is not signed in yet. Degrade to local so progress is
	# still kept, and say so once rather than silently changing behavior.
	if backend == "cloud" and not (Auth != null and Auth.is_signed_in()):
		push_warning("[Save] cloud backend requested but no session — falling back to local")
		print("GOGI_SAVE fallback=local reason=no-session")
		backend = "local"
	print("GOGI_SAVE backend=%s game=%s" % [backend, game_id])


# ---------------- read ----------------

func load_state() -> Dictionary:
	if backend == "off":
		loaded = true
		return {}
	if backend == "cloud":
		_state = await _cloud_load()
	else:
		_state = _local_load()
	loaded = true
	print("GOGI_SAVE loaded keys=%d" % _state.size())
	return _state


func get_value(key: String, fallback = null):
	return _state.get(key, fallback)


func has(key: String) -> bool:
	return _state.has(key)


# ---------------- write ----------------

func put(key: String, value) -> void:
	if backend == "off":
		return
	if _state.get(key, null) == value:
		return                       # unchanged -> not dirty. Keeps a ticking var from flushing forever.
	_state[key] = value
	_dirty = true


## Force a write now — call at a real checkpoint (quest complete, build placed, app backgrounding),
## not on a loop. Returns immediately; the write itself is fire-and-forget on cloud.
func flush() -> void:
	if not _dirty or backend == "off":
		return
	_dirty = false
	if backend == "cloud":
		_cloud_save()
	else:
		_local_save()


func _process(delta: float) -> void:
	if not _dirty or backend == "off":
		return
	_t += delta
	if _t >= FLUSH_EVERY:
		_t = 0.0
		flush()


# WRITE ON THE WAY OUT. A player who quits mid-session must not lose the last few seconds just
# because the debounce timer had not come round. NOTIFICATION_WM_CLOSE_REQUEST covers desktop/web
# tab close; APPLICATION_PAUSED is the one that matters on iOS, where backgrounding is the normal
# way a game ends and there is no "quit" at all.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		flush()


# ---------------- local backend ----------------

func _path() -> String:
	return LOCAL_PREFIX + game_id.replace("/", "_") + ".json"


func _local_load() -> Dictionary:
	var p := _path()
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	# A corrupt save must not brick the game. Start fresh rather than crash — a lost save is bad,
	# a game that will not open is worse, and the file is rewritten on the next flush anyway.
	if not (parsed is Dictionary):
		push_warning("[Save] local save unreadable — starting fresh")
		return {}
	return parsed


func _local_save() -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f == null:
		push_warning("[Save] could not open " + _path() + " for write")
		return
	f.store_string(JSON.stringify(_state))
	f.close()


# ---------------- cloud backend (Supabase / PostgREST) ----------------
#
# One row per (user_id, game_id), the blob in a jsonb column. RLS pins user_id = auth.uid(), so a
# player can only ever read or write their own row — the save layer never takes a user id from the
# caller, which is the mistake that lets one player overwrite another's progress.

func _rest(path: String) -> String:
	return Auth.supabase_url.rstrip("/") + "/rest/v1/" + path


func _headers(extra: Array = []) -> PackedStringArray:
	var h := PackedStringArray([
		"apikey: " + Auth.supabase_anon_key,
		"Authorization: Bearer " + Auth.bearer(),
		"Content-Type: application/json",
	])
	for e in extra:
		h.append(String(e))
	return h


func _cloud_load() -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)
	var url := _rest(TABLE + "?select=blob&game_id=eq." + game_id.uri_encode())
	var err := req.request(url, _headers(), HTTPClient.METHOD_GET)
	if err != OK:
		req.queue_free()
		push_warning("[Save] cloud load request failed to start")
		return {}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[1]) != 200:
		push_warning("[Save] cloud load HTTP " + str(res[1]))
		return {}
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if parsed is Array and (parsed as Array).size() > 0:
		var row = (parsed as Array)[0]
		if row is Dictionary and (row as Dictionary).get("blob", null) is Dictionary:
			return (row as Dictionary)["blob"]
	return {}


func _cloud_save() -> void:
	if _in_flight:
		_dirty = true      # a write is already out; re-mark so the next tick sends the newer state
		return
	_in_flight = true
	var req := HTTPRequest.new()
	add_child(req)
	var body := {"user_id": Auth.uid, "game_id": game_id, "blob": _state}
	# merge-duplicates = upsert on the (user_id, game_id) primary key.
	var err := req.request(_rest(TABLE), _headers(["Prefer: resolution=merge-duplicates"]),
		HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_in_flight = false
		req.queue_free()
		return
	var res: Array = await req.request_completed
	req.queue_free()
	_in_flight = false
	var code := int(res[1])
	if code < 200 or code >= 300:
		push_warning("[Save] cloud write HTTP " + str(code))
		_dirty = true      # keep it dirty so the next flush retries rather than losing the change
