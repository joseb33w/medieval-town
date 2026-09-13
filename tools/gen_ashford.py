#!/usr/bin/env python3
"""Generator for Ashford Green — a 7x7 chunk-mode medieval town (world.json).
Run:  python3 gen_ashford.py  -> writes /workspace/world.json and prints a placement report.
All positions are CELL-LOCAL [x,z] (metres from the cell centre); +Z = SOUTH, -Z = NORTH.
A Mason building at rot 0 has its front (door) facing -Z (north); rot 180 -> door faces +Z (south);
rot 90 -> door faces -X (west); rot -90 -> door faces +X (east).
"""
import json, itertools, math

CELL = 20.0
OUT = "/workspace/world.json"

CLOUD = "/cloud-mjvfxf53deudzlkx4zre/models/"
VILLAGER = CLOUD + "villager_man.glb"
MARKET_W = CLOUD + "market_woman.glb"
GUARD = CLOUD + "guard.glb"
STEWARD = CLOUD + "steward.glb"
SMITH = CLOUD + "blacksmith.glb"
HERO = CLOUD + "traveler.glb"

# ---- Mason building catalogue: width (X at rot 0), depth (Z at rot 0), door offset along the front ----
MASON = {
    "town_hall": (12.0, 9.0, 0.0),
    "house_a": (7.0, 6.0, 0.0),
    "house_b": (8.0, 6.5, -2.0),
    "house_c": (6.0, 5.5, 0.0),
    "house_d": (6.5, 8.0, 0.0),
    "tavern": (10.0, 8.0, -2.5),
    "chapel": (7.0, 12.0, 0.0),
}

# ---- prop groups (verified against the live manifest) ----
G = {
    # mod_village
    "Prop_Well_1": "mod_village", "Prop_Cart_1_Barrels": "mod_village", "Prop_Cart_1_Hay": "mod_village",
    "Prop_Lamp_Street": "mod_village", "Prop_Barrel_1": "mod_village", "Prop_Barrel_2": "mod_village",
    "Prop_Crate_1": "mod_village", "Prop_Hay_1": "mod_village", "Canopy_Full": "mod_village",
    "Wood_Railing_Straight": "mod_village", "Stone_Wall_1": "mod_village", "Stone_Wall_2": "mod_village",
    "Stone_Wall_3": "mod_village",
    # mega_fantasy
    "Stall_Empty": "mega_fantasy", "Stall_Cart_Empty": "mega_fantasy", "Bench": "mega_fantasy",
    "Barrel_Apples": "mega_fantasy", "Crate_Wooden": "mega_fantasy", "Banner_1": "mega_fantasy",
    "Cage_Small": "mega_fantasy", "Workbench": "mega_fantasy", "Anvil": "mega_fantasy", "Dummy": "mega_fantasy",
    # mega_medieval
    "Prop_Wagon": "mega_medieval", "Prop_WoodenFence_Single": "mega_medieval",
    "Prop_WoodenFence_Extension1": "mega_medieval",
    # q_farmbuild
    "Windmill": "q_farmbuild", "Fence": "q_farmbuild", "SmallBarn": "q_farmbuild", "OpenBarn": "q_farmbuild",
    # q_unature
    **{f"CommonTree_{i}": "q_unature" for i in range(1, 6)},
    **{f"BirchTree_{i}": "q_unature" for i in range(1, 6)},
    **{f"PineTree_{i}": "q_unature" for i in range(1, 6)},
    **{f"Rock_{i}": "q_unature" for i in range(1, 8)},
    **{f"Rock_Moss_{i}": "q_unature" for i in range(1, 8)},
    "Bush_1": "q_unature", "Bush_2": "q_unature", "BushBerries_1": "q_unature",
    "Grass": "q_unature", "Grass_2": "q_unature", "Flowers": "q_unature", "Wheat": "q_unature",
    # mega_nature
    "Grass_Common_Tall": "mega_nature", "Flower_3_Group": "mega_nature", "Bush_Common": "mega_nature",
}
def U(pid):
    return f"props/{G[pid]}/{pid}.glb"

TREE_SCALE = 2.2   # Quaternius trees are ~2.5-3.5 m at 1.0 -> 5.5-7.5 m next to 6-10 m houses
LAMP_SCALE = 2.0   # Prop_Lamp_Street is 1.25 m at 1.0 -> 2.5 m post lamp

# cobble is a GROUND preset but not a GSurf part material -> explicit surface dict for lane strips
COBBLE_MAT = {"color": [0.42, 0.41, 0.43], "rough": 0.80, "bump": 0.65, "tile": 1.2}
DIRT_MAT = "dirt"

# ---------------------------------------------------------------- helpers
def P(pid, x, z, rot=None, scale=None, sit=False, collider=None):
    d = {"url": U(pid), "pos": [round(x, 2), round(z, 2)]}
    if rot is not None:
        d["rot"] = rot
    if scale is not None:
        d["scale"] = scale
    if sit:
        d["sit"] = True
    if collider is not None:
        d["collider"] = collider
    return d

def tree(pid, x, z, rot=None):
    return P(pid, x, z, rot=rot, scale=TREE_SCALE)

def lamp(x, z, rot=None):
    return P("Prop_Lamp_Street", x, z, rot=rot, scale=LAMP_SCALE)

def bench(x, z, rot=0):
    return P("Bench", x, z, rot=rot, sit=True)

def M(mtype, x, z, rot):
    return {"url": f"MASON:{mtype}", "pos": [round(x, 2), round(z, 2)], "rot": rot, "collider": "mesh_exact"}

# lane strips: boxes tile the lane exactly (4 m along the lane, 3.5 m wide, spacing 4) -> no coplanar overlap
def lane_ew(x0, x1, mat=COBBLE_MAT):
    return {"part": {"shape": "box", "size": [4.0, 0.06, 3.5], "material": mat, "collider": "none"},
            "from": [x0, 0], "to": [x1, 0], "spacing": 4.0}

def lane_ns(z0, z1, mat=COBBLE_MAT):
    return {"part": {"shape": "box", "size": [3.5, 0.06, 4.0], "material": mat, "collider": "none"},
            "from": [0, z0], "to": [0, z1], "spacing": 4.0}

EW_FULL = lambda mat=COBBLE_MAT: lane_ew(-8, 8, mat)
NS_FULL = lambda mat=COBBLE_MAT: lane_ns(-8, 8, mat)
NS_NORTH_HALF = lambda mat=COBBLE_MAT: lane_ns(-8, -4, mat)   # T/cross: skip the centre box (owned by the E-W row)
NS_SOUTH_HALF = lambda mat=COBBLE_MAT: lane_ns(4, 8, mat)
EW_WEST_HALF = lambda mat=COBBLE_MAT: lane_ew(-8, -4, mat)
EW_EAST_HALF = lambda mat=COBBLE_MAT: lane_ew(4, 8, mat)

