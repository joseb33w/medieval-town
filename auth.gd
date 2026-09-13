extends Node
## Supabase email auth, spoken DIRECTLY to GoTrue's REST API over HTTPRequest.
##
## No supabase-js — same reason net.gd does not use it: the native iOS player has no browser and no
## JS runtime, so anything routed through JS works on the web and nowhere else. Every REQUEST here
## is HTTPRequest: one implementation, both tiers. The single exception is reading the web handoff
## token (see WEB_TOKEN_GLOBAL), which is ingress rather than protocol and has a native counterpart
## on the command line.
##
## WHY THE ENGINE OWNS THIS. A game that ships its own auth code is game-authored script, which the
## data-only gate rejects and the native player cannot execute. So sign-in lives here, in the pack,
## and a world turns it on with data (`"auth": true`).
##
## WHAT IT IS NOT: this is not a security boundary against the player. The client is fully under
## their control. Auth answers "which account is this" — it stops one player reading or overwriting
## ANOTHER player's rows. It does nothing about someone cheating in their own save; that needs
## server-side clamping in the RPC (see the backend rules).
##
## Register as an autoload named "Auth".

signal signed_in(uid: String)
signal signed_out()
signal auth_failed(reason: String)

## Set from world.json's backend/multiplayer block before any call. The anon key is publishable by
## design and is NOT a session — it only identifies the project.
var supabase_url: String = ""
var supabase_anon_key: String = ""

var uid: String = ""
var email: String = ""

var _access_token: String = ""
var _refresh_token: String = ""
var _expires_at: float = 0.0

## Refresh this far before expiry. Tokens last an hour by default; a wide margin means a slow
## network or a backgrounded tab cannot leave us holding a dead token mid-session.
const REFRESH_MARGIN_S := 300.0
const SESSION_PATH := "user://gogi_auth.json"

## Command-line handoff from a host that has ALREADY identified this player.
##
## The native player signs the user into the Gogi app long before a game opens, so making them type
## a second set of credentials into a game they just tapped is a wall with nothing behind it — the
## host already knows exactly who they are. It mints a Supabase session server-side (keyed to the
## signed-in account) and hands the refresh token in here, so `restore_session()` succeeds and
## auth_gate never draws.
##
## A REFRESH TOKEN, NOT AN ACCESS TOKEN, deliberately: it is the only credential this class can act
## on without also needing an expiry, and it goes through the SAME `/token?grant_type=refresh_token`
## exchange a returning player's saved session does — one code path, already proven, and a stale or
## revoked handoff degrades to the normal sign-in prompt instead of a broken session.
##
## Passed after a bare `--` so it lands in OS.get_cmdline_user_args() — the documented channel for
## host arguments, and the same one --world-url uses. NEVER printed: unlike the world URL this is a
## credential, and the engine logs are visible in a browser console and in device logs.
const CMDLINE_TOKEN_PREFIX := "--auth-refresh-token="

## Web handoff channel: a JS global the HOST PAGE plants before the engine boots.
##
## A web build has no command line. GODOT_CONFIG.args looks like the equivalent seam and is not —
## injecting there does NOT reach OS.get_cmdline_user_args() (measured 2026-08-24 against a live
## build). The page is the only thing that can speak to a web build before _ready, so the token is
## read from a global instead.
##
## NOT a query parameter, deliberately. A refresh token in a URL leaks into browser history, the
## Referer header on every outbound request, and each access log between the tab and R2. A global
## assigned in-process leaves no trace outside that tab.
##
## This is the one place JavaScriptBridge appears in this file, and it does not contradict the class
## doc above: the auth PROTOCOL is still a single implementation over HTTPRequest for both tiers.
## Only the INGRESS is tier-specific, exactly as it already is for the native command line.
const WEB_TOKEN_GLOBAL := "__gogiAuthRefresh"


func _ready() -> void:
	set_process(false)


## The refresh token handed in by the host, or "" when the player is opening the game on their own.
func _handed_token() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(CMDLINE_TOKEN_PREFIX):
			return a.substr(CMDLINE_TOKEN_PREFIX.length()).strip_edges()
	if OS.has_feature("web"):
		# The type is CHECKED rather than assumed. JavaScriptBridge marshals loosely — a JS boolean
		# comes back as TYPE_INT, not TYPE_BOOL, which is what silently killed every ?flag=1 in
		# main.gd — and an unset global arrives as null. `|| ""` makes "absent" and "empty" the same
		# answer so only a real string can ever reach the token exchange.
		var v = JavaScriptBridge.eval('window.%s || ""' % WEB_TOKEN_GLOBAL, true)
		if typeof(v) == TYPE_STRING:
			return String(v).strip_edges()
	return ""


func is_signed_in() -> bool:
	return _access_token != "" and uid != ""


## The header value RPC and Realtime calls should carry. Falls back to the anon key so an
## unauthenticated call still reaches the API and fails with a clean 401 rather than a malformed
## request nobody can read.
func bearer() -> String:
	return _access_token if _access_token != "" else supabase_anon_key


func sign_up(p_email: String, p_password: String) -> Dictionary:
	var res := await _post("/auth/v1/signup", {"email": p_email.strip_edges(), "password": p_password})
	return _adopt(res, "sign_up")


func sign_in(p_email: String, p_password: String) -> Dictionary:
	var res := await _post("/auth/v1/token?grant_type=password",
		{"email": p_email.strip_edges(), "password": p_password})
	return _adopt(res, "sign_in")


