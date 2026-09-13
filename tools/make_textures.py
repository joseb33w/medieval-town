#!/usr/bin/env python3
"""Tileable, mostly-greyscale detail textures for the Mason buildings (tinted at runtime by each
material's baseColorFactor). 256x256 PNGs -> tools/tex/<name>.png. Deterministic."""
import os, numpy as np
from PIL import Image, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tex")
os.makedirs(OUT, exist_ok=True)
N = 256
rng = np.random.default_rng(7)


def noise(scale, octaves=4, seed=0):
    r = np.random.default_rng(seed)
    acc = np.zeros((N, N)); amp = 1.0; tot = 0.0
    for o in range(octaves):
        s = max(2, int(scale / (2 ** o)))
        small = r.random((s, s))
        img = Image.fromarray((small * 255).astype(np.uint8)).resize((N, N), Image.BICUBIC)
        acc += np.asarray(img, dtype=np.float32) / 255.0 * amp
        tot += amp; amp *= 0.5
    return acc / tot


def save(name, lum):
    lum = np.clip(lum, 0, 1)
    img = Image.fromarray((lum * 255).astype(np.uint8), "L").convert("RGB")
    img.save(os.path.join(OUT, name + ".png"), optimize=True)


def courses(rows, cols_per_row, mortar, jitter_seed, tone_var=0.10, offset_half=True):
    """brick / ashlar: rows of blocks, alternate rows offset by half a block, dark mortar lines."""
    r = np.random.default_rng(jitter_seed)
    img = np.ones((N, N), dtype=np.float32) * 0.82
    rh = N / rows
    for i in range(rows):
        y0 = int(i * rh); y1 = int((i + 1) * rh)
        bw = N / cols_per_row
        off = (bw / 2) if (offset_half and i % 2) else 0
        for j in range(cols_per_row + 1):
            x0 = int(j * bw + off) - int(bw); x1 = int((j + 1) * bw + off) - int(bw)
            tone = 0.72 + r.random() * tone_var * 2
            xs = slice(max(0, x0), min(N, x1))
            img[y0:y1, xs] = tone
            # wrap the block that spills past the right edge
            if x1 > N:
                img[y0:y1, 0:x1 - N] = tone
        img[y0:y0 + mortar, :] = 0.45
        for j in range(cols_per_row + 1):
            x0 = int(j * bw + off) % N
            img[y0:y1, x0:min(N, x0 + mortar)] = 0.45
    img += (noise(64, 3, jitter_seed) - 0.5) * 0.10
    return img


# stone: large irregular ashlar, 4 courses per tile (tile = 2 m -> 0.5 m blocks)
save("stone", courses(4, 3, 3, 11, tone_var=0.08))
# brick: 12 courses per tile (tile = 1.5 m -> 12.5 cm bricks), 4 per row
save("brick", courses(12, 4, 2, 23, tone_var=0.09))
# plaster: soft mottled noise + faint cracks
p = 0.80 + (noise(32, 5, 5) - 0.5) * 0.14
save("plaster", p)
# timber: vertical planks with grain, 6 planks per tile
t = np.ones((N, N), dtype=np.float32) * 0.78
pw = N // 6
for j in range(6):
    tone = 0.66 + rng.random() * 0.16
    t[:, j * pw:(j + 1) * pw] = tone
    t[:, j * pw:j * pw + 2] = 0.42
grain = np.asarray(Image.fromarray((np.random.default_rng(3).random((N, 8)) * 255).astype(np.uint8)).resize((N, N), Image.BICUBIC), dtype=np.float32) / 255.0
t += (grain - 0.5) * 0.12
save("timber", t)
# slate: overlapping roof tiles, 8 courses per tile, staggered
save("slate", courses(8, 5, 2, 31, tone_var=0.12))
print("textures ->", OUT, sorted(os.listdir(OUT)))