# fences / walls as rows.  Prop_WoodenFence_Single is 2.06 m along X (rot 0); Stone_Wall_1 is 1.0 m along Z (rot 0)
def fence_x(x0, x1, z):                       # wooden fence running E-W
    return {"part": {"url": U("Prop_WoodenFence_Single")}, "from": [x0, z], "to": [x1, z], "spacing": 2.06}
def fence_z(z0, z1, x):                       # wooden fence running N-S
    return {"part": {"url": U("Prop_WoodenFence_Single"), "rot": 90}, "from": [x, z0], "to": [x, z1], "spacing": 2.06}
def wall_x(x0, x1, z, pid="Stone_Wall_1"):    # stone wall running E-W (module is along Z -> rot 90)
    return {"part": {"url": U(pid), "rot": 90}, "from": [x0, z], "to": [x1, z], "spacing": 1.0}
def wall_z(z0, z1, x, pid="Stone_Wall_1"):    # stone wall running N-S
    return {"part": {"url": U(pid)}, "from": [x, z0], "to": [x, z1], "spacing": 1.0}
def farmfence_x(x0, x1, z):                   # q_farmbuild Fence, 5.9 m along X
    return {"part": {"url": U("Fence")}, "from": [x0, z], "to": [x1, z], "spacing": 5.9}
def farmfence_z(z0, z1, x):
    return {"part": {"url": U("Fence"), "rot": 90}, "from": [x, z0], "to": [x, z1], "spacing": 5.9}
def wheat_row(x0, x1, z):
    return {"part": {"url": U("Wheat"), "collider": "none"}, "from": [x0, z], "to": [x1, z], "spacing": 0.9, "jitter": 0.15}
def wheat_col(z0, z1, x):
    return {"part": {"url": U("Wheat"), "collider": "none"}, "from": [x, z0], "to": [x, z1], "spacing": 0.9, "jitter": 0.15}
def orchard_row(pid, x0, x1, z):
    return {"part": {"url": U(pid)}, "from": [x0, z], "to": [x1, z], "spacing": 4.0, "jitter": 0.4}

def S(pid, count, collider=None):
    d = {"url": U(pid), "count": count}
    if collider is not None:
        d["collider"] = collider
    return d

def crowd(count, radius=5, speed=1.2):
    return {"set": [VILLAGER, MARKET_W], "count": count, "vary": True, "behaviour": "wander",
            "radius": radius, "speed": speed}

# ---------------------------------------------------------------- the cells
cells = {}
def cell(gx, gz, ground, **kw):
    rec = {"cell": [gx, gz], "ground": ground}
    for k, v in kw.items():
        if v:
            rec[k] = v
    cells[(gx, gz)] = rec
    return rec

# ===== [0,0] TOWN HALL block (cobble) — the landmark; door faces SOUTH (+Z) onto the plaza =====
cell(0, 0, "cobble",
     landmark={"url": "MASON:town_hall", "pos": [0, 0], "rot": 180, "collider": "mesh_exact"},
     props=[
         P("Prop_Well_1", 7.5, 7.5),
         lamp(-3.5, 7.5), lamp(4.5, 7.5),
         P("Banner_1", -5.0, 5.6, rot=0), P("Banner_1", 5.2, 5.6, rot=0),
         P("Stall_Empty", -7.5, 7.5, rot=90),
         P("Prop_Barrel_1", -8.6, 5.6), P("Crate_Wooden", -8.6, 9.0),
         bench(-8.2, 0.0, rot=90), bench(8.2, -2.0, rot=90),
         tree("CommonTree_3", -6.0, -7.5), tree("CommonTree_1", 6.0, -7.5),
     ],
     npc={"id": "steward", "name": "Steward Aldric", "pos": [2.5, 6.5], "model": STEWARD,
          "persona": "Aldric, the steward of Ashford Green's town hall. Proud of the new council chamber upstairs. Warm, a little pompous, two short sentences max.",
          "lines": ["Steward Aldric: Welcome to Ashford Green, traveller.",
                    "Steward Aldric: The council chamber is upstairs in the hall - the door is open to visitors."]})

# ===== [0,1] PLAZA / spawn (cobble) — High Street E-W + South Road leaving south =====
cell(0, 1, "cobble",
     rows=[EW_FULL(), NS_SOUTH_HALF()],
     props=[
         P("Stall_Empty", -6.5, -3.5, rot=0), P("Stall_Cart_Empty", 6.5, -3.5, rot=0),
         P("Canopy_Full", -6.5, 4.0, scale=2.5),
         P("Barrel_Apples", 5.0, -5.3), P("Crate_Wooden", -4.6, -5.4), P("Prop_Crate_1", -8.6, 6.2),
         lamp(-3.0, 5.5), lamp(3.0, 5.5),
         bench(7.0, 5.5), bench(-7.0, 8.6),
         P("Prop_Cart_1_Barrels", 7.5, 8.0, rot=90),
         P("Prop_Hay_1", 8.8, -7.5),
     ],
     populate=[crowd(4, radius=6, speed=1.2)],
     npc={"id": "greta", "name": "Greta", "pos": [-4.8, -3.0], "model": MARKET_W,
          "persona": "Greta, a cheerful market woman selling apples and bread on the plaza of Ashford Green. Chatty and kind, always trying to sell you something. Two short sentences max.",
          "lines": ["Greta: Apples fresh from the orchard, traveller - two for a copper!",
                    "Greta: If you're looking for the steward, he's by the hall door as always."]})

# ===== [-1,1] West Lane x High Street crossroads (cobble) =====
cell(-1, 1, "cobble",
     rows=[EW_FULL(), NS_NORTH_HALF(), NS_SOUTH_HALF(), fence_x(-9.0, -3.0, 9.3)],
     props=[
         M("house_b", 6.0, -6.65, 180),      # NE, door faces south onto High Street (door at x=+8)
         M("house_c", -6.15, -6.0, -90),     # NW, door faces east onto West Lane
         lamp(2.5, 2.5), tree("CommonTree_2", -6.0, 6.0), bench(-6.0, 3.2),
         P("Prop_Cart_1_Hay", 6.5, 6.5, rot=0), P("Prop_Barrel_2", 9.0, -2.6), P("Prop_Crate_1", 2.3, -2.9),
         P("Bush_1", -8.5, 8.5), P("BushBerries_1", -3.5, 8.5),
     ],
     scatter=[S("Flowers", 10), S("Grass", 10)])

