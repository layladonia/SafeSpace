import json
import unittest
from pathlib import Path

import color_reference as ref

HERE = Path(__file__).resolve().parent


class SharmaCIEDE2000Tests(unittest.TestCase):
    def test_all_sharma_pairs(self):
        pairs = json.loads((HERE / "sharma_ciede2000.json").read_text())["pairs"]
        self.assertEqual(len(pairs), 34)
        for i, pair in enumerate(pairs, start=1):
            with self.subTest(pair=i):
                self.assertAlmostEqual(ref.ciede2000(pair["lab1"], pair["lab2"]), pair["deltaE"], delta=0.0001)
                # ΔE00 is symmetric
                self.assertAlmostEqual(ref.ciede2000(pair["lab2"], pair["lab1"]), pair["deltaE"], delta=0.0001)


class ColorSpaceTests(unittest.TestCase):
    def test_oklab_reference_values(self):
        # Values from Ottosson's published OKLab definition.
        for rgb, expected in [
            ((1, 1, 1), (1.0, 0.0, 0.0)),
            ((0, 0, 0), (0.0, 0.0, 0.0)),
            ((1, 0, 0), (0.628, 0.225, 0.126)),
        ]:
            for got, want in zip(ref.srgb_to_oklab(*rgb), expected):
                self.assertAlmostEqual(got, want, delta=0.001)

    def test_cielab_reference_values(self):
        for got, want in zip(ref.srgb_to_cielab(1, 0, 0), (53.241, 80.092, 67.203)):
            self.assertAlmostEqual(got, want, delta=0.01)

    def test_fixture_is_up_to_date(self):
        committed = json.loads(ref.FIXTURE_PATH.read_text())
        self.assertEqual(committed, json.loads(json.dumps(ref.build_fixture())),
                         "run `python3 reference/color_reference.py` to regenerate")


if __name__ == "__main__":
    unittest.main()
