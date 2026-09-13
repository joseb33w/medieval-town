class_name GSurf
## SURFACE COOKBOOK — the SURFACE axis of the construction system. Turns bare geometry into a real, themed
## surface: TRIPLANAR materials (so a tiled texture never STRETCHES across a big/scaled box — the #1 "flat wall"
## bug), named civilization surfaces (sandstone/concrete/marble/…), EMISSIVE window/sign facades (so towers light
## up at night instead of going black), DECAL quads (hieroglyphs / road markings / posters / grime stamped onto a
## face), and emissive sign LIGHT-POOLS (a real OmniLight co-located with neon so the city lights ITSELF — the
## single biggest night-look miss). gl_compatibility / WebGL2-safe: no Environment glow (that's faked elsewhere),
## just self-illumination + point lights + procedural normal relief.
##
## Materials are CACHED (one per spec+palette) so a whole district shares coherent, low-overhead materials.
##
## ALBEDO CEILING — the "no near-white albedo" rule: every albedo resolved through surface()/_resolve() is
## clamped to <= 0.85 per RGB channel. Pre-fix, ACES with default tonemap_white 1.0 clipped any albedo
## >= ~0.72 to detail-free flat white at noon; 0.85 + main.gd's env.tonemap_white = 4.0 leaves real headroom
## so pale walls keep N·L shading and hue separation. ALBEDO ONLY — emission/glow colors (emissive(),
## window_facade glow, sign_light) are deliberately near-white and must stay unclamped.

# ---- Mobile VRAM: runtime texture cap for streamed GLB templates (WEB only) ----
# Streamed Meshy GLBs embed 1-2K textures that decode to UNCOMPRESSED RGBA in VRAM — the dominant
# mobile-OOM cost once ~GLB_CACHE_CAP templates are resident (a small index.pck is no longer the
# ceiling; decoded model textures are). On WEB, shrink every material texture in a freshly-parsed GLB
# to at most WEB_TEX_CAP px on its long edge, ONCE per template BEFORE it is cached — all .duplicate()
# instances then share the one shrunk texture, so RENDER_TEXTURE_MEM_USED (the GOGI_VRAM_MB the QA gate
# reads) drops with it. Native / editor is untouched. A shared source texture is resized once (deduped
# by identity); an already-small one is skipped. Called by area_builder (cell templates) and
# main._fetch_glb_scene (vehicles / hero).
const WEB_TEX_CAP := 320   # 512 -> 320. Halves texture memory again on top of the ETC2 re-compression
                           # below. These are stylised low-poly assets on a phone screen, where 320px on
                           # the long edge is past the point of visible difference — and video memory is
                           # the resource that actually fails on-device (iPhone freezes, Mac never does).

static func cap_textures_for_web(root: Node) -> void:
	if root == null or not OS.has_feature("web"):
		return
	_cap_walk(root, {})

static func _cap_walk(node: Node, seen: Dictionary) -> void:
	var mi := node as MeshInstance3D
	if mi != null:
		for i in mi.get_surface_override_material_count():
			_cap_material(mi.get_surface_override_material(i), seen)
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				_cap_material(mesh.surface_get_material(i), seen)
	for c in node.get_children():
		_cap_walk(c, seen)

static func _cap_material(m: Material, seen: Dictionary) -> void:
	var bm := m as BaseMaterial3D
	if bm == null:
		return
	for slot in [
		BaseMaterial3D.TEXTURE_ALBEDO,
		BaseMaterial3D.TEXTURE_NORMAL,
		BaseMaterial3D.TEXTURE_ROUGHNESS,
		BaseMaterial3D.TEXTURE_METALLIC,
		BaseMaterial3D.TEXTURE_EMISSION,
		BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION,
	]:
		var tex := bm.get_texture(slot)
		if tex == null:
			continue
		if seen.has(tex):
			bm.set_texture(slot, seen[tex])
			continue
		var shrunk := _shrink_tex(tex)
		if shrunk != null:
			seen[tex] = shrunk
			bm.set_texture(slot, shrunk)
		else:
			seen[tex] = tex   # already small — remember so a shared ref isn't re-checked

