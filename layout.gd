class_name GLayout
## LAYOUT — position generators for the ARRANGEMENT axis. Pure 2D math: given a line / perimeter / grid / ring,
## return the cell-local [x,z] POINTS at which to place a repeated part. The chunk streamer instances the part (a
## GShapes shape, a GBuild structure, or a library GLB) at each point and lifts it onto the terrain. This is how
## the agent COMPOSES a place — a colonnade, a fence around a yard, a streetlight row, an avenue of sphinxes, a
## hypostyle hall, a radial plaza — instead of hand-typing every position. The agent picks the GRAMMAR (grid /
## axial-spine / radial / path-aligned / Z-stack) and parameterizes these primitives; there is no per-theme code.

## Evenly-spaced points from `a` to `b` (BOTH ends inclusive), spacing ≈ `spacing`, optional perpendicular jitter.
## The line/row primitive: colonnades, fences, walls, streetlight rows, hedges, an avenue.
static func along(a: Vector2, b: Vector2, spacing: float, jitter := 0.0) -> Array:
	var out: Array = []
	var d := b - a
	var length := d.length()
	if length < 0.001 or spacing <= 0.001:
		out.append(a)
		return out
	var n := maxi(1, int(round(length / spacing)))
	var perp := Vector2(-d.y, d.x).normalized()
	for i in n + 1:
		var p := a.lerp(b, float(i) / float(n))
		if jitter > 0.0:
			p += perp * randf_range(-jitter, jitter)
		out.append(p)
	return out


## Points around the PERIMETER of a rect (centred at origin, half-extents hw×hd), spaced ≈ `spacing`. Corners
## deduped. The ring primitive: a fence around a yard, columns around a court, a wall around a compound.
static func around(hw: float, hd: float, spacing: float) -> Array:
	var out: Array = []
	out += along(Vector2(-hw, -hd), Vector2(hw, -hd), spacing)
	out += along(Vector2(hw, -hd), Vector2(hw, hd), spacing)
	out += along(Vector2(hw, hd), Vector2(-hw, hd), spacing)
	out += along(Vector2(-hw, hd), Vector2(-hw, -hd), spacing)
	return _dedupe(out)


## A regular GRID of points filling a region (centred, half-extents hw×hd), cols×rows. The fill primitive: a
## hypostyle hall of columns, an orchard, a parking lot, a tiled plaza.
static func grid(hw: float, hd: float, cols: int, rows: int, jitter := 0.0) -> Array:
	var out: Array = []
	cols = maxi(1, cols)
	rows = maxi(1, rows)
	for r in rows:
		for c in cols:
			var x := 0.0 if cols == 1 else lerpf(-hw, hw, float(c) / float(cols - 1))
			var z := 0.0 if rows == 1 else lerpf(-hd, hd, float(r) / float(rows - 1))
			if jitter > 0.0:
				x += randf_range(-jitter, jitter)
				z += randf_range(-jitter, jitter)
			out.append(Vector2(x, z))
	return out


## `count` points on a ring (or arc) of `radius`. The radial primitive: a plaza, a fan of statues, a cul-de-sac
## of lots, a stone circle. sweep_deg < 360 makes an arc; start_deg rotates it.
static func radial(radius: float, count: int, start_deg := 0.0, sweep_deg := 360.0) -> Array:
	var out: Array = []
	count = maxi(1, count)
	var closed := absf(sweep_deg) >= 359.9
	var denom := float(count) if closed else float(maxi(1, count - 1))
	for i in count:
		var ang := deg_to_rad(start_deg + sweep_deg * (float(i) / denom))
		out.append(Vector2(cos(ang) * radius, sin(ang) * radius))
	return out


static func _dedupe(pts: Array) -> Array:
	var out: Array = []
	for p in pts:
		var dup := false
		for q in out:
			if (p as Vector2).distance_to(q) < 0.05:
				dup = true
				break
		if not dup:
			out.append(p)
	return out
