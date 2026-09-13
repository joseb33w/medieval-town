extends Node
## GLOBAL AUDIO — autoloaded as `AudioManager` (see project.godot [autoload]).
## Guarantees EVERY game is audible: ships baked CC0 default SFX + an ambient bed
## (res://audio/), pools SFX voices so overlapping sounds don't cut each other, and
## unlocks the Web AudioContext on the first user gesture (browser autoplay policy /
## iOS Safari) via a "Tap to play" overlay. CC0 audio is from the Ninja Adventure pack;
## the broader library lives at <origin>/godot-assets/audio/ (manifest "audio" section).
##
## Use:
##   AudioManager.play_sfx("hit")                                  # baked: attack/hit/hurt/death/pickup/ui/door
##   AudioManager.register_sfx("boom", load("res://audio/boom.wav"))   # extra SFX you curled from the library
##   AudioManager.play_music(load("res://audio/music_village.ogg"))    # loops; style-match the game (see audio.md)
##   AudioManager.play_ambient(load("res://audio/waves.ogg"))          # per-biome bed; loops

const SFX_VOICES := 8

var _sfx: Array[AudioStreamPlayer] = []
var _i := 0
var _music: AudioStreamPlayer
var _ambient: AudioStreamPlayer
# WEATHER gets its OWN bed, separate from _ambient. They used to share one channel with two blind
# writers — weather3d wrote rain, the game's region system wrote the biome bed (forest birds, night
# crickets), and whichever ran last silently clobbered the other. Two bugs fell out of that: clearing
# the weather left the rain loop playing forever (weather3d only ever CALLED play_ambient, it had no
# stop path at all), and the region system cached "what I last set", so after weather overwrote the
# channel it believed its bed was still playing and refused to restore it until you changed region.
# Separate channels fix both by construction, and rain over forest birds is what it should sound like
# anyway — it rains in forests.
var _weather: AudioStreamPlayer
var _weather_cur := ""               # stream path currently on the weather bed ("" = silent)
var _weather_fade: Tween             # in-flight fade-out, killed if weather changes mid-fade
var _bank := {}
var _unlocked := false
var _overlay: CanvasLayer = null
var _world_loops: Array[AudioStreamPlayer3D] = []   # positional loops queued before the web unlock gesture


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # audio keeps working while the tree is paused (menus/dialogue)
	for _n in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx.append(p)
	_music = AudioStreamPlayer.new(); _music.bus = "Music"; add_child(_music)
	_ambient = AudioStreamPlayer.new(); _ambient.bus = "Music"; add_child(_ambient)
	_weather = AudioStreamPlayer.new(); _weather.bus = "Music"; add_child(_weather)
	_load_defaults()
	# _warm_all() is deliberately NOT called. Warming every bed at boot trades a small
	# region-entry stall for permanently-resident audio, and memory is the resource that actually
	# fails on-device. stream_for() below still caches on first use, so each bed stalls at most once.
	# Native (desktop): no browser autoplay policy, so start the bed immediately. But SKIP under the
	# HEADLESS display driver (verify/QA smoke loads, CI, the export check): it has no audio device, so
	# a looping bed there is pointless AND its playback is orphaned in the AudioServer at --quit, which
	# can't flush it before the engine's exit-time resource check → the benign-but-noisy "resources
	# still in use at exit (res://audio/ambient.wav)" leak. The shipped game is a WEB export, where this
	# whole branch is skipped anyway (audio unlocks on the tap gesture via unlock()/show_tap_overlay).
	if not OS.has_feature("web"):
		_unlocked = true
		if DisplayServer.get_name() != "headless":
			play_default_ambient()

	# ONE LINE OF AUDIO STATE AT BOOT — because silence is otherwise undiagnosable.
	#
	# When a player reports "no sound" there is no error, nothing logs, and the cause could be any of:
	# the unlock gate still closed, the bed never loaded, the master bus muted, the iOS session
	# category obeying the hardware silent switch, or simply a world that ships no audio content.
	# Those need completely different fixes and look identical from a screen recording. This says which
	# — and it is one print at startup, not a per-frame probe.
	print("GOGI_AUDIO unlocked=", _unlocked,
		" ds=", DisplayServer.get_name(),
		" bed=", ("playing" if _ambient.playing else ("loaded" if _ambient.stream != null else "none")),
		" master_db=", AudioServer.get_bus_volume_db(0),
		" master_muted=", AudioServer.is_bus_mute(0),
		" out=", AudioServer.get_output_device())

	# On web, playback waits for a user gesture (browser autoplay policy / iOS Safari).
	# The game triggers it ONE of two ways: show_tap_overlay() if it has no start screen
	# (the RPG streaming starter calls this), or unlock() from its own start gate (the
	# 3D/2D starters' "Tap to start" handler calls this).


