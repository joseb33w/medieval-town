extends Node
## Serverless multiplayer client — Supabase Realtime broadcast, spoken DIRECTLY over
## WebSocketPeer. No supabase-js, no JavaScriptBridge, no bridge.js.
##
## WHY THIS IS NOT A WEB-ONLY MODULE ANY MORE
## The previous version was a shim over web/bridge.js over supabase-js: three layers to move one
## JSON blob, all of them reachable only through JavaScriptBridge. That made multiplayer
## structurally impossible in the native iOS player, which has no browser and no JS runtime — the
## old `_ready()` literally opened with `if not OS.has_feature("web"): return`.
##
## Supabase Realtime is Phoenix channels over a WebSocket, and Godot's WebSocketPeer has both a
## native backend (wsl_peer) and an emscripten one (emws_peer). So ONE client covers web and
## native, and the JS layer disappears rather than being duplicated.
##
## Verified end-to-end before this was written: anonymous join + broadcast round-trip natively,
## the same across two separate processes with the production `self:false` config, and again from
## inside a `nothreads` web export in a real browser.
##
## Register as an autoload named "Net".
##
## Usage from game code (UNCHANGED from the bridge version — signals and methods are identical):
##   Net.message.connect(_on_net)        # inbound {Dictionary} from a peer
##   Net.connected.connect(func(room, you): ...)
##   Net.connect_room()                  # after tap-to-start
##   Net.send({ "t": "pos", "x": p.x, "y": p.y })   # broadcast; "from" is added for you
## Spawn / update remote players keyed by data["from"]; despawn on a timeout.

signal connected(room: String, you: String)
signal disconnected()
signal message(data: Dictionary)

## Overridden from world.json's `multiplayer` block, or left as the shared Gogi project.
## The anon key is publishable by design — it is RLS-scoped and already ships in every public
## web build. It is NOT a service-role key and must never be one.
var supabase_url: String = ""
var supabase_anon_key: String = ""

var local_id: String = ""
var room: String = ""

## Phoenix drops an idle socket at 60s. 25s leaves room for one missed beat.
const HEARTBEAT_S := 25.0
## Rejoin backoff after a drop — capped so a long outage doesn't spin.
const RECONNECT_MIN_S := 1.0
const RECONNECT_MAX_S := 15.0

var _ws := WebSocketPeer.new()
var _ref := 0
var _joined := false
var _topic := ""
var _hb_t := 0.0
var _retry_t := 0.0
var _retry_delay := RECONNECT_MIN_S
var _want_connection := false


func _ready() -> void:
	# A short random id is enough: rooms are small and friend-scoped, and the id only has to be
	# unique among the handful of peers actually present.
	local_id = "p_" + str(randi() % 0xFFFFFF).pad_zeros(6)
	set_process(false)


## Join (or create) a room. An empty code generates one — readable, ambiguous glyphs removed so it
## survives being read aloud or typed from a screenshot.
func connect_room(code: String = "") -> void:
	if code == "":
		code = _url_room()
	if code == "":
		code = _generate_code()
	var new_topic := "realtime:game:" + code

	# ALREADY CONNECTED, DIFFERENT ROOM — the world-swap case, and it does not behave the way it
	# looks. This node is an AUTOLOAD, so it outlives the scene reload and its socket is still open
	# on the previous world's channel. Two things follow, both found by testing a real swap:
	#
	#  - calling connect_to_url on a live socket fails with ERR_ALREADY_IN_USE, so the socket is
	#    never actually replaced;
	#  - Phoenix multiplexes channels over ONE socket, so joining the new topic then succeeds
	#    anyway while the OLD subscription is still live — the new world quietly receives the
	#    previous world's peers, which looks like ghosts rather than like a bug.
	#
	# So leave the old channel explicitly and reuse the socket, rather than reconnecting it.
	var open_now := _ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	if open_now and _topic != "" and _topic != new_topic:
		_push("phx_leave", {})

	room = code
	_topic = new_topic
	_joined = false
	_want_connection = true
	if open_now:
		_ref = 0   # the join sentinel — next _process sends phx_join for the new topic
	else:
		_open_socket()
	set_process(true)


func send(data: Dictionary) -> void:
	if not _joined:
		return
	var payload := data.duplicate()
	payload["from"] = local_id
	_push("broadcast", {"type": "broadcast", "event": "msg", "payload": payload})


func is_connected_to_room() -> bool:
	return _joined


# ---------------------------------------------------------------------------------------------
# transport


