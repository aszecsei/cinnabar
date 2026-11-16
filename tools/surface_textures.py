# Writes the sample's generated textures and the playground's bushes (see
# docs/rendering/materials.md#parallax-occlusion-mapping, docs/rendering/surfaces.md and
# docs/content/kinds/textures.md#textures): grayscale or RGBA PNGs that a pattern makes,
# so the repository holds no painted art. It uses the standard library only. `just sample-textures` runs it;
# commit what it writes, with the .meta files.
import math
import random
import struct
import sys
import zlib


# write_png takes rows of one value a texel, which is grayscale, or of four, which is RGBA. A depth of 16 writes each
# value as two bytes, big-endian, as PNG stores them.
def write_png(path, width, height, rows, depth=8):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    color_type = 6 if len(rows[0]) == width * 4 else 0
    pack = bytes if depth == 8 else lambda row: struct.pack(f">{len(row)}H", *row)
    raw = b"".join(b"\x00" + pack(row) for row in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 0))
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


# terrain_height is 16 bits a texel, which its .meta cooks as a height texture: 8 bits would terrace at 30 m / 255.
def terrain_height(size=256):
    rows = [[int(round(lake_height((x + 0.5) / size, (y + 0.5) / size) * 65535)) for x in range(size)] for y in range(size)]
    return size, size, rows, 16


# island_hole is the water's hole mask over the same rectangle, one texel a finest cell: 0 where the land is a little
# above the water, so the water stops just under the shore.
def island_hole(size=256):
    rows = [[0 if lake_height((x + 0.5) / size, (y + 0.5) / size) * 30 > 8.6 else 255 for x in range(size)] for y in range(size)]
    return size, size, rows


# terrain_hole is the terrain's hole mask, one texel a finest cell: a round hole 3 m across on the island's west flank,
# which its collider leaves open too (see docs/rendering/surfaces.md#collision).
def terrain_hole(size=256):
    rows = [[0 if math.hypot(x + 0.5 - 0.5 * size, y + 0.5 - 0.48 * size) < 3 else 255 for x in range(size)] for y in range(size)]
    return size, size, rows


# playground_hills is the playground's terrain, 0 to 1 of its material's height_scale (8 m) over 64 m (see
# docs/editor/landscape.md#the-sample): flat where it meets the floor, then rising into rolling hills that a character
# walks up, 16 bits a texel. Sculpt it further in the editor's Landscape tool.
def playground_hills(size=128):
    def height(u, v):
        rise = smoothstep(0.0, 0.5, v)
        hills = 0.5 + 0.5 * math.sin(u * 2 * math.pi * 2.5) * math.cos(v * 2 * math.pi * 1.5)
        return clamp01(rise * (0.3 + 0.35 * hills))

    rows = [[int(round(height((x + 0.5) / size, (y + 0.5) / size) * 65535)) for x in range(size)] for y in range(size)]
    return size, size, rows, 16


# playground_layers is the playground terrain's layer map (see docs/rendering/surfaces.md#layers): its red, green, blue
# and alpha are the weights of grass, dirt, rock and snow. Grass everywhere, a dirt path that winds up from the floor,
# and snow on the tops of the hills. Paint it further with the Landscape tool's Paint brush.
def playground_layers(size=128):
    rows = []
    for y in range(size):
        line = []
        for x in range(size):
            u, v = (x + 0.5) / size, (y + 0.5) / size
            path = clamp01(1 - abs(u - (0.5 + 0.12 * math.sin(v * 2 * math.pi))) / 0.04)
            hills = 0.5 + 0.5 * math.sin(u * 2 * math.pi * 2.5) * math.cos(v * 2 * math.pi * 1.5)
            snow = smoothstep(0.45, 0.6, smoothstep(0.0, 0.5, v) * (0.3 + 0.35 * hills))
            dirt = path * (1 - snow)
            grass = 1 - dirt - snow
            line += [int(round(grass * 255)), int(round(dirt * 255)), 0, int(round(snow * 255))]
        rows.append(line)
    return size, size, rows


