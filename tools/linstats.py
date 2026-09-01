"""Mean pre-tonemap linear value of a rectangle in a capture rendered at a known exposure.

    python3 tools/linstats.py shot.png 0.25 x0 y0 x1 y1

Snow saturates a whole frame at exposure 1.0, and at 255 every hypothesis about
why looks identical. Rendering once with `tonemap_exposure` turned down makes the
value the renderer actually produced readable straight off the PNG.
"""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import png


def srgb_to_linear(v):
    v /= 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def main():
    path, exposure = sys.argv[1], float(sys.argv[2])
    x0, y0, x1, y1 = map(int, sys.argv[3:7])
    w, h, pxs = png.read(path)
    acc = [0.0, 0.0, 0.0]
    n = 0
    for y in range(y0, min(y1, h)):
        for x in range(x0, min(x1, w)):
            i = (y * w + x) * 4
            for c in range(3):
                acc[c] += srgb_to_linear(pxs[i + c])
            n += 1
    print("%s  linear RGB %s" % (path, [round(a / n / exposure, 4) for a in acc]))


main()