# ===== [1,1] East Lane x High Street crossroads (cobble) =====
cell(1, 1, "cobble",
     rows=[EW_FULL(), NS_NORTH_HALF(), NS_SOUTH_HALF(), fence_z(3.0, 9.0, 9.3)],
     props=[
         M("house_d", -5.5, 7.4, 0),         # SW, gable end + door face north onto High Street
         M("house_c", 6.0, -6.15, 180),      # NE, door faces south
         lamp(-2.6, -2.6), tree("CommonTree_5", -6.0, -6.0), bench(-6.0, -2.8),
         P("Prop_Wagon", 6.5, 6.5, rot=0), P("Prop_Hay_1", 8.5, 8.8), P("Prop_Barrel_1", 9.0, -2.6),
         P("Bush_2", -8.8, -8.8),
     ],
     scatter=[S("Flowers", 10), S("Grass_2", 10)],
     populate=[crowd(2, radius=5)])

# ===== [-2,1] High Street west (cobble) =====
cell(-2, 1, "cobble",
     rows=[EW_FULL(), fence_x(2.5, 8.7, -9.3), fence_z(-8.0, -4.0, 9.3)],
     props=[
         M("house_a", -5.5, -6.4, 180),      # N side, door faces south
         M("house_d", -3.0, 7.4, 0),         # S side, door faces north (back pokes 1.4 m into [-2,2] - kept clear)
         lamp(2.0, -2.6), tree("BirchTree_2", 6.0, -6.5), tree("BirchTree_4", 3.2, -8.6),
         P("Prop_Cart_1_Hay", 6.0, 6.5, rot=0), P("Prop_Barrel_2", -7.0, 2.6), P("Prop_Crate_1", -8.2, 2.7),
         bench(5.5, 2.6), P("Bush_1", 8.8, -8.8),
     ],
     scatter=[S("Flowers", 12), S("Grass", 8)])

# ===== [2,1] High Street east — TAVERN (cobble) =====
cell(2, 1, "cobble",
     rows=[EW_FULL()],
     props=[
         M("tavern", 0.0, -7.4, 180),        # N side, door faces south (door offset -2.5 -> door at x=+2.5)
         M("house_a", 5.0, 6.4, 0),          # S side east, door faces north
         lamp(5.0, -2.6), bench(-2.5, -2.6), tree("BirchTree_3", -6.0, 6.5), P("Prop_Cart_1_Hay", -6.0, 3.0, rot=90),
         P("Prop_Barrel_1", -4.6, -2.7), P("Prop_Barrel_2", -5.6, -2.7), P("Prop_Crate_1", 7.2, -3.0),
         tree("CommonTree_4", 7.6, -7.0), P("Prop_Hay_1", -0.8, 8.6),
     ],
     chest={"pos": [-3.5, -6.5], "contents": ["potion"], "gold": 20},   # inside the tavern, west end
     scatter=[S("Flowers", 10), S("Grass", 8)])

# ===== [-1,0] West Lane (N-S) + Chapel Lane heading west (dirt) =====
cell(-1, 0, "dirt",
     rows=[NS_FULL(), EW_WEST_HALF(), fence_z(2.5, 9.0, -9.3)],
     props=[
         M("house_b", 6.65, -5.0, 90),       # E side, door faces west onto West Lane
         tree("CommonTree_4", 6.5, 6.5), P("Prop_Hay_1", 4.0, 3.5),
         tree("BirchTree_1", -6.0, -6.0), bench(-6.0, -2.8), P("Bush_1", -8.5, -8.5),
         P("Prop_Cart_1_Barrels", -6.0, 6.0, rot=0), lamp(2.4, 1.5), P("Prop_Barrel_1", 2.6, -7.5),
         tree("CommonTree_2", -3.5, 8.2),
     ],
     scatter=[S("Flowers", 10), S("Grass", 10)],
     populate=[crowd(2, radius=5)])

# ===== [1,0] East Lane (N-S) + Forge Lane heading east (dirt) =====
cell(1, 0, "dirt",
     rows=[NS_FULL(), EW_EAST_HALF(), fence_x(3.0, 9.0, -9.3)],
     props=[
         M("house_c", -6.15, -5.5, -90),     # W side, door faces east onto East Lane
         tree("CommonTree_1", -7.5, 8.5), P("Prop_Cart_1_Hay", -6.0, 4.5, rot=0),
         tree("BirchTree_3", 6.0, -6.0), tree("BirchTree_5", 8.0, -8.6),
         bench(6.0, 3.0), lamp(2.5, -2.5), P("Prop_Barrel_2", -2.6, -8.0), P("Bush_2", 8.5, 8.5),
     ],
     scatter=[S("Flowers", 10), S("Grass", 10)])

# ===== [-2,0] CHAPEL + walled churchyard (dirt) =====
cell(-2, 0, "dirt",
     rows=[{"part": {"shape": "box", "size": [4.0, 0.06, 3.5], "material": COBBLE_MAT, "collider": "none"},
            "from": [8, 0], "to": [8, 0], "spacing": 4.0},          # lane end box (x 6..10) -> 2 m to the door
           wall_x(-9.3, 9.3, 9.3), wall_x(-9.3, 9.3, -9.3), wall_z(-9.3, 9.3, -9.3)],
     props=[
         M("chapel", -2.0, 0.0, -90),        # door faces east (+X) toward the lane
         lamp(5.5, 2.5), lamp(5.5, -2.5), bench(6.5, 5.5), bench(6.5, -5.5),
         tree("BirchTree_1", -6.0, 7.0), tree("BirchTree_3", 2.0, 7.0),
         tree("BirchTree_2", -6.0, -7.0), tree("BirchTree_5", 2.0, -7.0),
         P("Bush_1", 8.5, 8.0), P("BushBerries_1", 8.5, -8.0),
     ],
     scatter=[S("Flowers", 14), S("Grass", 12)])

# ===== [2,0] FORGE yard (dirt) =====
cell(2, 0, "dirt",
     rows=[EW_WEST_HALF(), fence_z(-9.0, 8.0, 9.3), fence_x(1.0, 9.0, -9.3)],
     props=[
         M("house_c", -5.0, -6.15, 180),     # smith's cottage, door faces south onto Forge Lane
         P("Anvil", 2.8, -2.4, rot=0), P("Workbench", 4.8, -3.2, rot=0), P("Dummy", 6.5, 4.0),
         P("Cage_Small", 5.2, -8.3), P("Prop_Barrel_1", 6.5, -7.5), P("Prop_Crate_1", 7.8, -6.3),
         P("Prop_Cart_1_Barrels", 2.0, 6.5, rot=90), lamp(-2.5, 2.5), P("Prop_Hay_1", -6.0, 5.0),
     ],
     npc={"id": "blacksmith", "name": "Marta the Smith", "pos": [1.5, -1.0], "model": SMITH,
          "persona": "Marta, the blacksmith of Ashford Green, working an open-air forge at the end of Forge Lane. Blunt, good-humoured, proud of her hinges on the town hall doors. Two short sentences max.",
          "lines": ["Marta the Smith: Mind the anvil, it's hotter than it looks.",
                    "Marta the Smith: Every hinge on the town hall doors is mine - go try them."]},
     scatter=[S("Grass", 10), S("Rock_1", 6), S("Flowers", 8)])

