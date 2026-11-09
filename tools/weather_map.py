# Writes the samples' weather maps (see docs/rendering/clouds.md#weather and docs/content/kinds/textures.md#textures):
# 8-bit RGB PNGs, 512 texels square and tileable, whose R is the clouds' coverage, G the precipitation and B the cloud
# type, from seeded noise, so the repository holds no painted art. It makes maps in the spirit of the editor's
# `WeatherMap.Generate`, not with its algorithm, with the standard library only. `just sample-weather` runs it; commit what it writes, with the .meta files.
import math
import random
import struct
import sys
import zlib


# write_png takes rows of three bytes a texel, RGB.
def write_png(path, width, height, rows):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def clamp01(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def smoothstep(a, b, x):
    t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)


# Perlin is tiling gradient noise over a lattice of `cells` cells on a side: a unit gradient at each lattice point, from
# the seed, and quintic interpolation between the four around a point. It is about -1 to 1 with a mean of 0.
class Perlin:
    def __init__(self, rng, cells):
        self.cells = cells
        self.gradients = []
        for _ in range(cells * cells):
            angle = rng.random() * math.tau
            self.gradients.append((math.cos(angle), math.sin(angle)))

    def at(self, x, y):
        n = self.cells
        x, y = x * n, y * n
        ix, iy = math.floor(x), math.floor(y)
        fx, fy = x - ix, y - iy
        ux = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        uy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)

        def corner(cx, cy, dx, dy):
            gx, gy = self.gradients[(cy % n) * n + (cx % n)]
            return gx * dx + gy * dy

        a = corner(ix, iy, fx, fy)
        b = corner(ix + 1, iy, fx - 1, fy)
        c = corner(ix, iy + 1, fx, fy - 1)
        d = corner(ix + 1, iy + 1, fx - 1, fy - 1)
        top = a + (b - a) * ux
        bottom = c + (d - c) * ux
        return top + (bottom - top) * uy


# fbm sums `octaves` octaves of Perlin noise, each at twice the cells and half the amplitude, and divides by the sum of
# the amplitudes, so it stays about -1 to 1.
def fbm(rng, scale, octaves):
    layers = [Perlin(rng, scale << i) for i in range(octaves)]

    def at(x, y):
        total, amplitude, weight = 0.0, 1.0, 0.0
        for layer in layers:
            total += layer.at(x, y) * amplitude
            weight += amplitude
            amplitude *= 0.5
        return total / weight

    return at


# torus_distance is the distance between two points of the unit square that repeats.
def torus_distance(ax, ay, bx, by):
    dx = abs(ax - bx)
    dy = abs(ay - by)
    dx = min(dx, 1 - dx)
    dy = min(dy, 1 - dy)
    return math.sqrt(dx * dx + dy * dy)


# weather_map makes one map. Coverage (R) is an fbm of `octaves` octaves over `scale` cells, stretched about 0.5 and
# sharpened so the clouds are cells with clear sky between them, then moved by `coverage_bias` - 0.5, so its mean is
# about the bias. Precipitation (G) is `cells` Worley cells whose centers are where the coverage is high, each a
# rounded falloff over its radius, and a storm cell at `storm` (x, y, radius) when there is one, which rains fully at
# its center. The type (B) is 0.5, cumulus, raised toward 1, cumulonimbus, over the storm cell and a little over the
# rain cells, and lowered toward 0, stratus, where the coverage is thin.
def weather_map(seed, size=512, scale=6, octaves=4, coverage_bias=0.5, cells=3, storm=None):
    rng = random.Random(seed)
    noise = fbm(rng, scale, octaves)
    coverage = [[0.0] * size for _ in range(size)]
    for y in range(size):
        v = (y + 0.5) / size
        for x in range(size):
            u = (x + 0.5) / size
            c = smoothstep(0.3, 0.7, 0.5 + noise(u, v) * 0.9)
            coverage[y][x] = clamp01(c + coverage_bias - 0.5)

    # The rain cells sit where the coverage is high, from the seed, away from one another and the storm.
    centers = []
    for _ in range(4000):
        if len(centers) == cells:
            break
        cx, cy = rng.random(), rng.random()
        if coverage[int(cy * size)][int(cx * size)] < 0.7:
            continue
        if storm and torus_distance(cx, cy, storm[0], storm[1]) < storm[2] + 0.1:
            continue
        if any(torus_distance(cx, cy, ox, oy) < 0.2 for ox, oy, _ in centers):
            continue
        centers.append((cx, cy, 0.06 + 0.04 * rng.random()))

    rows = []
    for y in range(size):
        v = (y + 0.5) / size
        row = []
        for x in range(size):
            u = (x + 0.5) / size
            c = coverage[y][x]
            rain = 0.0
            for cx, cy, r in centers:
                d = torus_distance(u, v, cx, cy)
                rain = max(rain, 0.6 * (1 - smoothstep(0.0, r, d)) * smoothstep(0.3, 0.7, c))
            storm_fall = 0.0
            if storm:
                storm_fall = 1 - smoothstep(storm[2] * 0.3, storm[2], torus_distance(u, v, storm[0], storm[1]))
                rain = max(rain, storm_fall)
            kind = 0.5 + 0.5 * storm_fall + 0.2 * (rain - storm_fall) - 0.35 * (1 - smoothstep(0.2, 0.5, c))
            row.extend((int(round(c * 255)), int(round(rain * 255)), int(round(clamp01(kind) * 255))))
        rows.append(row)
    return size, size, rows


TEXTURES = {
    # Sponza: scattered cumulus around half coverage, and one storm cell off the center.
    "samples/intel/content/textures/sponza_weather.png": lambda: weather_map(seed=143, storm=(0.68, 0.3, 0.16)),
    # The glass scene: scattered cumulus, a little thinner, with rain cells and no storm.
    "samples/mygame/content/textures/glass_weather.png": lambda: weather_map(seed=7, coverage_bias=0.45),
}


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    for path, make in TEXTURES.items():
        w, h, rows = make()
        write_png(f"{root}/{path}", w, h, rows)
        print(path)


if __name__ == "__main__":
    main(sys.argv)