## Send a reset email. Deliberately reports success even when the address is unknown — telling a
## caller "no such user" turns this endpoint into an account-existence oracle.
func recover(p_email: String) -> bool:
	var res := await _post("/auth/v1/recover", {"email": p_email.strip_edges()})
	return int(res.get("code", 0)) < 500


## Restore a previous session from disk. Returns true when the player is signed in again.
##
## THIS IS WHAT MAKES THE ACCOUNT FEEL PERSISTENT. Without it every launch is a fresh sign-in
## prompt, which for a game is indistinguishable from having lost the account.
func restore_session() -> bool:
	# A token handed in by the host WINS over anything cached on this device. The host knows who is
	# signed in right now; the file only knows who was signed in last time, and on a shared or
	# re-signed-in device those differ — silently resuming the wrong account is worse than a prompt.
	var handed := _handed_token()
	if handed != "":
		_refresh_token = handed
		var handed_res := await _post(
			"/auth/v1/token?grant_type=refresh_token", {"refresh_token": _refresh_token})
		var handed_out := _adopt(handed_res, "handoff")
		if bool(handed_out.get("ok", false)):
			return true
		# Fall through rather than fail: an expired handoff should land the player on the normal
		# sign-in screen, not lock them out of a game they can legitimately play.
		_refresh_token = ""
		print("GOGI_AUTH handoff rejected — falling back to the saved session")

	if not FileAccess.file_exists(SESSION_PATH):
		return false
	var f := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return false
	var saved: Dictionary = parsed
	_refresh_token = str(saved.get("refresh_token", ""))
	if _refresh_token == "":
		return false
	var res := await _post("/auth/v1/token?grant_type=refresh_token", {"refresh_token": _refresh_token})
	var out := _adopt(res, "restore")
	if not bool(out.get("ok", false)):
		# The refresh token is spent or revoked. Clear it — retrying a dead token every launch just
		# delays the sign-in prompt the player now needs.
		_clear_saved()
		return false
	return true


func sign_out() -> void:
	if _access_token != "":
		# Best-effort revoke; a failure here must not prevent the LOCAL session being cleared, or the
		# player stays signed in on their own device after asking not to be.
		_post("/auth/v1/logout", {})
	_access_token = ""
	_refresh_token = ""
	uid = ""
	email = ""
	_expires_at = 0.0
	set_process(false)
	_clear_saved()
	signed_out.emit()


# ---------------------------------------------------------------------------------------------


func _adopt(res: Dictionary, what: String) -> Dictionary:
	var body: Dictionary = res.get("body", {})
	var code := int(res.get("code", 0))
	if code < 200 or code >= 300:
		# GoTrue puts the human-readable reason in different fields depending on the failure.
		var why := str(body.get("error_description", body.get("msg", body.get("error", "HTTP " + str(code)))))
		auth_failed.emit(why)
		return {"ok": false, "error": why}

	_access_token = str(body.get("access_token", ""))
	_refresh_token = str(body.get("refresh_token", _refresh_token))
	_expires_at = Time.get_unix_time_from_system() + float(body.get("expires_in", 3600))
	var user: Dictionary = body.get("user", {})
	uid = str(user.get("id", uid))
	email = str(user.get("email", email))

	if _access_token == "":
		# Signup with email confirmation ON returns a user and NO session — the player must click a
		# link first. Say so plainly; "success" with no way to play is the worst possible outcome.
		var msg := "check your email to confirm this address, then sign in"
		auth_failed.emit(msg)
		return {"ok": false, "error": msg, "needs_confirmation": true}

	_save()
	set_process(true)   # arms the refresh loop
	signed_in.emit(uid)
	print("GOGI_AUTH signed in uid=", uid, " (", what, ")")
	return {"ok": true, "uid": uid}


func _process(_delta: float) -> void:
	if _refresh_token == "" or _expires_at <= 0.0:
		return
	if Time.get_unix_time_from_system() < _expires_at - REFRESH_MARGIN_S:
		return
	_expires_at = Time.get_unix_time_from_system() + 60.0   # debounce while the refresh is in flight
	_refresh_now()


func _refresh_now() -> void:
	var res := await _post("/auth/v1/token?grant_type=refresh_token", {"refresh_token": _refresh_token})
	if int(res.get("code", 0)) >= 300:
		push_warning("[Auth] token refresh failed — session ended")
		_clear_saved()
		_access_token = ""
		uid = ""
		set_process(false)
		signed_out.emit()
		return
	_adopt(res, "refresh")


## ONLY the refresh token is written, never the access token or the password. The access token is
## short-lived and re-derivable; persisting it would just leave a longer-lived credential on disk
## for no gain. On iOS this lands in the app sandbox — adequate for a game account, and NOT where a
## payment credential would belong.
func _save() -> void:
	var f := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"refresh_token": _refresh_token, "uid": uid, "email": email}))
	f.close()


func _clear_saved() -> void:
	if FileAccess.file_exists(SESSION_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_PATH))


func _post(path: String, body: Dictionary) -> Dictionary:
	if supabase_url == "" or supabase_anon_key == "":
		return {"code": 0, "body": {"error": "auth not configured"}}
	var req := HTTPRequest.new()
	add_child(req)
	var headers := PackedStringArray([
		"apikey: " + supabase_anon_key,
		"Authorization: Bearer " + (_access_token if _access_token != "" else supabase_anon_key),
		"Content-Type: application/json",
	])
	var url := supabase_url.rstrip("/") + path
	var err := req.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return {"code": 0, "body": {"error": "request failed: " + str(err)}}
	var result: Array = await req.request_completed
	req.queue_free()
	var code := int(result[1])
	var parsed: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	return {"code": code, "body": parsed if parsed is Dictionary else {}}