# ===== [0,-1] Back Lane + North Road T (dirt) — the hall's back garden is the south half =====
cell(0, -1, "dirt",
     rows=[EW_FULL(), NS_NORTH_HALF(), fence_x(-8.0, 8.0, 9.3)],
     props=[
         M("house_a", -6.4, -6.5, -90),      # NW, door faces east onto North Road (back pokes 0.5 m into [0,-2])
         M("house_c", 6.15, -6.5, 90),       # NE, door faces west onto North Road
         tree("CommonTree_2", -6.0, 6.8), tree("CommonTree_4", 6.0, 6.8), bench(0.0, 4.5),
         lamp(2.5, -2.5), lamp(-2.5, 2.5), P("Prop_Wagon", -5.5, 3.2, rot=90),
         P("Bush_1", 8.8, 8.8), P("Prop_Hay_1", 7.5, 3.0),
     ],
     scatter=[S("Flowers", 12), S("Grass", 10)])

# ===== [-1,-1] Back Lane + West Lane T (dirt) =====
cell(-1, -1, "dirt",
     rows=[EW_FULL(), NS_SOUTH_HALF(), fence_z(3.0, 9.0, 9.3)],
     props=[
         M("house_b", -5.0, -6.65, 180),     # N side, door faces south (door at x=-3)
         M("house_a", -5.5, 6.4, 0),         # SW, door faces north
         P("Prop_Cart_1_Hay", 5.5, -6.5, rot=0), tree("CommonTree_3", 8.3, -8.3),
         bench(5.5, 3.0), lamp(2.5, 2.5), P("BushBerries_1", 7.5, 7.5),
         P("Prop_Barrel_2", -8.6, -2.8), P("Prop_Crate_1", 2.5, -2.8),
     ],
     scatter=[S("Flowers", 10), S("Grass", 10)])

# ===== [1,-1] Back Lane + East Lane T (dirt) =====
cell(1, -1, "dirt",
     rows=[EW_FULL(), NS_SOUTH_HALF(), fence_x(3.0, 9.0, -9.3), fence_z(-9.0, -3.0, 9.3)],
     props=[
         M("house_d", -5.0, -7.4, 180),      # N side, gable to the lane, door faces south (back pokes 1.4 m into [1,-2])
         tree("BirchTree_4", 6.0, -6.0), P("Bush_1", 8.5, -8.5),
         P("Prop_Wagon", -6.0, 6.0, rot=0), tree("CommonTree_5", -8.3, 8.6),
         bench(5.5, 3.0), lamp(-2.4, -2.6), P("Prop_Hay_1", 6.5, 6.5), P("Prop_Barrel_1", 8.8, 3.0),
     ],
     scatter=[S("Flowers", 10), S("Grass_2", 10)])

# ===== [-2,-1] Back Lane west + vegetable garden (dirt) =====
cell(-2, -1, "dirt",
     rows=[EW_FULL(), wheat_row(-8, 8, -8.0), wheat_row(-8, 8, -5.5), fence_x(-8.0, 8.0, -3.0)],
     props=[
         M("house_c", 4.5, 6.15, 0),         # S side, door faces north onto Back Lane
         P("Prop_Cart_1_Hay", -5.5, 6.0, rot=0), tree("CommonTree_1", -8.0, 8.2), lamp(2.0, 2.6),
         P("Prop_Barrel_2", 8.3, 3.0), P("Bush_1", -2.0, 8.6), P("Rock_Moss_1", 8.5, 8.5),
         P("Prop_Hay_1", -8.5, 3.0), P("BushBerries_1", 8.6, -8.6),
     ],
     scatter=[S("Flowers", 10), S("Grass", 12)])

# ===== [2,-1] Back Lane east — hay paddock N, orchard green S (dirt) =====
cell(2, -1, "dirt",
     rows=[EW_FULL(), fence_x(-8.0, 8.0, -3.0), fence_x(-8.0, 8.0, -9.3),
           fence_z(-9.0, -3.0, -9.3), fence_z(-9.0, -3.0, 9.3)],
     props=[
         P("Prop_Cart_1_Hay", 4.0, -6.0, rot=0), P("Prop_Hay_1", -4.0, -6.0), P("Prop_Hay_1", -6.0, -7.5),
         P("Prop_Barrel_1", 7.5, -8.0), tree("CommonTree_2", -7.0, -7.0),
         tree("CommonTree_3", -6.0, 6.0), tree("CommonTree_4", 0.0, 7.5), tree("CommonTree_1", 6.0, 6.0),
         bench(3.0, 3.0), lamp(-2.5, 2.5), P("Bush_2", 8.5, 8.5),
     ],
     scatter=[S("Grass", 14), S("Flowers", 10)])

# ===== [0,-2] North Road (cobble) =====
cell(0, -2, "cobble",
     rows=[NS_FULL(), fence_z(-8.0, 8.0, -9.3)],
     props=[
         M("house_a", 6.4, -2.0, 90),        # E side, door faces west onto North Road
         P("Prop_Cart_1_Barrels", -5.5, -5.0, rot=0), tree("CommonTree_2", -6.5, 4.0), bench(-4.0, 0.0, rot=90),
         lamp(2.5, 3.5), lamp(-2.5, -6.5), P("Prop_Barrel_2", 8.8, 2.8), P("Bush_1", 7.0, 6.5),
         P("Prop_Crate_1", -8.5, -8.5), tree("BirchTree_1", 7.0, -8.0),
     ],
     scatter=[S("Flowers", 10), S("Grass", 10)],
     populate=[crowd(2, radius=5)])

# ===== [0,2] South Road (cobble) =====
cell(0, 2, "cobble",
     rows=[NS_FULL(), fence_z(-8.0, 8.0, 9.3)],
     props=[
         M("house_b", -6.65, 3.0, -90),      # W side, door faces east onto South Road (door at z=+1)
         tree("CommonTree_3", 6.0, -6.0), P("Prop_Wagon", 6.5, 3.0, rot=0), bench(5.5, 7.5),
         lamp(2.5, -4.0), lamp(-2.5, 6.5), P("Prop_Barrel_1", -8.8, -4.0), P("Bush_2", 8.8, 8.8),
         P("Prop_Hay_1", 8.5, -1.5), P("Prop_Crate_1", -6.0, -5.0),
     ],
     scatter=[S("Flowers", 10), S("Grass", 10)])

