#!/usr/bin/env python3
"""Build step for Ashford Green: compile the Mason building specs, post-process the GLBs into
models/, and resolve the MASON:<id> placeholders in world.json into real asset paths + door leaves.

    python3 tools/build_town.py            # full run (compile + wire)
    python3 tools/build_town.py --wire     # skip the Mason compile, only rewrite world.json

Idempotent: world.json is regenerated from tools/world_layout.json (the Architect's layout) +
tools/gameplay.json (director / rules / zones / quests wiring) on every run.
"""
import json, math, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_ID = os.environ.get("BUILD_ID", "cloud-mjvfxf53deudzlkx4zre")
MASON = "/workspace/mason"
PP_DIR = "/tmp/masonpp"   # gltf-transform deps live OUTSIDE the project (never in the export)
OUT = "/tmp/mason-out"


def load(p):
    with open(p) as f:
        return json.load(f)


def ensure_pp():
    os.makedirs(PP_DIR, exist_ok=True)
    if not os.path.isdir(f"{PP_DIR}/node_modules/@gltf-transform"):
        subprocess.run("npm init -y >/dev/null && npm i --silent @gltf-transform/core @gltf-transform/functions @gltf-transform/extensions",
                       shell=True, cwd=PP_DIR, check=True)
    shutil.copyfile(f"{ROOT}/tools/pp.mjs", f"{PP_DIR}/pp.mjs")
    if not os.path.isdir(f"{ROOT}/tools/tex"):
        subprocess.run(["python3", f"{ROOT}/tools/make_textures.py"], check=True)
    shutil.copytree(f"{ROOT}/tools/tex", f"{PP_DIR}/tex", dirs_exist_ok=True)
    return f"{PP_DIR}/pp.mjs"


def compile_structures(spec_path):
    pp = ensure_pp()
    os.makedirs(OUT, exist_ok=True)
    r = subprocess.run([f"{MASON}/.venv/bin/python", f"{MASON}/mason.py", spec_path, OUT], cwd=MASON)
    if r.returncode != 0:
        sys.exit("mason compile failed")
    r = subprocess.run(["node", f"{MASON}/verify_walk.mjs", spec_path, OUT], cwd=MASON)
    if r.returncode != 0:
        sys.exit("mason walk gate failed")
    recs = [json.loads(l) for l in open(f"{OUT}/mason_assets.jsonl")]
    # streamed at runtime over HTTP (never packed): keep them out of Godot's import scan
    os.makedirs(f"{ROOT}/models/town", exist_ok=True)
    open(f"{ROOT}/models/town/.gdignore", "a").close()
    done = {}
    for rec in recs:
        h = rec["hash"]
        if h not in done:
            src = f"{OUT}/{h}.lod0.glb"
            dst = f"{ROOT}/models/town/{rec['id']}.glb"
            subprocess.run(["node", pp, src, dst], check=True, cwd=PP_DIR)
            done[h] = rec["id"]
        elif rec["id"] != done[h]:
            shutil.copyfile(f"{ROOT}/models/town/{done[h]}.glb", f"{ROOT}/models/town/{rec['id']}.glb")
    return recs


def door_of(spec):
    """The ground-level rect opening on the front face -> (centre_offset, width, height) or None."""
    for o in spec.get("openings", []):
        if o.get("face", "s") == "s" and float(o.get("sill", 0)) <= 0.4 and o.get("kind", "rect") == "rect" \
                and float(o.get("h", 0)) >= 2.9 and float(o.get("w", 0)) >= 2.0:
            return float(o.get("centre", 0.0)), float(o["w"]), float(o["h"])
    return None


def sp_footprint(spec):
    w, d = spec["footprint"][:2]
    return float(w), float(d)


def rot_xz(x, z, deg):
    t = math.radians(deg)
    return x * math.cos(t) + z * math.sin(t), -x * math.sin(t) + z * math.cos(t)