# dev_grid: the engine's dev texture (see docs/editor/mesh-editing.md#dev-materials), 1024 texels square: a thick
# line every 256 texels, a thinner one every 64, and 128-texel checks of two greys between them. At 256 texels per
# meter it is 4 m across, with the thick lines a meter apart and the thin ones at the grid's quarter meter, so a
# surface reads as a ruler.
def dev_grid(size=1024, major=256, minor=64, check=128, major_px=4, minor_px=2):
    rows = []
    for y in range(size):
        line = []
        for x in range(size):
            on_major = x % major < major_px or y % major < major_px
            on_minor = x % minor < minor_px or y % minor < minor_px
            light = ((x // check) + (y // check)) % 2 == 0
            if on_major:
                v = 40
            elif on_minor:
                v = 96
            else:
                v = 176 if light else 148
            line.append(v)
        rows.append(line)
    return size, size, rows


# foliage: a bush for a masked material, a trunk under a crown of thin leaves that are each set or clear, with gaps
# between them. The crown's alpha averages about 0.26, so its mips lose it at a cutoff of 0.5 unless they keep its
# coverage (see docs/content/kinds/textures.md#textures). The clear texels hold the leaves' green, so that filtering
# does not darken their edges. The sample cooks it twice, with and without alpha_coverage, to compare them.
def foliage(size=256, leaves=350, seed=28):
    rng = random.Random(seed)
    texels = [[(45, 95, 35, 0) for _ in range(size)] for _ in range(size)]

    def stamp(cx, cy, length, width, angle, color):
        c, s = math.cos(angle), math.sin(angle)
        for y in range(max(int(cy - length), 0), min(int(cy + length) + 1, size)):
            for x in range(max(int(cx - length), 0), min(int(cx + length) + 1, size)):
                along = (x - cx) * c + (y - cy) * s
                across = (y - cy) * c - (x - cx) * s
                if (along / length) ** 2 + (across / width) ** 2 <= 1:
                    texels[y][x] = (*color, 255)

    bark = (80, 55, 35)
    stamp(size * 0.5, size * 0.8, size * 0.2, size * 0.02, math.pi / 2, bark)
    for _ in range(leaves):
        # Evenly over an ellipse, the crown.
        angle, reach = rng.random() * math.tau, math.sqrt(rng.random())
        x = size * (0.5 + 0.42 * reach * math.cos(angle))
        y = size * (0.38 + 0.34 * reach * math.sin(angle))
        shade = 0.7 + 0.5 * rng.random()
        stamp(x, y, 5 + 3 * rng.random(), 1.2, rng.random() * math.pi, (int(50 * shade), int(120 * shade), int(35 * shade)))
    return size, size, [[v for texel in row for v in texel] for row in texels]


TEXTURES = {
    "lib/engine/content/textures/dev_grid.png": dev_grid,
    "samples/mygame/content/textures/bricks_height.png": bricks_height,
    "samples/mygame/content/textures/terrain_height.png": terrain_height,
    "samples/mygame/content/textures/island_hole.png": island_hole,
    "samples/mygame/content/textures/terrain_hole.png": terrain_hole,
    "samples/mygame/content/textures/playground_hills.png": playground_hills,
    "samples/mygame/content/textures/playground_layers.png": playground_layers,
    "samples/mygame/content/textures/foliage.png": foliage,
    "samples/mygame/content/textures/foliage_coverage.png": foliage,
}


# playground_bushes is the playground hills' foliage, an .instances file (see docs/content/kinds/instance-sets.md):
# bush cards on a jittered grid 4 m apart over the hills, off the dirt path and below the snow, each turned at random
# about up and scaled from 0.8 to 1.2, at the hills' height, in the space of the Hills entity, 64 m across and 8 m
# high. Scatter and erase more with the Landscape tool.
def playground_bushes():
    rng = random.Random(65)
    lines = ["instances 1",
             "# Each line is an instance: its position x y z in meters, its rotation as a quaternion x y z w, and its scale x y z,",
             "# relative to the entity whose Instanced_Mesh_Renderer names the set."]
    for j in range(16):
        for i in range(16):
            u = (i + 0.5 + rng.uniform(-0.4, 0.4)) / 16
            v = (j + 0.5 + rng.uniform(-0.4, 0.4)) / 16
            path = abs(u - (0.5 + 0.12 * math.sin(v * 2 * math.pi))) < 0.06
            hills = 0.5 + 0.5 * math.sin(u * 2 * math.pi * 2.5) * math.cos(v * 2 * math.pi * 1.5)
            height = clamp01(smoothstep(0.0, 0.5, v) * (0.3 + 0.35 * hills))
            if path or height > 0.45 or v < 0.05:
                continue
            yaw = rng.uniform(0, 2 * math.pi)
            scale = rng.uniform(0.8, 1.2)
            x, z, y = (u - 0.5) * 64, (v - 0.5) * 64, height * 8
            lines.append(f"i {x:.3f} {y:.3f} {z:.3f} 0 {math.sin(yaw / 2):.6f} 0 {math.cos(yaw / 2):.6f} {scale:.3f} {scale:.3f} {scale:.3f}")
    return "\n".join(lines) + "\n"


INSTANCES = {
    "samples/mygame/content/textures/playground_bushes.instances": playground_bushes,
}


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    for path, make in TEXTURES.items():
        w, h, rows, *depth = make()
        write_png(f"{root}/{path}", w, h, rows, *depth)
        print(path)
    for path, make in INSTANCES.items():
        with open(f"{root}/{path}", "w", newline="\n") as f:
            f.write(make())
        print(path)


if __name__ == "__main__":
    main(sys.argv)