func _open_socket() -> void:
	var url := supabase_url
	var key := supabase_anon_key
	if url == "" or key == "":
		push_warning("[Net] no Supabase credentials — set them from world.json's `multiplayer` block")
		return
	var host := url.replace("https://", "").replace("http://", "")
	while host.ends_with("/"):
		host = host.substr(0, host.length() - 1)
	# vsn=1.0.0 -> object frames {topic,event,payload,ref}. 2.0.0 would be arrays.
	# The socket is opened with the project's anon key (that is what `apikey` means), but the SESSION
	# is set separately below with the player's JWT. Realtime treats them differently: apikey admits
	# you to the project, access_token says WHO you are — and only the latter can ever be the basis
	# for per-channel authorization.
	var ws_url := "wss://%s/realtime/v1/websocket?apikey=%s&vsn=1.0.0" % [host, key]
	_joined = false
	_ref = 0
	var err := _ws.connect_to_url(ws_url)
	if err != OK:
		push_warning("[Net] connect_to_url failed: " + str(err))


## Tell Realtime who the player is, when there is a player to name.
##
## Sent AFTER the join reply rather than in the join payload: an expired or malformed token in the
## join itself is rejected as a channel error, which is indistinguishable from a broken room. Sent
## separately, an auth problem degrades to "connected but unauthenticated" — the game still runs.
##
## No-ops when the world did not ask for auth, so a signed-out multiplayer game keeps working
## exactly as it did before this existed.
func _send_access_token() -> void:
	var auth := get_node_or_null("/root/Auth")
	if auth == null or not auth.is_signed_in():
		return
	_push("access_token", {"access_token": auth.bearer()})


func _next_ref() -> String:
	_ref += 1
	return str(_ref)


func _push(event: String, payload: Dictionary, topic: String = "") -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify({
		"topic": topic if topic != "" else _topic,
		"event": event,
		"payload": payload,
		"ref": _next_ref(),
	}))


func _process(delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if _ref == 0:
				# CHANNEL TOPICS ARE PREFIXED WITH "realtime:" — joining the bare name is accepted
				# by the socket and then silently never delivers anything.
				_push("phx_join", {"config": {
					"broadcast": {"self": false, "ack": false},
					"presence": {"key": ""},
				}})
			while _ws.get_available_packet_count() > 0:
				_handle(_ws.get_packet().get_string_from_utf8())
			_hb_t += delta
			if _hb_t >= HEARTBEAT_S:
				_hb_t = 0.0
				_push("heartbeat", {}, "phoenix")
			_retry_delay = RECONNECT_MIN_S

		WebSocketPeer.STATE_CLOSED:
			if _joined:
				_joined = false
				disconnected.emit()
			if not _want_connection:
				set_process(false)
				return
			# Reconnect with backoff. The old bridge had no reconnect at all: a dropped socket
			# ended the session silently and the game kept broadcasting into nothing.
			_retry_t += delta
			if _retry_t >= _retry_delay:
				_retry_t = 0.0
				_retry_delay = minf(_retry_delay * 2.0, RECONNECT_MAX_S)
				_open_socket()


func _handle(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var d: Dictionary = parsed
	match str(d.get("event", "")):
		"phx_reply":
			if _joined:
				return
			var p: Dictionary = d.get("payload", {})
			if str(p.get("status", "")) == "ok" and str(d.get("topic", "")) == _topic:
				_joined = true
				_hb_t = 0.0
				_send_access_token()
				connected.emit(room, local_id)
			elif str(d.get("topic", "")) == _topic:
				push_warning("[Net] channel join rejected: " + raw.substr(0, 200))
		"broadcast":
			# Topic-checked, not assumed. One socket can carry several channels, so a frame arriving
			# here is not necessarily for the room we are in — during a room change, or if a leave is
			# still in flight, the previous channel can still deliver. Without this the old world's
			# players appear in the new one.
			if str(d.get("topic", "")) != _topic:
				return
			var bp: Dictionary = d.get("payload", {})
			var inner: Variant = bp.get("payload", {})
			if inner is Dictionary:
				message.emit(inner)
		"phx_error", "phx_close":
			if _joined:
				_joined = false
				disconnected.emit()
			_ws.close()


# ---------------------------------------------------------------------------------------------
# room codes


## `?room=` from the page URL on web. Native has no URL bar — the host passes `--room=` instead,
## which the game shell reads and hands to connect_room().
func _url_room() -> String:
	if not OS.has_feature("web"):
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--room="):
				return a.substr(7).strip_edges()
		return ""
	var search: Variant = JavaScriptBridge.eval("window.location.search", true)
	if search == null:
		return ""
	var q := str(search)
	var i := q.find("room=")
	if i < 0:
		return ""
	var v := q.substr(i + 5)
	var amp := v.find("&")
	return v.substr(0, amp) if amp >= 0 else v


## No 0/O/1/I/L — the code gets read aloud and typed from screenshots.
func _generate_code() -> String:
	const GLYPHS := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	var out := ""
	for i in 5:
		out += GLYPHS[randi() % GLYPHS.length()]
	if OS.has_feature("web"):
		# Put it in the address bar so the browser player can share the link they already have.
		JavaScriptBridge.eval(
			"(function(u){u.set('room','%s');history.replaceState(null,'','?'+u.toString());})"
			% out + "(new URLSearchParams(location.search));", true)
	return out