# ===== [-1,2] West Lane south — vegetable garden W, orchard E (dirt) =====
cell(-1, 2, "dirt",
     rows=[NS_FULL(), wheat_col(-8, 8, -7.5), wheat_col(-8, 8, -5.0), fence_z(-8.0, 8.0, -2.6)],
     props=[
         tree("CommonTree_1", 5.0, -6.0), tree("CommonTree_4", 5.5, 0.5), tree("CommonTree_2", 5.0, 6.5),
         tree("BirchTree_3", 8.6, -3.0), P("Prop_Cart_1_Hay", 3.5, 8.0, rot=0), P("Prop_Hay_1", 8.6, 8.6),
         lamp(2.5, -8.0), bench(3.5, -8.6), P("Rock_Moss_2", 8.6, 3.5),
     ],
     scatter=[S("Grass", 14), S("Flowers", 12)])

# ===== [1,2] East Lane south — orchard W, hay paddock E (dirt) =====
cell(1, 2, "dirt",
     rows=[NS_FULL(), fence_x(3.0, 9.0, -3.0), fence_x(3.0, 9.0, 9.3), fence_z(-3.0, 9.0, 9.3)],
     props=[
         tree("CommonTree_5", -6.0, -4.0), tree("CommonTree_3", -6.0, 3.0), tree("BirchTree_2", -4.0, 8.0),
         P("Bush_1", -8.5, -1.0), P("Prop_Hay_1", 6.0, -1.0), P("Prop_Hay_1", 7.0, 6.0),
         P("Prop_Cart_1_Hay", 5.0, 3.0, rot=90), P("Prop_Barrel_2", 8.5, -6.0), lamp(2.5, -6.5),
         tree("BirchTree_4", 6.0, -7.5),
     ],
     scatter=[S("Grass", 14), S("Flowers", 10)])

# ===== inner corners (dirt): orchards / gardens =====
cell(-2, -2, "dirt",
     rows=[fence_x(-8.0, -2.0, 9.3), fence_x(2.0, 8.0, 9.3), fence_z(-8.0, 8.0, -9.3), fence_x(-8.0, 8.0, -9.3)],
     props=[
         tree("CommonTree_1", -6.0, -6.0), tree("CommonTree_2", 0.0, -6.0), tree("CommonTree_3", 6.0, -6.0),
         tree("CommonTree_4", -6.0, 0.5), tree("CommonTree_5", 6.0, 0.5),
         P("Prop_Cart_1_Hay", 0.0, 3.0, rot=0), P("Prop_Hay_1", -6.0, 6.5), P("Bush_1", 6.0, 6.5),
         P("Rock_Moss_3", 8.6, 8.6),
     ],
     scatter=[S("Grass", 16), S("Flowers", 10)])

cell(2, -2, "dirt",
     rows=[wheat_row(-8, 8, -6.0), wheat_row(-8, 8, -3.0), wheat_row(-8, 8, 0.0),
           fence_x(-8.0, 8.0, -9.3), fence_z(-8.0, 2.0, 9.3), fence_z(-8.0, 2.0, -9.3)],
     props=[
         tree("CommonTree_2", -6.0, 6.0), tree("CommonTree_4", 0.0, 7.5), tree("BirchTree_1", 6.0, 6.0),
         P("Prop_Cart_1_Barrels", 6.0, 3.0, rot=90), P("Prop_Hay_1", -6.0, 3.0), P("Prop_Barrel_1", -8.6, 3.0),
         P("Bush_2", 8.6, 8.6), P("Rock_Moss_4", -8.6, 8.6),
     ],
     scatter=[S("Grass", 14), S("Flowers", 10)])

cell(-2, 2, "dirt",   # north strip z<-8.6, x in [-6.25,0.25] kept clear for [-2,1] house_d's back wall
     rows=[fence_x(-8.0, -2.0, 9.3), fence_x(2.0, 8.0, 9.3)],
     props=[
         tree("BirchTree_1", -6.0, -3.0), tree("BirchTree_2", 0.5, -5.0), tree("BirchTree_3", 6.0, -4.0),
         tree("BirchTree_4", -5.0, 4.0), tree("BirchTree_5", 3.0, 5.0), tree("BirchTree_2", 7.0, 8.0),
         bench(0.0, 1.0), P("Rock_4", -8.0, 8.0), P("Rock_Moss_5", 8.6, -8.0), P("Bush_1", -8.6, -8.0),
     ],
     scatter=[S("Grass", 16), S("Flowers", 14)])

cell(2, 2, "dirt",
     rows=[wheat_row(-8, 8, 3.0), wheat_row(-8, 8, 6.0), fence_x(-8.0, 8.0, 0.5), fence_x(-8.0, 8.0, 9.3)],
     props=[
         tree("CommonTree_1", -6.0, -6.0), tree("CommonTree_5", 6.0, -6.0), P("Prop_Wagon", 0.0, -6.0, rot=90),
         P("Prop_Hay_1", 4.0, -8.5), P("Prop_Barrel_2", -8.6, -8.6), bench(0.0, -2.6),
         P("Bush_2", 8.6, -2.0), P("Rock_1", -8.6, -2.0),
     ],
     scatter=[S("Grass", 14), S("Flowers", 10)])

# ===== [-1,-2] north yards: kitchen garden (dirt) =====
cell(-1, -2, "dirt",
     rows=[wheat_row(-8, 8, -6.0), wheat_row(-8, 8, -3.5), wheat_row(-8, 8, -1.0),
           fence_x(-8.0, 8.0, 1.5), fence_x(-8.0, -2.0, -9.3), fence_x(2.0, 8.0, -9.3)],
     props=[
         P("Prop_Cart_1_Barrels", -5.5, 6.0, rot=90), P("Prop_Hay_1", 0.0, 4.5), P("Prop_Crate_1", 6.0, 4.0),
         P("Prop_Barrel_1", 7.2, 4.0), tree("CommonTree_4", -8.0, 8.0), tree("BirchTree_2", 8.0, 8.0),
         P("Bush_1", 3.0, 8.0), P("Rock_Moss_2", -8.6, -8.6), bench(0.0, 8.6),
     ],
     scatter=[S("Grass", 14), S("Flowers", 10)])

# ===== [1,-2] north yards: small orchard + hay (dirt); south strip z>8.6, x in [-8.25,-1.75] kept clear for [1,-1] house_d =====
cell(1, -2, "dirt",
     rows=[fence_x(-8.0, 8.0, -9.3), fence_z(-8.0, 6.0, 9.3), orchard_row("CommonTree_1", -7, 7, -5.5),
           orchard_row("CommonTree_3", -7, 7, -1.0)],
     props=[
         P("Prop_Cart_1_Hay", 5.0, 5.0, rot=0), P("Prop_Hay_1", 2.0, 4.0), P("Prop_Hay_1", 7.5, 8.0),
         P("Barrel_Apples", -4.0, 4.0), P("Crate_Wooden", -5.2, 4.0), tree("BirchTree_5", 5.0, 8.6),
         P("Bush_2", -8.6, 3.0), P("Rock_Moss_5", -8.6, -8.6), bench(0.0, 8.0),
     ],
     scatter=[S("Grass", 14), S("Flowers", 10)])