func _load_defaults() -> void:
	# Neutral CC0 (Kenney) defaults ship as .ogg; .wav kept as a fallback.
	for n in ["attack", "hit", "hurt", "death", "pickup", "ui", "door", "thunder"]:
		for ext in ["ogg", "wav"]:
			var p := "res://audio/%s.%s" % [n, ext]
			if ResourceLoader.exists(p):
				_bank[n] = load(p)
				break


# Warm EVERY bed in res://audio/ at boot so region entry never pays a blocking load().
#
# Region music/ambient is chosen at runtime from world.json ("music"/"ambient" names), so there is no
# static list to preload from — the game_director resolves a name to a path and used to `load()` it
# ON THE FRAME the player crossed the border, from _process, with no loading screen to hide it. A
# multi-MB .ogg that way is a visible freeze. The audio already lives in the .pck (it was downloaded
# with the game), so warming costs no bandwidth — it just moves the resource-parse cost to boot,
# where a loading screen absorbs it.
#
# Export-safe: an exported project stores audio under remapped names, so entries can come back as
# `<file>.ogg.remap` / `.import`. Strip those suffixes and let ResourceLoader.exists() reject
# anything that isn't real. Wrapped so a filesystem quirk degrades to lazy loading, never a crash.
func _warm_all() -> void:
	var dir := DirAccess.open("res://audio")
	if dir == null:
		return
	var paths: Array = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var n := fname
			for suffix in [".remap", ".import"]:
				if n.ends_with(suffix):
					n = n.substr(0, n.length() - suffix.length())
			if n.ends_with(".ogg") or n.ends_with(".wav"):
				var p := "res://audio/" + n
				if not paths.has(p):
					paths.append(p)
		fname = dir.get_next()
	dir.list_dir_end()
	warm(paths)


func register_sfx(sname: String, stream: AudioStream) -> void:
	if stream != null:
		_bank[sname] = stream


func has_sfx(sname: String) -> bool:
	return _bank.has(sname)


# Fire a one-shot SFX by name on a free pooled voice. Unknown name = silent no-op.
func play_sfx(sname: String, vol_db := 0.0, pitch := 1.0) -> void:
	var s: AudioStream = _bank.get(sname, null)
	if s == null:
		return
	var p := _sfx[_i]
	_i = (_i + 1) % _sfx.size()
	p.stream = s
	p.volume_db = vol_db
	p.pitch_scale = pitch
	p.play()


