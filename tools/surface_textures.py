# Writes the sample's generated textures (see docs/rendering/materials.md#parallax-occlusion-mapping and
# docs/rendering/surfaces.md): 8-bit grayscale PNGs that a pattern makes, so the repository holds no painted art. It
# uses the standard library only. `just sample-textures` runs it; commit what it writes, with the .meta files.
import math
import struct
import sys
import zlib


def write_png(path, width, height, rows):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def clamp01(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


# bricks_height: a running bond of bricks, 1 on their faces, rounded off toward their edges, and 0 in the mortar.
def bricks_height(size=256, brick_w=64, brick_h=32, mortar=3, round_px=2):
    rows = []
    for y in range(size):
        row = y // brick_h
        shift = (brick_w // 2) if row % 2 else 0
        line = []
        for x in range(size):
            bx = (x + shift) % brick_w
            by = y % brick_h
            # Distance to the nearest mortar edge, in pixels, inside the brick's face.
            d = min(bx - mortar, brick_w - 1 - bx, by - mortar, brick_h - 1 - by)
            h = clamp01((d + 0.5) / round_px)
            line.append(int(round(h * 255)))
        rows.append(line)
    return size, size, rows


# lake_height is the lake's bed, 0 to 1 of the terrain material's height_scale (30 m): rolling hills, shores that rise
# toward the edges, and an island. The water sits 8 m above the terrain's base, so the land shows where this is over
# 8 / 30.
def lake_height(u, v):
    hills = 0.1 + 0.05 * (math.sin(u * 19.0) * math.cos(v * 23.0) + 0.5 * math.sin((u + v) * 41.0))
    rim = max(abs(u - 0.5), abs(v - 0.5))
    shore = 0.45 * smoothstep(0.34, 0.5, rim)
    island = 0.55 * math.exp(-(((u - 0.56) ** 2 + (v - 0.48) ** 2) / (2 * 0.075 ** 2)))
    return clamp01(hills + shore + island)


def smoothstep(a, b, x):
    t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)


def terrain_height(size=256):
    rows = [[int(round(lake_height((x + 0.5) / size, (y + 0.5) / size) * 255)) for x in range(size)] for y in range(size)]
    return size, size, rows


# island_hole is the water's hole mask over the same rectangle, one texel a finest cell: 0 where the land is a little
# above the water, so the water stops just under the shore.
def island_hole(size=256):
    rows = [[0 if lake_height((x + 0.5) / size, (y + 0.5) / size) * 30 > 8.6 else 255 for x in range(size)] for y in range(size)]
    return size, size, rows


TEXTURES = {
    "samples/mygame/content/textures/bricks_height.png": bricks_height,
    "samples/mygame/content/textures/terrain_height.png": terrain_height,
    "samples/mygame/content/textures/island_hole.png": island_hole,
}


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    for path, make in TEXTURES.items():
        w, h, rows = make()
        write_png(f"{root}/{path}", w, h, rows)
        print(path)


if __name__ == "__main__":
    main(sys.argv)