# ===== OUTSKIRTS ring (grass) =====
# gates: the four roads leave town through a gap in a low stone wall flanked by two lamps
cell(0, -3, "grass",   # NORTH GATE
     rows=[NS_FULL(), wall_x(-9.5, -3.0, 9.3), wall_x(3.0, 9.5, 9.3),
           wheat_row(-8.5, -3.0, -7.0), wheat_row(-8.5, -3.0, -4.0), wheat_row(-8.5, -3.0, -1.0),
           fence_x(-8.5, -3.0, 1.5)],
     props=[
         P("SmallBarn", 6.0, -4.0, rot=-90), lamp(-2.8, 8.0), lamp(2.8, 8.0),
         tree("CommonTree_2", 8.0, 6.0), P("Rock_3", -8.5, 7.0), P("Prop_Hay_1", 7.5, -8.5),
         P("Prop_Cart_1_Hay", 7.5, 2.0, rot=0),
     ],
     scatter=[S("Grass_Common_Tall", 20), S("Flowers", 10)])

cell(0, 3, "grass",    # SOUTH GATE — the main entrance; guard post
     rows=[NS_FULL(), wall_x(-9.5, -3.0, -9.3), wall_x(3.0, 9.5, -9.3),
           wheat_row(-8.5, -3.0, 3.0), wheat_row(-8.5, -3.0, 6.0), wheat_row(3.0, 8.5, 3.0), wheat_row(3.0, 8.5, 6.0),
           fence_x(-8.5, -3.0, 1.0), fence_x(3.0, 8.5, 1.0)],
     props=[
         lamp(-2.8, -8.0), lamp(2.8, -8.0), P("Prop_Wagon", -6.0, -5.0, rot=0),
         tree("CommonTree_4", -7.0, 8.6), tree("CommonTree_1", 7.0, 8.6), P("Rock_Moss_1", 8.5, -6.0),
         P("Prop_Hay_1", -8.5, 8.6), P("Bush_1", 7.0, -3.0),
     ],
     npc={"id": "guard", "name": "Town Guard", "pos": [2.8, -6.0], "model": GUARD,
          "persona": "A town guard at the south gate of Ashford Green, a peaceful farming town. Bored but polite, gives directions. Two short sentences max.",
          "lines": ["Town Guard: Welcome to Ashford Green. The plaza and the town hall are straight up the road.",
                    "Town Guard: Quiet day. Mind the carts on the High Street."]},
     scatter=[S("Grass_Common_Tall", 18), S("Flowers", 10)])

cell(-3, 1, "grass",   # WEST GATE
     rows=[EW_FULL(), wall_z(-9.5, -3.0, 9.3), wall_z(3.0, 9.5, 9.3),
           wheat_row(-8.5, 7.0, 4.0), wheat_row(-8.5, 7.0, 6.5), wheat_row(-8.5, 7.0, 9.0)],
     props=[
         P("OpenBarn", -5.0, -6.0, rot=0), lamp(8.0, -2.8), lamp(8.0, 2.8),
         tree("CommonTree_3", 3.0, -6.5), P("Rock_4", -8.6, -9.0), P("Prop_Hay_1", -8.6, -2.6),
         P("Prop_Cart_1_Barrels", 1.5, -8.0, rot=90),
     ],
     scatter=[S("Grass_Common_Tall", 20), S("Flowers", 8)])

cell(3, 1, "grass",    # EAST GATE
     rows=[EW_FULL(), wall_z(-9.5, -3.0, -9.3), wall_z(3.0, 9.5, -9.3), fence_x(-5.0, 8.0, -3.0)],
     props=[
         P("SmallBarn", 5.0, 6.0, rot=180), lamp(-8.0, -2.8), lamp(-8.0, 2.8),
         tree("CommonTree_1", -4.0, -6.5), tree("CommonTree_2", 1.0, -7.5), tree("CommonTree_3", 6.0, -5.5),
         tree("CommonTree_4", 8.6, -8.6), P("Prop_Wagon", -4.0, 5.5, rot=0), P("Rock_Moss_2", 8.6, -2.8),
     ],
     scatter=[S("Grass_Common_Tall", 20), S("Flowers", 10)])

cell(-3, -1, "grass",  # Back Lane west end -> pine wood
     rows=[EW_FULL(DIRT_MAT)],
     props=[
         tree("PineTree_2", -6.0, -6.0), tree("PineTree_4", -3.0, -7.5), tree("PineTree_1", -7.0, 5.0),
         tree("PineTree_3", -2.0, 7.0), tree("CommonTree_5", 5.0, -6.0), P("Rock_5", 6.0, 6.0),
         P("Rock_Moss_6", -8.5, -3.5), P("Rock_2", 8.0, 8.0),
     ],
     scatter=[S("PineTree_1", 14), S("Grass_Common_Tall", 20), S("Rock_Moss_1", 8)])

cell(3, -1, "grass",   # Back Lane east end -> meadow orchard
     rows=[EW_FULL(DIRT_MAT), farmfence_x(-6.0, 5.8, -3.0), farmfence_x(-6.0, 5.8, 3.0)],
     props=[
         tree("CommonTree_1", -5.0, -7.0), tree("CommonTree_3", 2.0, -7.0), tree("BirchTree_2", 7.0, -6.0),
         tree("CommonTree_2", -5.0, 6.5), tree("BirchTree_4", 5.0, 7.0), P("Prop_Cart_1_Hay", -1.0, 6.0, rot=90),
         P("Rock_7", 8.6, 8.6), P("Bush_2", -8.6, 8.0),
     ],
     scatter=[S("Grass_Common_Tall", 20), S("Flowers", 12)])

cell(-3, 0, "grass",   # behind the chapel: birch meadow
     props=[
         tree("BirchTree_1", -5.0, -6.0), tree("BirchTree_2", 2.0, -7.0), tree("BirchTree_3", -7.0, 2.0),
         tree("BirchTree_4", 0.0, 3.0), tree("BirchTree_5", 6.0, 7.0), P("Rock_Moss_3", -8.0, -8.0),
         P("Rock_6", 8.0, -2.0), P("Bush_1", -3.0, 8.0), bench(7.0, -6.0),
     ],
     scatter=[S("Grass_Common_Tall", 18), S("Flowers", 12), S("Bush_Common", 5)])

