#!/usr/bin/env python3
"""S1 baseline: how far each variant's palette moves from the original's.

Reads only <out>/palette.csv from `safespace-cli analyze --variants s1` (contract §7.1) and
writes <out>/s1_baseline.csv plus a per-variant summary. Standard library only.

Distance: symmetric, share-weighted nearest-centroid distance in OKLab (the "chamfer" metric
used in the Task 8 method comparison). 0 means the same palette. This is a proposed §7.2
metric until A confirms it.

usage: python3 scripts/s1_baseline.py <analyze-output-dir>
"""
import csv
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def directed(a, b):
    mass = sum(share for share, _ in a)
    return sum(share * min(math.dist(lab, other) for _, other in b) for share, lab in a) / mass


def chamfer(a, b):
    return (directed(a, b) + directed(b, a)) / 2


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    palettes = defaultdict(list)
    with open(out / "palette.csv", newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            lab = (float(row["oklab_l"]), float(row["oklab_a"]), float(row["oklab_b"]))
            palettes[(row["image_id"], row["variant"])].append((float(row["share"]), lab))

    rows, by_variant = [], defaultdict(list)
    for (image_id, variant), palette in sorted(palettes.items()):
        if variant == "original":
            continue
        original = palettes.get((image_id, "original"))
        if not original:
            continue
        distance = chamfer(original, palette)
        rows.append({"image_id": image_id, "variant": variant, "chamfer_oklab": f"{distance:.6f}",
                     "color_count_original": len(original), "color_count_variant": len(palette)})
        by_variant[variant].append(distance)

    with open(out / "s1_baseline.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]) if rows else ["image_id"])
        writer.writeheader()
        writer.writerows(rows)

    print(f"{'variant':<10} {'images':>6} {'median':>9} {'p90':>9} {'max':>9}")
    for variant, values in sorted(by_variant.items()):
        values.sort()
        p90 = values[min(len(values) - 1, math.ceil(0.9 * len(values)) - 1)]
        print(f"{variant:<10} {len(values):>6} {statistics.median(values):>9.4f} {p90:>9.4f} {values[-1]:>9.4f}")
    print(f"Wrote {out / 's1_baseline.csv'}")


if __name__ == "__main__":
    main()
