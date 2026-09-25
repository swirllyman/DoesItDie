#!/usr/bin/env python3
"""Export the approved PNG artwork as game-ready TGA; --preview shows small sizes.

Requires Pillow. Source artwork lives beside this script.
"""
import pathlib
import sys
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent.parent
BIG = 1024


def build(size):
    source = "icon-source.png"
    with Image.open(pathlib.Path(__file__).with_name(source)) as image:
        assert image.width == image.height, "Expected square artwork"
        return image.convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)


def main():
    big = build(BIG)
    out = HERE / "DoesItDie" / "icon.tga"
    big.resize((64, 64), Image.LANCZOS).save(out)
    if "--preview" in sys.argv:
        target = pathlib.Path(sys.argv[sys.argv.index("--preview") + 1])
        sizes = [64, 32, 20, 16]
        strip = Image.new("RGBA", (sum(sizes) + 20 * (len(sizes) + 1), 80), (40, 40, 44, 255))
        x = 20
        for s in sizes:
            small = big.resize((s, s), Image.LANCZOS)
            strip.paste(small, (x, (80 - s) // 2), small)
            x += s + 20
        strip.resize((strip.width * 3, strip.height * 3), Image.NEAREST).save(target)
        print("preview: %s" % target)
    head = out.read_bytes()[:18]
    print("%s %.1f kB, TGA type %d (2 = uncompressed truecolour), %d bits, %dx%d" % (
        out.relative_to(HERE), out.stat().st_size / 1024, head[2], head[16],
        head[12] | head[13] << 8, head[14] | head[15] << 8))


if __name__ == "__main__":
    main()
