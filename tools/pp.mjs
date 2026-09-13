// Post-process a Mason lod0 GLB for the Godot rpg engine:
//  - drop the `__collision` shell (this engine has no handler for it; collider:"mesh_exact" trimeshes the visual mesh)
//  - assign a hand-tuned PBR palette per material group (body_/roof_/trim_ + material name)
//  - join primitives per material (one draw call per material instead of one per B-rep face)
import { NodeIO } from '@gltf-transform/core';
import { join, weld, prune, dedup, flatten } from '@gltf-transform/functions';
import { readFileSync } from 'node:fs';

const [,, inPath, outPath, paletteJson] = process.argv;
const PALETTE = {
  stone:   { color: [0.62, 0.60, 0.55], rough: 0.92 },
  plaster: { color: [0.82, 0.78, 0.68], rough: 0.90 },
  timber:  { color: [0.42, 0.30, 0.20], rough: 0.85 },
  brick:   { color: [0.58, 0.36, 0.28], rough: 0.90 },
  slate:   { color: [0.30, 0.32, 0.36], rough: 0.75 },
  metal:   { color: [0.50, 0.52, 0.55], rough: 0.55 },
};
const overrides = paletteJson ? JSON.parse(readFileSync(paletteJson, 'utf8')) : {};

const io = new NodeIO();
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
    .setBaseColorFactor([col[0], col[1], col[2], 1])
    .setRoughnessFactor(ov.rough ?? base.rough)
    .setMetallicFactor(0)
    .setDoubleSided(false);
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