def wire(world, specs, cell_size):
    by_id = {s["id"]: s for s in specs["structures"]}
    cells = {tuple(c["cell"]): c for c in world["cells"]}
    half = cell_size / 2.0
    placed = []
    for c in world["cells"]:
        gx, gz = c["cell"]
        cx, cz = gx * cell_size + half, gz * cell_size + half
        entries = []
        if isinstance(c.get("landmark"), dict):
            entries.append(c["landmark"])
        entries += [p for p in c.get("props", []) if isinstance(p, dict)]
        for e in entries:
            u = str(e.get("url", ""))
            if not u.startswith("MASON:"):
                continue
            tid = u[6:]
            if tid not in by_id:
                sys.exit(f"unknown MASON type {tid} in cell {c['cell']}")
            e["url"] = f"/{BUILD_ID}/models/town/{tid}.glb"
            e["collider"] = "mesh_exact"
            # `footprint` marks the record as a BUILDING: the engine applies the Mason GSurf surfaces
            # to the body_/roof_/trim_ solids and draws it across the far ring as skyline.
            e["footprint"] = list(sp_footprint(by_id[tid]))
            px, pz = (e.get("pos") or [0, 0])[:2]
            rot = float(e.get("rot", 0.0))
            placed.append({"type": tid, "cell": [gx, gz], "world": [cx + px, cz + pz], "rot": rot})
    # door leaves: one hinged, USE-openable door per rect front doorway. interaction.add_door sizes
    # the leaf from w/h and hangs it hinge-at-pivot extending +X, so the hinge sits half a doorway
    # from the opening's centre.
    for p in placed:
        sp = by_id[p["type"]]
        d = door_of(sp)
        if d is None:
            continue
        off, w, h = d
        depth = float(sp["footprint"][1])
        wall_t = float(sp.get("wall_t", 0.35))
        # door centre in Godot space at rot 0: (off, -depth/2) -- the front face is -Z; the leaf
        # hangs at mid-wall so it sits INSIDE the opening's reveal instead of half proud of the facade
        dx, dz = rot_xz(off, -(depth / 2.0 - wall_t / 2.0), p["rot"])
        wx, wz = p["world"][0] + dx, p["world"][1] + dz
        ldx, ldz = rot_xz(1.0, 0.0, p["rot"])          # the leaf runs along the wall (+X local)
        hx, hz = wx - (w / 2.0) * ldx, wz - (w / 2.0) * ldz
        # register the door in the cell that CONTAINS the hinge so the +-(half-1) clamp never bites
        cgx, cgz = math.floor(hx / cell_size), math.floor(hz / cell_size)
        cell = cells.get((cgx, cgz))
        if cell is None:
            sys.exit(f"door of {p['type']} at {hx:.1f},{hz:.1f} falls outside the grid")
        ccx, ccz = cgx * cell_size + half, cgz * cell_size + half
        label = {"town_hall": "Town Hall Door"}.get(p["type"], "Door")
        cell.setdefault("doors", []).append({
            "id": f"door_{p['type']}_{len(cell.get('doors', []))}_{cgx}_{cgz}",
            "pos": [round(hx - ccx, 3), round(hz - ccz, 3)],
            "facing": p["rot"], "label": label, "w": w, "h": h})
        p["door_world"] = [round(wx, 2), round(wz, 2)]
    # BALUSTRADE along each stair flight's open edge: a thin timber wall from the floor up through the
    # stairwell cutout (guards the upper-floor opening too). The engine's step-up probe reads the floor
    # 0.6 m ahead of the player's CENTRE, so a player straddling the flight's edge would wedge on the
    # riser corner; the wall keeps them on the treads.
    for p in placed:
        sp = by_id[p["type"]]
        st = (sp.get("interior") or {}).get("stair") if isinstance(sp.get("interior"), dict) else None
        if not st:
            continue
        sw, run = float(st["width"]), float(st["run"])
        ex = float(st["cx"]) - sw / 2.0 - 0.07             # open (room-side) edge, model +X = wall side
        cz = -float(st.get("cy", 0.0))                     # model +Y (front) -> Godot -Z
        lx, lz = rot_xz(ex, cz, p["rot"])
        wx, wz = p["world"][0] + lx, p["world"][1] + lz
        cgx, cgz = math.floor(wx / cell_size), math.floor(wz / cell_size)
        cell = cells.get((cgx, cgz))
        if cell is None:
            continue
        ccx, ccz = cgx * cell_size + half, cgz * cell_size + half
        cell.setdefault("rows", []).append({
            "part": {"shape": "box", "size": [0.12, 4.6, round(run + 0.3, 2)], "material": "timber",
                     "collider": "box", "rot": p["rot"]},
            "from": [round(wx - ccx, 3), round(wz - ccz, 3)], "to": [round(wx - ccx, 3), round(wz - ccz, 3)], "spacing": 1})
    return placed


def rewrite_meshy_paths(node):
    """/<build>/models/<name>.glb -> /<build>/models/meshy/<name>.glb when the character lives in the
    gdignored models/meshy/ folder (streamed, never packed into index.pck)."""
    if isinstance(node, dict):
        for k, v in node.items():
            node[k] = rewrite_meshy_paths(v)
        return node
    if isinstance(node, list):
        return [rewrite_meshy_paths(v) for v in node]
    if isinstance(node, str) and node.startswith("/") and "/models/" in node and node.endswith(".glb"):
        name = node.rsplit("/", 1)[1]
        if os.path.exists(f"{ROOT}/models/meshy/{name}") and "/models/meshy/" not in node:
            return f"/{BUILD_ID}/models/meshy/{name}"
    return node


def main():
    do_compile = "--wire" not in sys.argv
    specs = load(f"{ROOT}/structures.json")
    if do_compile:
        compile_structures(f"{ROOT}/structures.json")
    world = load(f"{ROOT}/tools/world_layout.json")
    gameplay = load(f"{ROOT}/tools/gameplay.json")
    cell_size = float(world.get("grid", {}).get("cell_size", 16))
    placed = wire(world, specs, cell_size)
    world = rewrite_meshy_paths(world)
    for k, v in gameplay.items():
        world[k] = v
    with open(f"{ROOT}/world.json", "w") as f:
        json.dump(world, f, indent=1)
    with open(f"{ROOT}/tools/placements.json", "w") as f:
        json.dump(placed, f, indent=1)
    print(f"wired {len(placed)} Mason buildings, {sum(1 for p in placed if 'door_world' in p)} door leaves -> world.json")


if __name__ == "__main__":
    main()