func _loopify(s: AudioStream) -> void:
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	elif s is AudioStreamWAV:
		(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD


# Looping background music on the Music bus. Replaces any current track. Starts once unlocked.
# ---------------- CACHED STREAMS BY PATH (do NOT `load()` on the hot path) ----------------
#
# A blocking `load("res://audio/<x>.ogg")` at the moment the player crosses a region border
# decodes the whole file on THAT frame — a multi-MB .ogg is a visible freeze, and it fires from
# _process/_physics_process where there is no loading screen to hide it. The engine is exported
# `nothreads`, so there is no background loader to fall back on; the only cure is to pay the cost
# EARLY, while a loading screen is up and a stall is invisible.
#
# Use `AudioManager.warm(paths)` during boot with every audio path the world can reach, then call
# the `_path` variants below at runtime — they hit the cache and never touch the disk. A cache MISS
# still loads (correctness over speed: a late-authored path must still play), so warming is an
# optimization, not a precondition. Chat edits that introduce a NEW audio path therefore keep
# working; re-run warm() after a hot-reload to move the cost back off the hot path.
var _stream_cache := {}   # res:// path -> AudioStream (template defaults, from the .pck)
var _remote := {}         # bare name -> AudioStream fetched from the game's loose audio/ dir

func warm(paths) -> void:
	if not (paths is Array):
		return
	for p0 in paths:
		var p := String(p0)
		if p == "" or _stream_cache.has(p):
			continue
		if not ResourceLoader.exists(p):
			continue
		var s = load(p)
		if s is AudioStream:
			_stream_cache[p] = s


# Cached fetch. Returns null for a missing/invalid path (callers already null-guard).
#
# TWO SOURCES, in order: the .pck (template default SFX — attack/hit/hurt/door/ui/…) and then the
# REMOTE cache filled by warm_remote(). A game's OWN music and ambience (its boss theme, its biome
# beds) are NOT in the .pck: they are loose files served next to world.json, exactly like models.
# That is what lets a game be a self-contained DATA bundle the native player can download, instead
# of content baked into a web export.
#
# Deliberately SYNCHRONOUS and non-blocking: callers use it inline on a region change, so it can
# never wait on a fetch. A bed that has not landed yet simply returns null and stays silent — best
# effort, never a stall and never an error. warm_remote() is what makes the hit rate ~100%.
func stream_for(path: String) -> AudioStream:
	if path == "":
		return null
	if _stream_cache.has(path):
		return _stream_cache[path]
	if ResourceLoader.exists(path):
		var s = load(path)
		if s is AudioStream:
			_stream_cache[path] = s
			return s
	return _remote.get(_basename(path), null)


static func _basename(path: String) -> String:
	# "res://audio/boss_dramatic.ogg" -> "boss_dramatic"
	return path.get_file().get_basename()


# Fetch a game's own audio from `base` (the directory holding world.json) into the remote cache.
# Called once at boot with the names the game actually uses, so a region change is a cache hit.
# Failures are silent by design — a missing bed is quieter, not broken.
func warm_remote(base: String, names: Array) -> void:
	if base == "":
		return
	for n0 in names:
		var name_ := String(n0)
		if name_ == "" or _remote.has(name_):
			continue
		if ResourceLoader.exists("res://audio/%s.ogg" % name_) or ResourceLoader.exists("res://audio/%s.wav" % name_):
			continue   # a template default already ships in the .pck
		_fetch_remote(base, name_)


func _fetch_remote(base: String, name_: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request("%saudio/%s.ogg" % [base, name_])
	var res = await req.request_completed
	req.queue_free()
	if res[1] != 200:
		return
	var body: PackedByteArray = res[3]
	if body.size() < 32:
		return
	var s := AudioStreamOggVorbis.load_from_buffer(body)
	if s != null:
		_remote[name_] = s


# ---------------- weather bed (own channel; see _weather) ----------------

# Switch the weather bed. Idempotent: re-applying the SAME bed is a no-op, so the per-frame weather
# apply can call this freely without restarting the loop. Pass "" (or call stop_weather) to clear.
func play_weather_path(path: String, vol_db := -10.0) -> void:
	if path == "":
		stop_weather()
		return
	if path == _weather_cur and _weather.playing:
		return
	var s := stream_for(path)   # cached — never a blocking load() on a weather change mid-gameplay
	if s == null:
		return
	if _weather_fade != null and _weather_fade.is_valid():
		_weather_fade.kill()    # a fade-out was running; we're overriding it
	_weather_cur = path
	_loopify(s)
	_weather.stream = s
	_weather.volume_db = vol_db
	if _unlocked:
		_weather.play()


# Fade the weather bed out and stop it. Fading rather than cutting because weather transitions are
# gradual on screen (the fog/light lerp), and a hard audio cut against a soft visual fade reads as a
# glitch. A fade already in flight is left alone so repeated clear-weather applies don't restart it.
func stop_weather(fade_sec := 1.0) -> void:
	if _weather_cur == "":
		return
	_weather_cur = ""
	if not _weather.playing:
		return
	if _weather_fade != null and _weather_fade.is_valid():
		return
	var from_db := _weather.volume_db
	_weather_fade = create_tween()
	_weather_fade.tween_property(_weather, "volume_db", -60.0, fade_sec)
	_weather_fade.tween_callback(func() -> void:
		_weather.stop()
		_weather.volume_db = from_db)   # restore so the NEXT bed doesn't start silent


## `stop_audio`. "music" / "ambient" / "weather" / "all" (default). Silence has to be addressable:
## a rule that can start a track but never stop it leaves an author with no way to write the moment
## the music cuts out — the single most reliable dramatic beat there is.
func stop_audio(what := "all") -> int:
	var n := 0
	var w := what.to_lower()
	if (w == "all" or w == "music") and _music != null:
		_music.stop()
		_music.stream = null
		n += 1
	if (w == "all" or w == "ambient" or w == "bed") and _ambient != null:
		_ambient.stop()
		_ambient.stream = null
		n += 1
	if (w == "all" or w == "weather") and _weather != null:
		_weather.stop()
		_weather.stream = null
		n += 1
	print("GOGI_AUDIO stop=%s n=%d" % [w, n])
	return n


func play_music_path(path: String, vol_db := -7.0) -> void:
	play_music(stream_for(path), vol_db)


func play_ambient_path(path: String, vol_db := -12.0) -> void:
	play_ambient(stream_for(path), vol_db)


func play_music(stream: AudioStream, vol_db := -7.0) -> void:
	if stream == null:
		return
	_loopify(stream)
	_music.stream = stream
	_music.volume_db = vol_db
	if _unlocked:
		_music.play()


# Looping ambient bed (waves/wind/rain) on the Music bus, quieter than music.
func play_ambient(stream: AudioStream, vol_db := -12.0) -> void:
	if stream == null:
		return
	_loopify(stream)
	_ambient.stream = stream
	_ambient.volume_db = vol_db
	if _unlocked:
		_ambient.play()


# A POSITIONAL looping world sound anchored to a node/spot — a fountain, the road, an
# NPC, a machine. It attenuates with distance + pans, so the soundscape is LOCALIZED to
# its source instead of a global wash. Reserve play_ambient() for WEATHER + at most ONE
# subtle biome bed; everything that belongs to a PLACE or a CHARACTER goes through here
# (a busy city = many quiet localized sources, not one loud omnipresent loop). Returns
# the player; it is freed automatically when its parent node is freed (e.g. cell evict).
func attach_loop(parent: Node3D, stream: AudioStream, vol_db := -8.0, max_distance := 18.0, unit_size := 5.0) -> AudioStreamPlayer3D:
	if parent == null or stream == null:
		return null
	_loopify(stream)
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = "SFX"
	p.volume_db = vol_db
	p.max_distance = max_distance
	p.unit_size = unit_size
	p.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(p)
	if _unlocked:
		p.play()
	else:
		_world_loops.append(p)   # web autoplay is gated until the first gesture
	return p


# Reset every channel for a runtime world swap (see main.gd `_switch_world`).
#
# The scene is fully torn down and rebuilt when the player opens a different game, but AudioManager is
# an AUTOLOAD — it survives that, along with whatever the previous world left playing. Without this,
# game B opens with game A's music still going and its biome bed underneath.
#
# `_world_loops` holds AudioStreamPlayer3D nodes parented into the WORLD, so the reload frees them;
# the array is cleared rather than stopped, because stopping a freed node is the error and dropping
# the references is the actual requirement. The baked bed is restarted so the new world is never
# dead-silent while it streams in — the same guarantee boot gives.
func reset_for_world_change() -> void:
	for p in [_music, _ambient, _weather]:
		if p != null:
			p.stop()
			p.stream = null
	_world_loops.clear()

	if not OS.has_feature("web") and DisplayServer.get_name() != "headless":
		play_default_ambient()


# Baked fallback bed so a game is never dead-silent before it sets its own ambient.
func play_default_ambient() -> void:
	if _ambient.stream != null:
		return
	var p := "res://audio/ambient.wav"
	if ResourceLoader.exists(p):
		play_ambient(load(p))


# Web AudioContext starts suspended until a user gesture. Godot's web driver resumes
# on the first canvas input; we ALSO start queued music/ambient here so sound begins
# the moment the player taps.
func unlock() -> void:
	if _unlocked:
		return
	_unlocked = true
	if _ambient.stream == null:
		play_default_ambient()
	if _ambient.stream != null and not _ambient.playing:
		_ambient.play()
	if _music.stream != null and not _music.playing:
		_music.play()
	if _weather.stream != null and not _weather.playing:
		_weather.play()   # weather set before the web unlock gesture still starts on unlock
	for wl in _world_loops:
		if is_instance_valid(wl) and not wl.playing:
			wl.play()
	_world_loops.clear()


func set_music_volume_db(db: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), db)


func set_sfx_volume_db(db: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), db)


func show_tap_overlay() -> void:
	if not OS.has_feature("web") or _unlocked or _overlay != null:
		return
	_overlay = CanvasLayer.new()
	_overlay.layer = 200
	add_child(_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.08, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(dim)
	var lbl := Label.new()
	lbl.text = "Tap to play"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 42)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(lbl)
	dim.gui_input.connect(_on_overlay_input)


func _on_overlay_input(event: InputEvent) -> void:
	var pressed := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
		or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventKey and (event as InputEventKey).pressed)
	if pressed:
		unlock()
		if _overlay != null:
			_overlay.queue_free()
			_overlay = null
