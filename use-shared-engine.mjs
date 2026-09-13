#!/usr/bin/env node
/**
 * SHARED-ENGINE REWRITE — run on a Godot web export directory AFTER `--export-release`
 * and BEFORE uploading it.
 *
 * WHY
 * Every exported game shipped its own copy of a BYTE-IDENTICAL engine at its own URL, so a
 * browser could never reuse it. Measured across three separate builds: `index.wasm` had the same
 * SHA-256 in all of them, 37.7MB each. A user opening their second game re-downloaded 37.7MB they
 * already had. Only `index.pck` (~10MB) actually differs per game.
 *
 * WHAT IT DOES
 * Godot's web loader resolves EVERY engine file from one config value. From the loader source:
 *
 *     'locateFile': function (path) {
 *         if (!path.startsWith('godot.')) return path;
 *         else if (path.endsWith('.audio.worklet.js')) return `${loadPath}.audio.worklet.js`;
 *         else if (path.endsWith('.wasm'))             return `${loadPath}.wasm`;
 *     }
 *     const pack = this.config.mainPack || `${exe}.pck`;
 *
 * `loadPath` comes from `executable`, and `mainPack` overrides the pack INDEPENDENTLY. So pointing
 * `executable` at a shared URL moves the wasm and both audio worklets, while `mainPack` keeps the
 * game's own pack local. `index.js` is referenced by its own <script> tag, so that is repointed too.
 *
 * The engine URL is VERSIONED (`godot-engine/<version>/`). A future engine upgrade publishes a new
 * folder and new games point at it; games already deployed keep resolving the version they shipped
 * against, so an engine change can never retroactively break a live game.
 *
 * SAFETY
 * Idempotent, and refuses to write a half-rewritten page: if any expected reference is missing the
 * script exits non-zero WITHOUT touching index.html, so a Godot template change surfaces as a failed
 * build rather than a game that silently 404s its engine.
 *
 * Usage:  node use-shared-engine.mjs <out-dir> [engine-base-url]
 */

import { readFileSync, writeFileSync, existsSync, unlinkSync, statSync } from "node:fs";
import { join } from "node:path";

const OUT = process.argv[2];
const ENGINE_BASE =
  process.argv[3] ||
  process.env.GODOT_ENGINE_BASE ||
  "https://preview.myapping.com/godot-engine/4.7.1-nothreads";

if (!OUT) {
  console.error("usage: use-shared-engine.mjs <out-dir> [engine-base-url]");
  process.exit(2);
}

const html = join(OUT, "index.html");
if (!existsSync(html)) {
  console.error(`[shared-engine] no index.html in ${OUT}`);
  process.exit(2);
}

// Engine files the loader will now fetch from ENGINE_BASE. Byte-identical across every build —
// verified by SHA-256 across three independent exports before this script was written.
const ENGINE_FILES = [
  "index.js",
  "index.wasm",
  "index.audio.worklet.js",
  "index.audio.position.worklet.js",
];

let src = readFileSync(html, "utf8");
const before = src;

// Already rewritten (re-running a build over the same dir) -> nothing to do.
if (src.includes(`${ENGINE_BASE}/index.js`)) {
  console.log("[shared-engine] already rewritten — skipping");
  process.exit(0);
}

// 1. the <script> tag that loads the loader itself
const scriptRef = /<script src="index\.js"><\/script>/;
if (!scriptRef.test(src)) {
  console.error('[shared-engine] FAIL: no <script src="index.js"> in index.html — Godot template changed?');
  process.exit(1);
}
src = src.replace(scriptRef, `<script src="${ENGINE_BASE}/index.js"></script>`);

// 2. executable -> shared base (moves .wasm + both audio worklets via locateFile)
//    mainPack   -> the game's OWN pack, resolved relative to the page
const exeRef = /"executable":"index"/;
if (!exeRef.test(src)) {
  console.error('[shared-engine] FAIL: no "executable":"index" in GODOT_CONFIG — Godot template changed?');
  process.exit(1);
}
src = src.replace(exeRef, `"executable":"${ENGINE_BASE}/index","mainPack":"index.pck"`);

if (src === before) {
  console.error("[shared-engine] FAIL: nothing was rewritten");
  process.exit(1);
}
writeFileSync(html, src);

// 3. drop the now-redundant local copies so they are never uploaded. index.pck stays — it is the game.
let freed = 0;
for (const f of ENGINE_FILES) {
  const p = join(OUT, f);
  if (existsSync(p)) {
    freed += statSync(p).size;
    unlinkSync(p);
  }
}

const mb = (freed / 1048576).toFixed(1);
console.log(`[shared-engine] engine -> ${ENGINE_BASE}`);
console.log(`[shared-engine] removed ${ENGINE_FILES.length} local engine files, ${mb}MB per game`);
