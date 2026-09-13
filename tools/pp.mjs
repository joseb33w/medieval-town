// Post-process a Mason lod0 GLB for the Godot rpg engine:
//  - drop the `__collision` shell (this engine has no handler for it; collider:"mesh_exact" trimeshes the visual mesh)
//  - assign a hand-tuned PBR palette per material group (body_/roof_/trim_ + material name)
//  - join primitives per material (one draw call per material instead of one per B-rep face)
import { NodeIO, VertexLayout } from '@gltf-transform/core';
import { join, weld, prune, dedup, flatten } from '@gltf-transform/functions';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join as pjoin } from 'node:path';
import { fileURLToPath } from 'node:url';

const [,, inPath, outPath, paletteJson] = process.argv;
// tileable greyscale detail textures (tools/make_textures.py), tinted by baseColorFactor; metres per repeat
const TEX_DIR = process.env.TOWN_TEX_DIR || pjoin(dirname(fileURLToPath(import.meta.url)), 'tex');
const TEX = { stone: ['stone', 2.0], plaster: ['plaster', 3.0], timber: ['timber', 2.0], brick: ['brick', 1.5], slate: ['slate', 1.5], metal: ['plaster', 2.0] };
const texCache = new Map();
function texFor(name) {
  const [file] = TEX[name] || TEX.stone;
  if (texCache.has(file)) return texCache.get(file);
  const path = pjoin(TEX_DIR, file + '.png');
  if (!existsSync(path)) return null;
  const t = doc.createTexture(file).setImage(readFileSync(path)).setMimeType('image/png');
  texCache.set(file, t);
  return t;
}
const PALETTE = {
  stone:   { color: [0.52, 0.50, 0.46], rough: 0.92 },
  plaster: { color: [0.78, 0.72, 0.60], rough: 0.90 },
  timber:  { color: [0.40, 0.28, 0.18], rough: 0.85 },
  brick:   { color: [0.55, 0.33, 0.26], rough: 0.90 },
  slate:   { color: [0.26, 0.28, 0.32], rough: 0.75 },
  metal:   { color: [0.50, 0.52, 0.55], rough: 0.55 },
};
const overrides = paletteJson ? JSON.parse(readFileSync(paletteJson, 'utf8')) : {};

const io = new NodeIO().setVertexLayout(VertexLayout.SEPARATE);
const doc = await io.read(inPath);
const root = doc.getRoot();

// 1. drop the collision shell
for (const node of root.listNodes()) {
  if (node.getName() === '__collision' || node.getName().startsWith('__collision')) {
    for (const c of node.listChildren()) c.dispose();
    node.dispose();
  }
}
for (const mesh of root.listMeshes()) {
  if (mesh.getName().startsWith('__collision')) mesh.dispose();
}
// meshes whose name is empty AND that are not referenced by any named node = collision leftovers
// (Mason labels body_/roof_/trim_; the collision compound's children are unlabelled)
for (const mesh of root.listMeshes()) {
  const parents = mesh.listParents().filter(p => p.propertyType === 'Node');
  const named = parents.some(p => /^(body|roof|trim)_/.test(p.getName()) ) || /^(body|roof|trim)_/.test(mesh.getName());
  if (!named) { for (const p of parents) p.dispose(); mesh.dispose(); }
}

// 1b. UVs by box projection (Mason exports POSITION+NORMAL only; faces are flat, vertices unshared
// across faces, so a per-vertex dominant-normal projection is seam-free per face). Mesh-local frame is
// Z-up here (the node carries the -90deg X rotation), so metres map 1:1 either way.
for (const mesh of root.listMeshes()) {
  let label = mesh.getName();
  if (!/^(body|roof|trim)_/.test(label)) {
    const p = mesh.listParents().find(p => p.propertyType === 'Node' && /^(body|roof|trim)_/.test(p.getName()));
    if (p) label = p.getName();
  }
  const m = /^(body|roof|trim)_(.+)$/.exec(label);
  const perRepeat = (TEX[m ? m[2] : 'stone'] || TEX.stone)[1];
  for (const prim of mesh.listPrimitives()) {
    const P = prim.getAttribute('POSITION'), Nn = prim.getAttribute('NORMAL');
    if (!P || !Nn || prim.getAttribute('TEXCOORD_0')) continue;
    const n = P.getCount(); const uv = new Float32Array(n * 2);
    const pos = [0, 0, 0], nor = [0, 0, 0];
    for (let i = 0; i < n; i++) {
      P.getElement(i, pos); Nn.getElement(i, nor);
      const ax = Math.abs(nor[0]), ay = Math.abs(nor[1]), az = Math.abs(nor[2]);
      let u, v;
      if (az >= ax && az >= ay) { u = pos[0]; v = pos[1]; }        // horizontal face (floor/ceiling/roof top)
      else if (ax >= ay) { u = pos[1]; v = pos[2]; }               // face normal along X
      else { u = pos[0]; v = pos[2]; }                              // face normal along Y
      uv[i * 2] = u / perRepeat; uv[i * 2 + 1] = -v / perRepeat;
    }
    const acc = doc.createAccessor().setType('VEC2').setArray(uv).setBuffer(root.listBuffers()[0]);
    prim.setAttribute('TEXCOORD_0', acc);
  }
}

// 2. palette per group
const matCache = new Map();
function matFor(group, name) {
  const key = group + ':' + name;
  if (matCache.has(key)) return matCache.get(key);
  const base = PALETTE[name] || PALETTE.stone;
  const ov = overrides[key] || overrides[name] || {};
  let col = ov.color || base.color;
  if (group === 'trim' && !ov.color) col = col.map(c => Math.min(0.85, c * 1.12));
  const m = doc.createMaterial(key)
    .setBaseColorFactor([Math.min(1, col[0] * 1.18), Math.min(1, col[1] * 1.18), Math.min(1, col[2] * 1.18), 1])   // texture lum ~0.8 -> tint x1.18 keeps the palette
    .setRoughnessFactor(ov.rough ?? base.rough)
    .setMetallicFactor(0)
    .setDoubleSided(false);
  const tex = texFor(name);
  if (tex) m.setBaseColorTexture(tex);
  matCache.set(key, m);
  return m;
}
for (const mesh of root.listMeshes()) {
  let label = mesh.getName();
  if (!/^(body|roof|trim)_/.test(label)) {
    const p = mesh.listParents().find(p => p.propertyType === 'Node' && /^(body|roof|trim)_/.test(p.getName()));
    if (p) label = p.getName();
  }
  const m = /^(body|roof|trim)_(.+)$/.exec(label);
  if (!m) continue;
  const mat = matFor(m[1], m[2]);
  for (const prim of mesh.listPrimitives()) prim.setMaterial(mat);
}

// 3. join + weld
await doc.transform(dedup(), flatten(), join({ keepMeshes: false, keepNamed: false }), weld(), prune());
await io.write(outPath, doc);

// report
let tris = 0, prims = 0;
for (const mesh of root.listMeshes()) for (const prim of mesh.listPrimitives()) {
  prims++; const idx = prim.getIndices(); tris += idx ? idx.getCount() / 3 : prim.getAttribute('POSITION').getCount() / 3;
}
console.log(`${outPath}: meshes=${root.listMeshes().length} prims=${prims} tris=${tris} mats=${root.listMaterials().map(m=>m.getName()).join(',')}`);