static func _shrink_tex(tex: Texture2D) -> ImageTexture:
	var img := tex.get_image()
	if img == null:
		return null
	var mx := maxi(img.get_width(), img.get_height())
	if mx <= WEB_TEX_CAP:
		return null
	if img.is_compressed():
		img.decompress()
	var s := float(WEB_TEX_CAP) / float(mx)
	img.resize(maxi(1, roundi(img.get_width() * s)), maxi(1, roundi(img.get_height() * s)), Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	# NO RUNTIME RE-COMPRESSION — it does not work in a web export, and trying is worse than useless.
	# Image.compress() needs a compressor the WEB TEMPLATE DOES NOT SHIP (they are editor-side). A
	# call here fails on every texture with `Parameter "_image_compress_etc2_func" is null` — dozens of
	# console errors per cell build, CPU burned on a copy that is then discarded, and the texture stays
	# RGBA8 regardless. It appeared to work when tested against the headless macOS EDITOR binary, which
	# does have the compressor; that test could not have caught this. Verified failing in a live web
	# build. (The project's `import_etc2_astc` setting compresses textures at IMPORT time; it cannot
	# reach GLBs that are downloaded and parsed at runtime.)
	#
	# So on web the only lever for streamed-texture memory is SIZE, which is what WEB_TEX_CAP does.
	# A native export has the compressors and could re-enable this — gate it on OS.has_feature("web")
	# being FALSE if that day comes.
	return ImageTexture.create_from_image(img)


# Named surface presets: color + roughness + metallic + normal-bump + uv tiling (units per texture repeat).
const SURFACES := {
	"sandstone": {"color": [0.80, 0.68, 0.45], "rough": 0.92, "metal": 0.0, "bump": 0.45, "tile": 4.0},
	"limestone": {"color": [0.86, 0.82, 0.72], "rough": 0.88, "metal": 0.0, "bump": 0.35, "tile": 4.0},
	"concrete":  {"color": [0.55, 0.55, 0.57], "rough": 0.9,  "metal": 0.0, "bump": 0.25, "tile": 4.0},
	"stucco":    {"color": [0.86, 0.82, 0.74], "rough": 0.95, "metal": 0.0, "bump": 0.3,  "tile": 3.0},
	"brick":     {"color": [0.55, 0.30, 0.24], "rough": 0.88, "metal": 0.0, "bump": 0.5,  "tile": 2.0},
	"plaster":   {"color": [0.85, 0.83, 0.79], "rough": 0.93, "metal": 0.0, "bump": 0.2,  "tile": 4.0},
	"marble":    {"color": [0.86, 0.85, 0.82], "rough": 0.25, "metal": 0.0, "bump": 0.1,  "tile": 5.0},
	"wood":      {"color": [0.42, 0.28, 0.16], "rough": 0.7,  "metal": 0.0, "bump": 0.35, "tile": 3.0},
	"timber":    {"color": [0.30, 0.20, 0.12], "rough": 0.75, "metal": 0.0, "bump": 0.4,  "tile": 2.5},
	"metal":     {"color": [0.62, 0.64, 0.68], "rough": 0.35, "metal": 0.9, "bump": 0.12, "tile": 4.0},
	"steel":     {"color": [0.50, 0.52, 0.56], "rough": 0.45, "metal": 0.85,"bump": 0.12, "tile": 4.0},
	"glass":     {"color": [0.30, 0.42, 0.5],  "rough": 0.08, "metal": 0.5, "bump": 0.0,  "tile": 6.0},
	"asphalt":   {"color": [0.12, 0.12, 0.14], "rough": 0.82, "metal": 0.0, "bump": 0.28, "tile": 6.0},
	"sand":      {"color": [0.80, 0.69, 0.47], "rough": 0.97, "metal": 0.0, "bump": 0.55, "tile": 5.0},
	"grass":     {"color": [0.30, 0.48, 0.23], "rough": 1.0,  "metal": 0.0, "bump": 0.45, "tile": 6.0},
	"dirt":      {"color": [0.40, 0.31, 0.22], "rough": 0.98, "metal": 0.0, "bump": 0.5,  "tile": 5.0},
	"thatch":    {"color": [0.66, 0.52, 0.28], "rough": 0.95, "metal": 0.0, "bump": 0.6,  "tile": 2.0},
	"roof_tile": {"color": [0.45, 0.22, 0.18], "rough": 0.7,  "metal": 0.0, "bump": 0.4,  "tile": 1.5},
}

# Per-channel albedo ceiling (see header). Applied ONLY where albedo is resolved (_resolve); never to emission.
const ALBEDO_MAX := 0.85

# Cache: spec-key -> Material (shared across a build so a district reuses materials). Static so it persists
# per game run; cleared implicitly when the game reloads.
static var _cache := {}
static var _palette := Color(1, 1, 1)   # uniform tint applied to every surface() so a build reads art-directed


## Set a uniform palette tint (call once per build from the committed art direction). Clears the cache so
## already-built materials pick it up next request.
static func set_palette(tint: Color) -> void:
	_palette = tint
	_cache.clear()


## A TRIPLANAR surface material — the workhorse. World-triplanar so a tiled procedural-normal relief maps
## correctly onto ANY size/scaled box (no stretch). `spec` = a preset NAME ("sandstone"…) or {color,rough,metal,
## bump,tile}. Cached.
static func surface(spec) -> StandardMaterial3D:
	var key := "S:" + var_to_str(spec)
	if _cache.has(key):
		return _cache[key]
	var p := _resolve(spec)
	var m := StandardMaterial3D.new()
	m.albedo_color = (p["color"] as Color) * _palette
	m.roughness = p["rough"]
	m.metallic = p["metal"]
	# world triplanar -> the normal-relief tiles by WORLD size, identical on a 2m and a 40m wall
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	var t: float = maxf(0.5, p["tile"])
	m.uv1_scale = Vector3(1.0 / t, 1.0 / t, 1.0 / t)
	if p["bump"] > 0.001:
		m.normal_enabled = true
		m.normal_texture = _noise_normal(int(t * 13.0) + int((p["color"] as Color).r * 255.0), p["bump"])
		m.normal_scale = clampf(p["bump"], 0.0, 1.0)
	_cache[key] = m
	return m


## A self-illuminated material (windows-as-glow, neon strips, signage fills). Emissive reads as "lit" at night
## even though Environment glow is off; pair with neon.gd's additive halo for a fake bloom. Cached.
static func emissive(color: Color, energy: float = 1.4) -> StandardMaterial3D:
	var key := "E:%s:%.2f" % [str(color), energy]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	_cache[key] = m
	return m


## An EMISSIVE WINDOW-GRID facade material — a procedurally generated tile of lit window cells on a dark wall,
## applied to a tower/building face so it reads as a populated, night-lit facade (the "tower glows at night, not
## a black block" fix). `cols`/`rows` = windows per tile; `wall` = the wall color; `glow` = window emission color;
## `lit` = emission energy (raise at night). Tiled by the caller's uv1_scale = (floors, bays). Cached by params.
static func window_facade(wall: Color, glow: Color, lit: float = 1.2, cols: int = 4, rows: int = 4) -> StandardMaterial3D:
	var key := "W:%s:%s:%.2f:%d:%d" % [str(wall), str(glow), lit, cols, rows]
	if _cache.has(key):
		return _cache[key]
	var tex := _window_tex(wall * _palette, glow, cols, rows)
	# Emission uses a WINDOW-ONLY mask (black wall texels). Reusing the albedo
	# texture made the WALL emit at `lit` too — light-walled towers rendered as
	# self-glowing white slabs in daylight (the "buildings wash to white in
	# bright sun" bug). Now only window texels glow, day and night.
	var etex := _window_tex(Color(0, 0, 0), glow, cols, rows)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.emission_enabled = true
	m.emission_texture = etex
	m.emission_energy_multiplier = lit
	m.roughness = 0.7
	m.uv1_scale = Vector3(cols, rows, 1.0)   # caller overrides per building via material duplicate if needed
	_cache[key] = m
	return m


## A DECAL quad — a thin textured/colored plane stamped onto a wall or floor for surface detail the geometry
## can't carry: hieroglyph panels, road markings, posters, crosswalks, signage, grime. `size` in metres, faces
## +Z by default (rotate the returned node to lie on the target face); transparent where `tex` is transparent.
## NOTE: a real Decal node is Forward+-only; this alpha-quad is the gl_compatibility-safe equivalent.
static func decal_quad(tex: Texture2D, size: Vector2, emissive_energy: float = 0.0) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	if emissive_energy > 0.0:
		m.emission_enabled = true
		m.emission_texture = tex
		m.emission_energy_multiplier = emissive_energy
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## An emissive sign LIGHT-POOL — a real OmniLight3D color-matched to a neon sign so the sign actually CASTS its
## color onto the wall, street, and people beside it (the single biggest "neon Vegas at night" miss). Budget it:
## the caller caps the count + distance-culls to ~6-8 in the resident ring. Add as a child of the sign/prop.
static func sign_light(color: Color, energy: float = 2.0, light_range: float = 7.0) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = light_range
	l.shadow_enabled = false                 # cheap fill light, no shadow map
	l.light_specular = 0.3
	return l


# ─────────────────────────────── internals ───────────────────────────────

static func _resolve(spec) -> Dictionary:
	var out := {"color": Color(0.6, 0.6, 0.62), "rough": 0.85, "metal": 0.0, "bump": 0.25, "tile": 4.0}
	if typeof(spec) == TYPE_STRING and SURFACES.has(String(spec).to_lower()):
		var pr: Dictionary = SURFACES[String(spec).to_lower()]
		out["color"] = Color(pr["color"][0], pr["color"][1], pr["color"][2])
		out["rough"] = pr["rough"]; out["metal"] = pr["metal"]; out["bump"] = pr["bump"]; out["tile"] = pr["tile"]
	elif typeof(spec) == TYPE_DICTIONARY:
		var d: Dictionary = spec
		var nm := String(d.get("preset", d.get("material", ""))).to_lower()
		if SURFACES.has(nm):
			var pr2: Dictionary = SURFACES[nm]
			out["color"] = Color(pr2["color"][0], pr2["color"][1], pr2["color"][2])
			out["rough"] = pr2["rough"]; out["metal"] = pr2["metal"]; out["bump"] = pr2["bump"]; out["tile"] = pr2["tile"]
		if d.has("color"):
			var c = d["color"]
			out["color"] = Color(c[0], c[1], c[2])
		for k in ["rough", "metal", "bump", "tile"]:
			if d.has(k):
				out[k] = float(d[k])
	# ALBEDO CEILING — near-white albedo can't survive daylight (see header). Albedo only; emission
	# colors (emissive()/window glow/sign_light) never pass through _resolve and stay unclamped.
	var c: Color = out["color"]
	out["color"] = Color(minf(c.r, ALBEDO_MAX), minf(c.g, ALBEDO_MAX), minf(c.b, ALBEDO_MAX), c.a)
	return out


# A tiling, seamless procedural NORMAL map (FastNoiseLite -> NoiseTexture2D as_normal_map). Runtime-generated:
# no asset dependency, works offline / on any build. Shared with the ground system's approach.
static func _noise_normal(seed_i: int, bump: float) -> NoiseTexture2D:
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


# Generate a window-grid tile: `wall`-colored background with a grid of brighter window cells (mullion gaps).
# Called twice per facade: once with the real wall color (albedo) and once with a BLACK background
# (emission mask) so windows glow and the wall genuinely does not.
static func _window_tex(wall: Color, glow: Color, cols: int, rows: int) -> ImageTexture:
	var px := 128
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color(wall.r, wall.g, wall.b, 1.0))
	var cw := float(px) / float(maxi(1, cols))
	var rh := float(px) / float(maxi(1, rows))
	var margin := 0.22   # fraction of a cell that is wall (mullion/frame) around each window
	for cy in rows:
		for cx in cols:
			# slight per-window variation so not every window is identical brightness
			var on := 0.55 + 0.45 * float((cx * 7 + cy * 13) % 5) / 4.0
			var wcol := Color(glow.r * on, glow.g * on, glow.b * on, 1.0)
			var x0 := int((float(cx) + margin) * cw)
			var x1 := int((float(cx) + 1.0 - margin) * cw)
			var y0 := int((float(cy) + margin) * rh)
			var y1 := int((float(cy) + 1.0 - margin) * rh)
			for y in range(y0, y1):
				for x in range(x0, x1):
					img.set_pixel(x, y, wcol)
	return ImageTexture.create_from_image(img)
