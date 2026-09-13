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
DOOR_LEAF_HALF = 1.1        # interaction.add_door hangs a 2.2 x 3.0 leaf, hinge at the pivot, extending +X


def load(p):
    with open(p) as f:
        return json.load(f)


def ensure_pp():
    os.makedirs(PP_DIR, exist_ok=True)
    if not os.path.isdir(f"{PP_DIR}/node_modules/@gltf-transform"):
        subprocess.run("npm init -y >/dev/null && npm i --silent @gltf-transform/core @gltf-transform/functions @gltf-transform/extensions",
                       shell=True, cwd=PP_DIR, check=True)
    shutil.copyfile(f"{ROOT}/tools/pp.mjs", f"{PP_DIR}/pp.mjs")
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
    os.makedirs(f"{ROOT}/models", exist_ok=True)
    done = {}
    for rec in recs:
        h = rec["hash"]
        if h not in done:
            src = f"{OUT}/{h}.lod0.glb"
            dst = f"{ROOT}/models/{rec['id']}.glb"
            subprocess.run(["node", pp, src, dst], check=True, cwd=PP_DIR)
            done[h] = rec["id"]
        elif rec["id"] != done[h]:
            shutil.copyfile(f"{ROOT}/models/{done[h]}.glb", f"{ROOT}/models/{rec['id']}.glb")
    return recs


def door_of(spec):
    """The ground-level rect opening on the front face -> (centre_offset, width, height) or None."""
    for o in spec.get("openings", []):
        if o.get("face", "s") == "s" and float(o.get("sill", 0)) <= 0.4 and o.get("kind", "rect") == "rect" \
                and float(o.get("h", 0)) >= 2.9 and float(o.get("w", 0)) >= 2.0:
            return float(o.get("centre", 0.0)), float(o["w"]), float(o["h"])
    return None


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
            e["url"] = f"/{BUILD_ID}/models/{tid}.glb"
            e["collider"] = "mesh_exact"
            px, pz = (e.get("pos") or [0, 0])[:2]
            rot = float(e.get("rot", 0.0))
            placed.append({"type": tid, "cell": [gx, gz], "world": [cx + px, cz + pz], "rot": rot})
    # door leaves: one hinged, USE-openable door per rect front doorway
    for p in placed:
        sp = by_id[p["type"]]
        d = door_of(sp)
        if d is None:
            continue
        off, w, h = d
        depth = float(sp["footprint"][1])
        # door centre in Godot space at rot 0: (off, -depth/2) -- front face is -Z
        dx, dz = rot_xz(off, -depth / 2.0, p["rot"])
        wx, wz = p["world"][0] + dx, p["world"][1] + dz
        ldx, ldz = rot_xz(1.0, 0.0, p["rot"])          # the leaf runs along the wall (+X local)
        hx, hz = wx - DOOR_LEAF_HALF * ldx, wz - DOOR_LEAF_HALF * ldz
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
            "facing": p["rot"], "label": label})
        p["door_world"] = [round(wx, 2), round(wz, 2)]
    return placed


def main():
    do_compile = "--wire" not in sys.argv
    specs = load(f"{ROOT}/structures.json")
    if do_compile:
        compile_structures(f"{ROOT}/structures.json")
    world = load(f"{ROOT}/tools/world_layout.json")
    gameplay = load(f"{ROOT}/tools/gameplay.json")
    cell_size = float(world.get("grid", {}).get("cell_size", 16))
    placed = wire(world, specs, cell_size)
    for k, v in gameplay.items():
        world[k] = v
    with open(f"{ROOT}/world.json", "w") as f:
        json.dump(world, f, indent=1)
    with open(f"{ROOT}/tools/placements.json", "w") as f:
        json.dump(placed, f, indent=1)
    print(f"wired {len(placed)} Mason buildings, {sum(1 for p in placed if 'door_world' in p)} door leaves -> world.json")


if __name__ == "__main__":
    main()