cell(3, 0, "grass",    # east of the forge: rocky pasture + barn
     rows=[farmfence_x(-6.0, 5.8, 9.3), farmfence_z(-5.0, 6.8, 9.3)],
     props=[
         P("SmallBarn", 4.0, -4.0, rot=90), P("Prop_Cart_1_Barrels", -5.0, 5.0, rot=0),
         tree("CommonTree_4", -6.0, -6.0), tree("PineTree_5", 7.0, 6.0), tree("CommonTree_2", -2.0, 8.0),
         P("Rock_4", -8.0, 0.0), P("Rock_Moss_7", 8.6, -8.6), P("Prop_Hay_1", 0.0, -8.0), P("Prop_Barrel_1", 8.3, 1.5),
     ],
     scatter=[S("Grass_Common_Tall", 20), S("Rock_1", 8), S("Flowers", 8)])

# --- field templates ---
def wheat_field(gx, gz, extra_props=(), lane_rows=()):
    cell(gx, gz, "grass",
         rows=list(lane_rows) + [wheat_row(-8, 8, -6.0), wheat_row(-8, 8, -3.0), wheat_row(-8, 8, 0.0),
                                 wheat_row(-8, 8, 3.0), farmfence_x(-6.0, 5.8, -9.3), farmfence_x(-6.0, 5.8, 6.0)],
         props=[P("Prop_Cart_1_Hay", -6.0, 8.0, rot=0), P("Prop_Hay_1", 0.0, 8.0), P("Prop_Hay_1", 3.0, 8.6),
                tree("CommonTree_2", 7.5, 8.0), tree("CommonTree_5", -8.6, -8.6), P("Rock_3", 8.6, -8.6)] + list(extra_props),
         scatter=[S("Wheat", 40, collider="none"), S("Grass_Common_Tall", 12)])

def orchard(gx, gz, kind="CommonTree", extra_props=(), lane_rows=()):
    a, b = (f"{kind}_1", f"{kind}_3")
    cell(gx, gz, "grass",
         rows=list(lane_rows) + [orchard_row(a, -8, 8, -6.0), orchard_row(b, -8, 8, -2.0),
                                 orchard_row(a, -8, 8, 2.0), orchard_row(b, -8, 8, 6.0),
                                 farmfence_x(-6.0, 5.8, 9.3)],
         props=[P("Prop_Cart_1_Barrels", 8.0, 8.6, rot=0), P("Barrel_Apples", -8.6, 8.6), P("Crate_Wooden", -7.4, 8.6),
                P("Prop_Hay_1", 8.6, -8.6), P("Rock_Moss_2", -8.6, -8.6)] + list(extra_props),
         scatter=[S("Grass_Common_Tall", 16), S("Flowers", 12), S("BushBerries_1", 6)])

def pasture(gx, gz, extra_props=(), lane_rows=()):
    cell(gx, gz, "grass",
         rows=list(lane_rows),
         rings=[{"part": {"shape": "column", "radius": 0.12, "height": 1.0, "material": "timber"},
                 "half": [7.0, 6.0], "spacing": 1.4}],       # post-fenced paddock around the cell centre
         props=[P("Prop_Cart_1_Hay", 3.0, 0.0, rot=0), P("Prop_Hay_1", -4.0, -3.0), P("Prop_Hay_1", -3.0, 3.5),
                P("Prop_Barrel_1", 5.5, -4.0), tree("CommonTree_3", -8.6, -8.6), tree("BirchTree_2", 8.6, 8.6),
                tree("CommonTree_1", 8.6, -8.6), P("Rock_Moss_4", -8.6, 8.6), P("Bush_2", 0.0, 8.6)] + list(extra_props),
         scatter=[S("Grass_Common_Tall", 22), S("Flowers", 12)])

def forest(gx, gz):
    cell(gx, gz, "grass",
         props=[tree("PineTree_1", -6.0, -6.0), tree("PineTree_3", 2.0, -7.0), tree("CommonTree_4", 7.0, -3.0),
                tree("PineTree_5", -7.0, 1.0), tree("CommonTree_2", 0.0, 2.0), tree("PineTree_2", 6.0, 6.0),
                tree("PineTree_4", -3.0, 7.0), P("Rock_Moss_6", 8.0, 1.0), P("Rock_5", -8.0, -2.0), P("Bush_1", 4.0, -8.0)],
         scatter=[S("PineTree_2", 25), S("CommonTree_3", 12), S("Rock_Moss_1", 10), S("Grass_Common_Tall", 20)])

forest(-3, -3); forest(3, -3); forest(-3, 3); forest(3, 3)
wheat_field(-2, -3); wheat_field(2, -3); wheat_field(-2, 3); wheat_field(3, -2)
orchard(-1, -3, "CommonTree"); orchard(-3, -2, "BirchTree"); orchard(3, 2, "CommonTree")
orchard(-1, 3, "CommonTree", lane_rows=[lane_ns(-8, 0, DIRT_MAT)])   # West Lane runs on into the orchard
pasture(1, -3); pasture(-3, 2); pasture(2, 3)

# ===== [1,3] WINDMILL on the south-east edge (the tallest thing outside town, seen from the plaza) =====
cell(1, 3, "grass",
     rows=[lane_ns(-8, -4, DIRT_MAT), wheat_row(-8, -1, 6.0), wheat_row(-8, -1, 8.6), farmfence_x(-8.5, 3.3, 4.0)],
     props=[
         P("Windmill", 0.0, 3.0, rot=0), P("Prop_Cart_1_Hay", 5.0, -6.0, rot=0), P("Prop_Hay_1", 6.5, -8.0),
         P("Prop_Crate_1", 5.0, 1.0), P("Prop_Crate_1", 6.2, 1.0), P("Prop_Barrel_2", 5.6, 2.2),
         tree("CommonTree_1", -7.0, -7.0), tree("CommonTree_3", 8.6, 8.0), P("Rock_2", -8.6, 0.0),
     ],
     scatter=[S("Wheat", 30, collider="none"), S("Grass_Common_Tall", 16)])

# ---------------------------------------------------------------- assemble
assert len(cells) == 49, len(cells)
for gx in range(-3, 4):
    for gz in range(-3, 4):
        assert (gx, gz) in cells, (gx, gz)

world = {
    "mode": "chunk",
    "title": "Ashford Green",
    "grid": {"cell_size": 20},
    "start_cell": [0, 1],
    "goal": {"type": "reach_cell", "target": [0, 0]},
    "character_source": "meshy",
    "hero_model": HERO,
    "default_npc_model": VILLAGER,
    "sky": {"time": "day", "weather": "cloudy"},
    "items": {"potion": {"consumed": True}},
    "cells": [cells[(gx, gz)] for gz in range(-3, 4) for gx in range(-3, 4)],
}

# ---------------------------------------------------------------- validation
def cell_centre(gx, gz):
    return (gx * CELL + CELL / 2, gz * CELL + CELL / 2)

def footprint(mtype, x, z, rot):
    w, d, _ = MASON[mtype]
    if rot in (90, -90):
        w, d = d, w
    return (x - w / 2, z - d / 2, x + w / 2, z + d / 2)

