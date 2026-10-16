"""Independent Python reference for SafeSpace's color math.

Written separately from the Swift code in Sources/SafeSpaceCore/Color so the two
can be checked against each other. Standard library only.

    python3 reference/color_reference.py          # regenerate reference/python_reference.json
    python3 -m unittest discover -s reference     # run the Python tests
"""

import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE_PATH = HERE / "python_reference.json"

# D65 reference white for CIELAB (2° observer), matching ColorSpace.swift.
D65_WHITE = (0.95047, 1.00000, 1.08883)

SRGB_TO_XYZ = (
    (0.4124564, 0.3575761, 0.1804375),
    (0.2126729, 0.7151522, 0.0721750),
    (0.0193339, 0.1191920, 0.9503041),
)

# Björn Ottosson, "A perceptual color space for image processing" (2020).
OKLAB_M1 = (
    (0.4122214708, 0.5363325363, 0.0514459929),
    (0.2119034982, 0.6806995451, 0.1073969566),
    (0.0883024619, 0.2817188376, 0.6299787005),
)
OKLAB_M2 = (
    (0.2104542553, 0.7936177850, -0.0040720468),
    (1.9779984951, -2.4285922050, 0.4505937099),
    (0.0259040371, 0.7827717662, -0.8086757660),
)


def _matmul(m, v):
    return tuple(sum(m[i][j] * v[j] for j in range(3)) for i in range(3))


def srgb_to_linear(c):
    """Inverse sRGB transfer function (IEC 61966-2-1), c in [0, 1]."""
    if c <= 0.04045:
        return c / 12.92
    return ((c + 0.055) / 1.055) ** 2.4


def srgb_to_oklab(r, g, b):
    lms = _matmul(OKLAB_M1, tuple(srgb_to_linear(c) for c in (r, g, b)))
    lms_ = tuple(math.copysign(abs(c) ** (1.0 / 3.0), c) for c in lms)
    return _matmul(OKLAB_M2, lms_)


def srgb_to_cielab(r, g, b):
    xyz = _matmul(SRGB_TO_XYZ, tuple(srgb_to_linear(c) for c in (r, g, b)))
    eps = (6.0 / 29.0) ** 3
    kappa = 1.0 / (3.0 * (6.0 / 29.0) ** 2)

    def f(t):
        return t ** (1.0 / 3.0) if t > eps else kappa * t + 4.0 / 29.0

    fx, fy, fz = (f(v / w) for v, w in zip(xyz, D65_WHITE))
    return (max(0.0, 116.0 * fy - 16.0), 500.0 * (fx - fy), 200.0 * (fy - fz))


def ciede2000(lab1, lab2, kL=1.0, kC=1.0, kH=1.0):
    """CIEDE2000 color difference per Sharma, Wu & Dalal (2005)."""
    L1, a1, b1 = lab1
    L2, a2, b2 = lab2

    c_bar = (math.hypot(a1, b1) + math.hypot(a2, b2)) / 2.0
    g = 0.5 * (1.0 - math.sqrt(c_bar**7 / (c_bar**7 + 25.0**7)))
    a1p, a2p = (1.0 + g) * a1, (1.0 + g) * a2
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360.0 if (a1p or b1) else 0.0
    h2p = math.degrees(math.atan2(b2, a2p)) % 360.0 if (a2p or b2) else 0.0

    d_lp = L2 - L1
    d_cp = c2p - c1p
    if c1p * c2p == 0:
        d_hp = 0.0
    else:
        d_hp = h2p - h1p
        if d_hp > 180.0:
            d_hp -= 360.0
        elif d_hp < -180.0:
            d_hp += 360.0
    d_Hp = 2.0 * math.sqrt(c1p * c2p) * math.sin(math.radians(d_hp) / 2.0)

    l_barp = (L1 + L2) / 2.0
    c_barp = (c1p + c2p) / 2.0
    if c1p * c2p == 0:
        h_barp = h1p + h2p
    elif abs(h1p - h2p) <= 180.0:
        h_barp = (h1p + h2p) / 2.0
    elif h1p + h2p < 360.0:
        h_barp = (h1p + h2p + 360.0) / 2.0
    else:
        h_barp = (h1p + h2p - 360.0) / 2.0

    t = (
        1.0
        - 0.17 * math.cos(math.radians(h_barp - 30.0))
        + 0.24 * math.cos(math.radians(2.0 * h_barp))
        + 0.32 * math.cos(math.radians(3.0 * h_barp + 6.0))
        - 0.20 * math.cos(math.radians(4.0 * h_barp - 63.0))
    )
    d_theta = 30.0 * math.exp(-(((h_barp - 275.0) / 25.0) ** 2))
    r_c = 2.0 * math.sqrt(c_barp**7 / (c_barp**7 + 25.0**7))
    s_l = 1.0 + 0.015 * (l_barp - 50.0) ** 2 / math.sqrt(20.0 + (l_barp - 50.0) ** 2)
    s_c = 1.0 + 0.045 * c_barp
    s_h = 1.0 + 0.015 * c_barp * t
    r_t = -math.sin(math.radians(2.0 * d_theta)) * r_c

    l_term = d_lp / (kL * s_l)
    c_term = d_cp / (kC * s_c)
    h_term = d_Hp / (kH * s_h)
    return math.sqrt(l_term**2 + c_term**2 + h_term**2 + r_t * c_term * h_term)


def reference_srgb_samples():
    """8-bit sRGB inputs for the Swift/Python cross-check."""
    steps = (0, 10, 11, 64, 128, 191, 255)  # 10/11 straddle the 0.04045 knee
    return [(r, g, b) for r in steps for g in steps for b in steps]


def build_fixture():
    samples = []
    for rgb in reference_srgb_samples():
        r, g, b = (c / 255.0 for c in rgb)
        samples.append({
            "srgb8": list(rgb),
            "oklab": list(srgb_to_oklab(r, g, b)),
            "cielab": list(srgb_to_cielab(r, g, b)),
        })
    return {
        "generator": "reference/color_reference.py",
        "samples": samples,
    }


if __name__ == "__main__":
    fixture = build_fixture()
    rows = ",\n  ".join(json.dumps(s) for s in fixture["samples"])
    FIXTURE_PATH.write_text(
        f'{{"generator": {json.dumps(fixture["generator"])},\n "samples": [\n  {rows}\n]}}\n'
    )
    print(f"wrote {FIXTURE_PATH.relative_to(HERE.parent)}")