def door_local(mtype, x, z, rot):
    w, d, off = MASON[mtype]
    if rot == 0:    return (x + off, z - d / 2)
    if rot == 180:  return (x - off, z + d / 2)
    if rot == 90:   return (x - d / 2, z - off)
    if rot == -90:  return (x + d / 2, z + off)

def overlap(a, b, pad=0.0):
    return not (a[2] + pad <= b[0] or b[2] + pad <= a[0] or a[3] + pad <= b[1] or b[3] + pad <= a[1])

bld = []        # (label, world footprint, world door, cell, type, pos, rot)
lanes = []      # world rects of lane strips
propcount = {}
for c in world["cells"]:
    gx, gz = c["cell"]; cx, cz = cell_centre(gx, gz)
    ents = list(c.get("props", []))
    if "landmark" in c:
        ents.insert(0, c["landmark"])
    propcount[(gx, gz)] = len(c.get("props", []))
    assert len(c.get("props", [])) <= 12, (c["cell"], len(c["props"]))
    nm = 0
    for i, p in enumerate(ents):
        if str(p.get("url", "")).startswith("MASON:"):
            nm += 1
            t = p["url"][6:]; x, z = p["pos"]; rot = p.get("rot", 0)
            fx0, fz0, fx1, fz1 = footprint(t, x, z, rot)
            dl = door_local(t, x, z, rot)
            bld.append((f"[{gx},{gz}] {t}", (fx0 + cx, fz0 + cz, fx1 + cx, fz1 + cz), (dl[0] + cx, dl[1] + cz), (gx, gz), t, (x, z), rot, dl))
            # door side >= 1.5 m inside cell edge
            dside = {0: -fz0, 180: fz1, 90: -fx0, -90: fx1}[rot]
            assert dside <= 8.5, ("door side too close to edge", c["cell"], t, dside)
            # Mason buildings must be FIRST in props
            if p is not c.get("landmark"):
                assert i - (1 if "landmark" in c else 0) < 3 and all(str(q.get("url", "")).startswith("MASON:") for q in c["props"][:i - (1 if "landmark" in c else 0) + 1]), ("mason not first", c["cell"])
    assert nm <= 4, (c["cell"], nm)
    assert sum(1 for p in c.get("props", []) if str(p.get("url", "")).startswith("MASON:")) <= 3, c["cell"]
    for r in c.get("rows", []):
        part = r["part"]
        if part.get("shape") == "box" and part["size"][1] < 0.1:
            sx, _, sz = part["size"]
            (ax, az), (bx, bz) = r["from"], r["to"]
            L = math.hypot(bx - ax, bz - az); n = max(1, round(L / r["spacing"])) if L > 0.001 else 0
            for k in range(n + 1):
                px = ax + (bx - ax) * (k / n if n else 0); pz = az + (bz - az) * (k / n if n else 0)
                lanes.append((px - sx / 2 + cx, pz - sz / 2 + cz, px + sx / 2 + cx, pz + sz / 2 + cz))
    for s in c.get("scatter", []):
        assert s["count"] <= 40
    for k in ("enemies", "director", "rules", "zones", "regions", "roads", "terrain", "water"):
        assert k not in c, (c["cell"], k)

problems = []
for a, b in itertools.combinations(bld, 2):
    if overlap(a[1], b[1], pad=1.0):
        problems.append(f"BUILDING OVERLAP/too close (<1 m): {a[0]} vs {b[0]}")
for b in bld:
    for L in lanes:
        if overlap(b[1], L):
            problems.append(f"BUILDING ON LANE: {b[0]} fp={b[1]} lane={L}")
sx, sz = cell_centre(0, 1)
for b in bld:
    if overlap(b[1], (sx - 2, sz - 2, sx + 2, sz + 2)):
        problems.append(f"BUILDING ON SPAWN: {b[0]}")
# every prop's position must be clear of every Mason footprint (except the chest, which is deliberately inside the tavern)
for c in world["cells"]:
    gx, gz = c["cell"]; cx, cz = cell_centre(gx, gz)
    for p in c.get("props", []):
        if str(p.get("url", "")).startswith("MASON:"):
            continue
        wx, wz = p["pos"][0] + cx, p["pos"][1] + cz
        for b in bld:
            if b[1][0] - 0.3 <= wx <= b[1][2] + 0.3 and b[1][1] - 0.3 <= wz <= b[1][3] + 0.3:
                problems.append(f"PROP {p['url'].split('/')[-1]} at [{gx},{gz}] {p['pos']} inside/touching {b[0]}")
        for L in lanes:
            if L[0] - 0.4 <= wx <= L[2] + 0.4 and L[1] - 0.4 <= wz <= L[3] + 0.4:
                problems.append(f"PROP {p['url'].split('/')[-1]} at [{gx},{gz}] {p['pos']} on a lane strip")
    if "npc" in c:
        wx, wz = c["npc"]["pos"][0] + cx, c["npc"]["pos"][1] + cz
        for b in bld:
            if b[1][0] <= wx <= b[1][2] and b[1][1] <= wz <= b[1][3]:
                problems.append(f"NPC {c['npc']['id']} inside {b[0]}")

# check manifest ids
man = json.load(open("/tmp/manifest.json"))
files = {p["file"] for p in man["props"]}
used = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "url" and isinstance(v, str) and v.startswith("props/"):
                used.add(v)
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(world)
missing = sorted(u for u in used if u not in files)
if missing:
    problems.append("MISSING IN MANIFEST: " + ", ".join(missing))

with open(OUT, "w") as f:
    json.dump(world, f, indent=1)

print(f"cells={len(world['cells'])} mason={len(bld)} (houses={sum(1 for b in bld if b[4].startswith('house'))}) distinct props={len(used)}")
print("props/cell:", " ".join(f"{k}:{v}" for k, v in sorted(propcount.items())))
print("\nMASON PLACEMENTS (cell, type, local pos, rot, door WORLD (x,z), door faces):")
faces = {0: "north (-Z)", 180: "south (+Z)", 90: "west (-X)", -90: "east (+X)"}
for b in sorted(bld, key=lambda b: (b[3][1], b[3][0])):
    print(f"  {b[3]!s:9} {b[4]:10} pos={b[5]!s:14} rot={b[6]:5} door_local={tuple(round(v,2) for v in b[7])!s:16} door_world=({b[2][0]:.2f}, {b[2][1]:.2f}) faces {faces[b[6]]}")
print("\nspawn world =", (sx, 0.0, sz), "(centre of start_cell [0,1]); hall door world = (10.00, 14.50), 15.5 m due north of spawn")
print("\nPROBLEMS:" if problems else "\nno geometry problems found")
for p in problems:
    print("  -", p)
